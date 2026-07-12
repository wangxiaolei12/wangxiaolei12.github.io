---
layout: post
title: "Linux 进程调度（十一）：switch_mm 地址空间切换深度剖析"
date: 2026-07-11 10:00:00 +0800
excerpt: "深入剖析 Linux 进程地址空间切换机制：switch_mm 在 x86 和 ARM64 架构下的实现差异、ASID/PCID 管理策略、Lazy TLB 模式、Generation 轮转机制以及性能优化策略。"
---

# Linux 进程调度（十一）：switch_mm 地址空间切换深度剖析

基于 mainline 内核源码分析，聚焦 `switch_mm` 函数实现

---

## 一、背景：为什么需要地址空间切换

在多任务操作系统中，每个进程都有独立的虚拟地址空间。当调度器切换进程时，必须切换页表，使 CPU 能够正确访问新进程的内存。

```
进程 A (虚拟地址 0x00000000)          进程 B (虚拟地址 0x00000000)
        │                                     │
        ▼                                     ▼
   [页表 A]                               [页表 B]
        │                                     │
        ▼                                     ▼
   物理内存 0x10000000                  物理内存 0x20000000
```

**核心挑战**：
1. **性能**：频繁的页表切换会影响系统吞吐量
2. **TLB 一致性**：切换页表后需处理翻译后备缓冲（TLB）的失效
3. **多 CPU 协调**：SMP 环境下需确保所有 CPU 的 TLB 状态一致

---

## 二、switch_mm 调用链路

```
__schedule()                    // 调度器主函数
    │
    └─→ context_switch()       // 上下文切换入口
            │
            ├─→ prepare_task_switch()   // 准备切换
            │
            ├─→ switch_mm_irqs_off(prev->active_mm, next->mm, next)
            │       │
            │       └─→ 切换页表、更新 ASID、TLB 管理
            │
            ├─→ switch_to(prev, next, prev)  // 切换寄存器和栈
            │
            └─→ finish_task_switch(prev)     // 清理工作
```

---

## 三、x86 架构实现

### 3.1 核心数据结构

```c
// arch/x86/include/asm/tlbflush.h
struct cpu_tlbstate {
    struct mm_struct *loaded_mm;    // 当前 CPU 加载的 mm
    u16 loaded_mm_asid;             // 当前 ASID
    struct ctx {
        u64 ctx_id;                 // 上下文 ID
        u64 tlb_gen;                // TLB 版本号
    } ctxs[TLB_NR_DYN_ASIDS];       // ASID 缓存（默认 4 个槽位）
};
DECLARE_PER_CPU(struct cpu_tlbstate, cpu_tlbstate);
```

### 3.2 ASID 空间划分

x86 使用 PCID（Process Context ID），支持动态 ASID 和全局 ASID：

```
ASID 空间划分
+-------------------+-------------------------------+
|   动态 ASID       |         全局 ASID             |
| (局部/每 CPU)     |      (全局/跨 CPU)            |
+-------------------+-------------------------------+
| 0 ~ TLB_NR_DYN-1  | TLB_NR_DYN ~ MAX_ASID-1       |
|                   |                               |
| 每 CPU 独立分配   | 全局统一分配，所有 CPU 相同    |
|                   |                               |
| 本地 TLB 刷新     | 广播 TLB 刷新（INVLPGB）      |
| + IPI shootdown   |                               |
+-------------------+-------------------------------+
```

### 3.3 switch_mm_irqs_off 核心逻辑

```c
// arch/x86/mm/tlb.c:783
void switch_mm_irqs_off(struct mm_struct *unused, struct mm_struct *next,
                        struct task_struct *tsk)
{
    struct mm_struct *prev = this_cpu_read(cpu_tlbstate.loaded_mm);
    u16 prev_asid = this_cpu_read(cpu_tlbstate.loaded_mm_asid);
    bool was_lazy = this_cpu_read(cpu_tlbstate_shared.is_lazy);

    if (prev == next) {
        if (is_global_asid(prev_asid))
            return;
        if (!was_lazy)
            return;
        if (this_cpu_read(cpu_tlbstate.ctxs[prev_asid].tlb_gen) ==
            atomic64_read(&next->context.tlb_gen))
            return;
    } else {
        cond_mitigation(tsk);
        this_cpu_write(cpu_tlbstate.loaded_mm, LOADED_MM_SWITCHING);
    }

reload_tlb:
    load_new_mm_cr3(next->pgd, ns.asid, new_lam, ns.need_flush);
    this_cpu_write(cpu_tlbstate.loaded_mm, next);
    this_cpu_write(cpu_tlbstate.loaded_mm_asid, ns.asid);
}
```

### 3.4 CR3 寄存器格式

```
CR3 寄存器格式
+---------------------------------------+-----------+------+
|           Page Directory Base         |   PCID    | LAM  |
|              (40 bits)                |  (12 bits)|(4bit)|
+---------------------------------------+-----------+------+
```

### 3.5 x86 ASID 选择策略

```c
// arch/x86/mm/tlb.c:240
static struct new_asid choose_new_asid(struct mm_struct *next, u64 next_tlb_gen)
{
    if (mm_global_asid(next)) {
        ns.asid = mm_global_asid(next);
        ns.need_flush = 0;
        return ns;
    }

    for (asid = 0; asid < TLB_NR_DYN_ASIDS; asid++) {
        if (cpu_tlbstate.ctxs[asid].ctx_id == next->context.ctx_id) {
            ns.asid = asid;
            ns.need_flush = (cpu_tlbstate.ctxs[asid].tlb_gen < next_tlb_gen);
            return ns;
        }
    }

    ns.asid = this_cpu_add_return(cpu_tlbstate.next_asid, 1) - 1;
    ns.need_flush = true;
    return ns;
}
```

---

## 四、ARM64 架构实现

### 4.1 核心数据结构

```c
// arch/arm64/include/asm/mmu.h
typedef struct {
    atomic64_t    id;          // ASID + Generation（64 位）
    refcount_t    pinned;      // Pinned ASID 引用计数
    void          *vdso;       // VDSO 地址
} mm_context_t;
```

**ASID 格式**（64 位）：

```
+----------------------------------+-------------------+
|        Generation（高 48 位）     |  ASID 编号        |
|                                   | （低 8/16 位）    |
+----------------------------------+-------------------+
```

### 4.2 全局 ASID 管理

```c
// arch/arm64/mm/context.c
static u32 asid_bits;                    // CPU 支持的 ASID 位数
static DEFINE_RAW_SPINLOCK(cpu_asid_lock);  // 全局锁
static atomic64_t asid_generation;       // Generation 计数器
static unsigned long *asid_map;          // ASID 使用位图
static cpumask_t tlb_flush_pending;     // 需要 TLB 刷新的 CPU
```

### 4.3 check_and_switch_context 核心逻辑

```c
// arch/arm64/mm/context.c:215
void check_and_switch_context(struct mm_struct *mm)
{
    u64 asid, old_active_asid;

    asid = atomic64_read(&mm->context.id);

    old_active_asid = atomic64_read(this_cpu_ptr(&active_asids));
    if (old_active_asid && asid_gen_match(asid) &&
        atomic64_cmpxchg_relaxed(this_cpu_ptr(&active_asids),
                                 old_active_asid, asid))
        goto switch_mm_fastpath;

    raw_spin_lock_irqsave(&cpu_asid_lock, flags);
    if (!asid_gen_match(asid)) {
        asid = new_context(mm);
        atomic64_set(&mm->context.id, asid);
    }

    if (cpumask_test_and_clear_cpu(cpu, &tlb_flush_pending))
        local_flush_tlb_all();

    atomic64_set(this_cpu_ptr(&active_asids), asid);
    raw_spin_unlock_irqrestore(&cpu_asid_lock, flags);

switch_mm_fastpath:
    cpu_switch_mm(mm->pgd, mm);
}
```

### 4.4 Generation 轮转机制

当 ASID 空间耗尽时，ARM64 通过增加 generation 使所有旧 ASID 失效：

```c
// arch/arm64/mm/context.c:158
static u64 new_context(struct mm_struct *mm)
{
    asid = find_next_zero_bit(asid_map, NUM_USER_ASIDS, cur_idx);
    if (asid != NUM_USER_ASIDS)
        goto set_asid;

    generation = atomic64_add_return_relaxed(ASID_FIRST_VERSION,
                                             &asid_generation);
    flush_context();
    asid = find_next_zero_bit(asid_map, NUM_USER_ASIDS, 1);

set_asid:
    __set_bit(asid, asid_map);
    return asid2ctxid(asid, generation);
}
```

### 4.5 TTBRx_EL1 寄存器操作

```c
// arch/arm64/mm/context.c:349
void cpu_do_switch_mm(phys_addr_t pgd_phys, struct mm_struct *mm)
{
    unsigned long asid = ASID(mm);
    unsigned long ttbr0 = phys_to_ttbr(pgd_phys);
    unsigned long ttbr1 = read_sysreg(ttbr1_el1);

    if (system_supports_cnp() && asid)
        ttbr0 |= TTBRx_EL1_CnP;

    ttbr1 &= ~TTBRx_EL1_ASID_MASK;
    ttbr1 |= FIELD_PREP(TTBRx_EL1_ASID_MASK, asid);

    write_sysreg(ttbr1, ttbr1_el1);
    write_sysreg(ttbr0, ttbr0_el1);
    isb();
}
```

---

## 五、Lazy TLB 模式

### 5.1 设计思想

当内核线程（`task->mm == NULL`）运行时，CPU 保留上一个用户进程的页表：

```
用户进程 (A)
    │
    ├─→ 切换到内核线程 (K)
    │     └─→ enter_lazy_tlb()
    │           └─→ TTBR0 指向零页（保留内核页表）
    │
    ├─→ 切换回用户进程 (A)
    │     └─→ 快速路径：ASID 有效，直接复用
    │
    └─→ 切换到另一个用户进程 (B)
          └─→ 正常切换页表
```

### 5.2 调用时机

```c
// kernel/sched/core.c:5475
if (!next->mm) {
    if (prev->mm)
        mmgrab_lazy_tlb(prev->active_mm);
    else
        prev->active_mm = NULL;
} else {
    switch_mm_irqs_off(prev->active_mm, next->mm, next);
}
```

---

## 六、x86 vs ARM64 对比

| 特性 | x86 | ARM64 |
|------|-----|-------|
| **页表寄存器** | CR3 | TTBR0_EL1 / TTBR1_EL1 |
| **ASID 位数** | 12 位（含 PTI） | 8 或 16 位 |
| **ASID 分配** | 动态 ASID + 全局 ASID | 全局位图 + Generation 轮转 |
| **锁机制** | 动态 ASID 无锁 | 全局 `cpu_asid_lock` |
| **TLB 刷新** | IPI shootdown / INVLPGB | 延迟刷新（Generation 轮转后） |
| **广播刷新** | 支持 INVLPGB（AMD） | 不支持 |
| **CnP 特性** | 不支持 | 支持 |
| **快速路径** | PCID 匹配检查 | 原子 cmpxchg |
| **ASID 耗尽** | 循环复用槽位 | Generation 轮转 |

---

## 七、性能优化策略

### 7.1 快速路径优化

| 架构 | 快速路径条件 | 开销 |
|------|-------------|------|
| x86 | `prev == next && !was_lazy` | 零开销，直接返回 |
| ARM64 | `cmpxchg` 成功 | 一次原子操作 |

### 7.2 PCID / ASID 优化

- **x86 PCID**：不同进程共享 TLB 条目，通过 PCID 区分
- **ARM64 CnP**：标记页表条目为"公共"，其他 CPU 共享 TLB

### 7.3 延迟 TLB 刷新

- **x86**：Lazy TLB 模式延迟刷新
- **ARM64**：Generation 轮转后标记 CPU，下次切换时刷新

### 7.4 全局 ASID 优化

- **x86**：高频多 CPU 进程使用全局 ASID，避免 IPI shootdown
- **ARM64**：Pinned ASID 用于需要跨 CPU 持久化的场景

---

## 八、安全机制

### 8.1 KPTI（Kernel Page Table Isolation）

将内核页表和用户页表分离，防止 Meltdown 攻击：

```c
static inline u16 user_pcid(u16 asid)
{
    u16 ret = kern_pcid(asid);
    ret |= 1 << X86_CR3_PTI_PCID_USER_BIT;
    return ret;
}
```

### 8.2 Spectre-v2 缓解

进程间切换时刷新分支预测器：

```c
if (next_tif & TIF_SPEC_IB)
    indirect_branch_prediction_barrier();
```

### 8.3 SW PAN（Privileged Access Never）

ARM64 软件模拟 PAN 保护：

```c
if (system_uses_ttbr0_pan())
    WRITE_ONCE(task_thread_info(tsk)->ttbr0, ttbr);
```

---

## 九、调试技巧

### 9.1 查看当前进程的 ASID

```bash
cat /proc/PID/status | grep -i asid
```

### 9.2 监控 TLB 刷新次数

```bash
echo 1 > /proc/sys/vm/tlb_flush_all
cat /proc/vmstat | grep tlb
```

### 9.3 使用 perf 分析上下文切换

```bash
perf stat -e context-switches,cpu-clock -p PID
```

---

## 十、总结

`switch_mm` 是 Linux 内核中进程地址空间切换的核心函数，其设计体现了以下原则：

| 原则 | 实现方式 |
|------|----------|
| **性能优先** | 快速路径无锁、PCID/ASID 复用、延迟刷新 |
| **正确性保障** | ASID generation、TLB shootdown、内存屏障 |
| **多 CPU 协调** | cpumask 更新、IPI 机制、全局 ASID |
| **安全增强** | KPTI、Spectre 缓解、PAN 保护 |
| **架构适配** | x86/ARM64 各自优化，利用硬件特性 |

**核心设计思想**：通过分层 ASID 管理、延迟刷新和硬件特性利用，在页表切换的正确性和性能之间取得最佳平衡。

---

*本文由 [王孝雷](https://wangxiaolei12.github.io) 原创，转载请注明出处。*