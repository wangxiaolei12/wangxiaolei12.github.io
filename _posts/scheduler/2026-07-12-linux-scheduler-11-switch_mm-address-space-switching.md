---
layout: post
title: "Linux 进程调度（十一）：switch_mm 地址空间切换深度剖析"
date: 2026-07-12 10:00:00 +0800
excerpt: "深入剖析 Linux 进程地址空间切换机制：先讲核心原理（ASID、TLB、Generation 轮转），再逐行对照 ARM64 源码分析实现细节，重点讲解快速路径设计、延迟 TLB 刷新策略和并发安全保障。"
---

# Linux 进程调度（十一）：switch_mm 地址空间切换深度剖析

基于 mainline 内核源码分析，先讲原理，再讲实现

---

## 一、核心原理

### 1.1 为什么需要地址空间切换

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

### 1.2 TLB 的作用与问题

**TLB（Translation Lookaside Buffer）** 是 CPU 的缓存，存储虚拟地址到物理地址的映射：

```
TLB 条目格式：
┌──────────────┬──────────────────────────────────────┐
│     ASID     │         Virtual Address              │
│  (8/16 bits) │           (48 bits)                  │
└──────────────┴──────────────────────────────────────┘
                   │
                   ▼
            Physical Address
```

**问题**：如果每次进程切换都刷新 TLB，TLB 命中率会归零，导致严重的性能下降。

### 1.3 ASID 机制

**ASID（Address Space Identifier）** 是解决方案：

```
ASID 工作原理：
┌─────────────────────────────────────────────────────────────┐
│ 进程 A (ASID=1) 的 TLB 条目：                              │
│  [1][0x1000] → 0x10000000                                  │
│                                                            │
│ 进程 B (ASID=2) 的 TLB 条目：                              │
│  [2][0x1000] → 0x20000000                                  │
│                                                            │
│ 不同 ASID 的 TLB 条目可以共存！                              │
│ 切换时只需更新 ASID，无需刷新 TLB！                          │
└─────────────────────────────────────────────────────────────┘
```

### 1.4 Generation 轮转

ASID 空间有限（8 位 = 256 个，16 位 = 65536 个），当 ASID 空间耗尽时：

```
Generation 轮转机制：
┌─────────────────────────────────────────────────────────────┐
│ 1. 全局 generation + 1                                      │
│ 2. 标记所有 CPU 需要 TLB 刷新                                │
│ 3. ASID 可以重新分配                                        │
│                                                            │
│ 旧 ASID：[Generation=1][ASID=5] → 失效                      │
│ 新 ASID：[Generation=2][ASID=5] → 有效                      │
│                                                            │
│ TLB 条目匹配时，Generation 和 ASID 都必须匹配！               │
└─────────────────────────────────────────────────────────────┘
```

### 1.5 快速路径与慢速路径

```
设计策略：优化常见路径，容忍罕见路径
┌─────────────────────────────────────────────────────────────┐
│ 快速路径（99% 的情况）：                                    │
│   - ASID 有效且未过期                                       │
│   - 无并发竞争                                              │
│   - 直接写入寄存器，无需加锁和 TLB 刷新                      │
│                                                            │
│ 慢速路径（1% 的情况）：                                     │
│   - ASID 过期或未分配                                       │
│   - 有并发竞争                                              │
│   - 需要加锁、重新分配 ASID、刷新 TLB                        │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、调用链路

```
__schedule()                    // 调度器主函数
    │
    └─→ context_switch()       // 上下文切换入口
            │
            ├─→ prepare_task_switch()   // 准备切换
            │
            ├─→ switch_mm(prev->active_mm, next->mm, next)
            │       │
            │       └─→ __switch_mm(next)
            │             │
            │             └─→ check_and_switch_context(next)
            │                   │
            │                   └─→ cpu_do_switch_mm()
            │                         └─→ 写入 TTBR0_EL1 / TTBR1_EL1
            │
            ├─→ switch_to(prev, next, prev)  // 切换寄存器和栈
            │
            └─→ finish_task_switch(prev)     // 清理工作
```

---

## 三、核心数据结构

### 3.1 mm_context_t

```c
// arch/arm64/include/asm/mmu.h:19
typedef struct {
    atomic64_t    id;          // ASID + Generation（64 位）
    refcount_t    pinned;      // Pinned ASID 引用计数
    void          *vdso;       // VDSO 地址
} mm_context_t;
```

**`mm->context.id` 格式**：

```
+----------------------------------+-------------------+
|        Generation（高 48 位）     |  ASID 编号        |
|                                   | （低 8/16 位）    |
+----------------------------------+-------------------+
```

### 3.2 全局 ASID 管理变量

```c
// arch/arm64/mm/context.c:20-28
static u32 asid_bits;                    // CPU 支持的 ASID 位数
static DEFINE_RAW_SPINLOCK(cpu_asid_lock);  // 全局 ASID 分配锁
static atomic64_t asid_generation;       // 全局 Generation 计数器
static unsigned long *asid_map;          // ASID 使用位图
static cpumask_t tlb_flush_pending;     // 需要 TLB 刷新的 CPU
static DEFINE_PER_CPU(atomic64_t, active_asids);  // 每 CPU 活跃 ASID
```

---

## 四、ARM64 核心代码逐行分析

### 4.1 switch_mm 入口

```c
// arch/arm64/include/asm/mmu_context.h:250
static inline void switch_mm(struct mm_struct *prev, struct mm_struct *next,
                             struct task_struct *tsk)
{
    if (prev != next)
        __switch_mm(next);

    update_saved_ttbr0(tsk, next);
}
```

**分析**：
- 只有 `prev != next` 时才执行实际切换
- 同一进程内的线程切换（`prev == next`）只需更新保存的 TTBR0

### 4.2 __switch_mm

```c
// arch/arm64/include/asm/mmu_context.h:236
static inline void __switch_mm(struct mm_struct *next)
{
    // init_mm 是内核页表，不需要用户空间映射
    if (next == &init_mm) {
        cpu_set_reserved_ttbr0();
        return;
    }

    check_and_switch_context(next);
}
```

**分析**：
- 如果目标是 `init_mm`（内核页表），直接将 TTBR0 指向零页
- 否则调用 `check_and_switch_context` 进行完整切换

### 4.3 check_and_switch_context（核心函数）

```c
// arch/arm64/mm/context.c:215
void check_and_switch_context(struct mm_struct *mm)
{
    unsigned long flags;
    unsigned int cpu;
    u64 asid, old_active_asid;

    if (system_supports_cnp())
        cpu_set_reserved_ttbr0();

    asid = atomic64_read(&mm->context.id);
```

**第217-219行**：变量声明

| 变量 | 用途 |
|------|------|
| `flags` | 保存中断状态 |
| `cpu` | 当前 CPU 编号 |
| `asid` | 目标进程的 ASID |
| `old_active_asid` | 当前 CPU 的活跃 ASID |

**第221-222行**：CnP 预处理

```c
if (system_supports_cnp())
    cpu_set_reserved_ttbr0();
```

**分析**：如果支持 CnP（Common Not Private）特性，先将 TTBR0 指向零页，防止投机执行访问旧用户页表。

**第224行**：读取目标 ASID

```c
asid = atomic64_read(&mm->context.id);
```

**分析**：从目标进程的 `mm_struct` 中读取 ASID（含 generation）。使用 `atomic64_read` 确保原子性，因为其他 CPU 可能修改这个值。

---

#### 快速路径判断

```c
    old_active_asid = atomic64_read(this_cpu_ptr(&active_asids));
    if (old_active_asid && asid_gen_match(asid) &&
        atomic64_cmpxchg_relaxed(this_cpu_ptr(&active_asids),
                                 old_active_asid, asid))
        goto switch_mm_fastpath;
```

**第240行**：读取当前活跃 ASID

```c
old_active_asid = atomic64_read(this_cpu_ptr(&active_asids));
```

**分析**：读取当前 CPU 的活跃 ASID。`this_cpu_ptr` 访问每 CPU 变量，避免缓存一致性开销。

**第241-244行**：三个条件检查

| 条件 | 含义 | 不满足时的处理 |
|------|------|---------------|
| `old_active_asid != 0` | 当前 CPU 有活跃的 ASID | 进入慢速路径，重新初始化 |
| `asid_gen_match(asid)` | ASID 的 generation 未过期 | 进入慢速路径，重新分配 ASID |
| `cmpxchg 成功` | 无并发竞争 | 进入慢速路径，获取锁 |

**条件1详解**：`old_active_asid != 0`

```c
old_active_asid && ...
```

**不满足的情况**：
- CPU 刚启动，还没有加载任何进程的页表
- 刚经历过 generation 轮转，`flush_context()` 将所有 `active_asids` 清零

**条件2详解**：`asid_gen_match(asid)`

```c
#define asid_gen_match(asid) \
    (!(((asid) ^ atomic64_read(&asid_generation)) >> asid_bits))
```

**计算示例**：
```c
asid = 0x0002000A;  // generation=2, asid=10
asid_generation = 0x00020000;  // 全局 generation=2

xor_result = 0x0002000A ^ 0x00020000 = 0x0000000A;
shift_result = 0x0000000A >> 16 = 0;
result = !0 = true;  // 匹配！
```

**不满足的情况**：目标进程的 ASID 是旧 generation 分配的，已过期。

**条件3详解**：`atomic64_cmpxchg_relaxed`

```c
atomic64_cmpxchg_relaxed(this_cpu_ptr(&active_asids),
                         old_active_asid, asid)
```

**cmpxchg 操作**（原子）：
1. 读取 `active_asids` 的当前值
2. 比较当前值是否等于 `old_active_asid`
3. 如果相等，写入 `asid`，返回 true
4. 如果不等，不写入，返回 false

**成功**：没有并发竞争，原子更新成功
**失败**：其他 CPU 修改了 `active_asids`，必须进入慢速路径获取锁

---

#### 慢速路径

```c
    raw_spin_lock_irqsave(&cpu_asid_lock, flags);

    asid = atomic64_read(&mm->context.id);
    if (!asid_gen_match(asid)) {
        asid = new_context(mm);
        atomic64_set(&mm->context.id, asid);
    }

    cpu = smp_processor_id();
    if (cpumask_test_and_clear_cpu(cpu, &tlb_flush_pending))
        local_flush_tlb_all();

    atomic64_set(this_cpu_ptr(&active_asids), asid);
    raw_spin_unlock_irqrestore(&cpu_asid_lock, flags);
```

**第246行**：获取全局锁

```c
raw_spin_lock_irqsave(&cpu_asid_lock, flags);
```

**分析**：获取 `cpu_asid_lock` 自旋锁并禁止中断。保护 ASID 分配和 generation 更新，防止多个 CPU 同时分配相同的 ASID。

**第248行**：重新读取 ASID

```c
asid = atomic64_read(&mm->context.id);
```

**分析**：在获取锁之后重新读取，确保一致性。因为在获取锁之前，可能有其他 CPU 修改了这个值。

**第249-252行**：检查并重新分配 ASID

```c
if (!asid_gen_match(asid)) {
    asid = new_context(mm);
    atomic64_set(&mm->context.id, asid);
}
```

**分析**：如果 ASID 的 generation 不匹配（过期），调用 `new_context()` 重新分配。

**第254-256行**：延迟 TLB 刷新

```c
cpu = smp_processor_id();
if (cpumask_test_and_clear_cpu(cpu, &tlb_flush_pending))
    local_flush_tlb_all();
```

**分析**：检查当前 CPU 是否需要刷新 TLB（`tlb_flush_pending` 掩码标记）。如果需要，执行 `local_flush_tlb_all()`。

**为什么延迟刷新？**
- generation 轮转时，不立即刷新所有 CPU 的 TLB
- 而是标记需要刷新的 CPU
- 等到下次上下文切换时再执行，避免 IPI 开销

**第258行**：更新活跃 ASID

```c
atomic64_set(this_cpu_ptr(&active_asids), asid);
```

**分析**：将新的 ASID（含 generation）写入当前 CPU 的 `active_asids`。

**第259行**：释放锁

```c
raw_spin_unlock_irqrestore(&cpu_asid_lock, flags);
```

**分析**：释放全局锁并恢复中断状态。

---

#### 快速路径（写入寄存器）

```c
switch_mm_fastpath:

    arm64_apply_bp_hardening();

    if (!system_uses_ttbr0_pan())
        cpu_switch_mm(mm->pgd, mm);
}
```

**第263行**：分支预测缓解

```c
arm64_apply_bp_hardening();
```

**分析**：针对 Spectre-v2 漏洞的缓解措施，刷新分支预测器。

**第269-270行**：切换页表

```c
if (!system_uses_ttbr0_pan())
    cpu_switch_mm(mm->pgd, mm);
```

**分析**：如果没有启用 SW PAN，调用 `cpu_switch_mm()` 切换页表。SW PAN 模式下，TTBR0 的设置会延迟到 `uaccess_enable()` 时执行。

---

### 4.4 cpu_do_switch_mm（硬件寄存器操作）

```c
// arch/arm64/mm/context.c:349
void cpu_do_switch_mm(phys_addr_t pgd_phys, struct mm_struct *mm)
{
    unsigned long ttbr1 = read_sysreg(ttbr1_el1);
    unsigned long asid = ASID(mm);
    unsigned long ttbr0 = phys_to_ttbr(pgd_phys);

    if (system_supports_cnp() && asid)
        ttbr0 |= TTBRx_EL1_CnP;

    if (IS_ENABLED(CONFIG_ARM64_SW_TTBR0_PAN))
        ttbr0 |= FIELD_PREP(TTBRx_EL1_ASID_MASK, asid);

    ttbr1 &= ~TTBRx_EL1_ASID_MASK;
    ttbr1 |= FIELD_PREP(TTBRx_EL1_ASID_MASK, asid);

    cpu_set_reserved_ttbr0_nosync();

    write_sysreg(ttbr1, ttbr1_el1);
    write_sysreg(ttbr0, ttbr0_el1);
    isb();
    post_ttbr_update_workaround();
}
```

**执行顺序分析**：

| 步骤 | 操作 | 目的 |
|------|------|------|
| 1 | `cpu_set_reserved_ttbr0_nosync()` | TTBR0 指向零页，防止投机访问 |
| 2 | `write_sysreg(ttbr1, ttbr1_el1)` | 更新内核页表基址（先保证内核安全） |
| 3 | `write_sysreg(ttbr0, ttbr0_el1)` | 更新用户页表基址 |
| 4 | `isb()` | 指令同步屏障，确保写入生效 |

**为什么先写 TTBR1？**
- TTBR1 是内核页表，内核代码在所有进程间共享
- 先更新内核页表，确保内核代码可以正常执行
- 如果先写 TTBR0，在写 TTBR1 之前的短暂时间内，内核访问可能出错

**为什么需要 `isb()`？**
- CPU 可能重排序指令执行
- `isb()` 确保所有寄存器写入完成后再执行后续指令
- 防止后续指令使用旧的页表

---

### 4.5 new_context（ASID 分配）

```c
// arch/arm64/mm/context.c:158
static u64 new_context(struct mm_struct *mm)
{
    static u32 cur_idx = 1;
    u64 asid = atomic64_read(&mm->context.id);
    u64 generation = atomic64_read(&asid_generation);

    if (asid != 0) {
        u64 newasid = asid2ctxid(ctxid2asid(asid), generation);

        if (check_update_reserved_asid(asid, newasid))
            return newasid;

        if (refcount_read(&mm->context.pinned))
            return newasid;

        if (!__test_and_set_bit(ctxid2asid(asid), asid_map))
            return newasid;
    }

    asid = find_next_zero_bit(asid_map, NUM_USER_ASIDS, cur_idx);
    if (asid != NUM_USER_ASIDS)
        goto set_asid;

    generation = atomic64_add_return_relaxed(ASID_FIRST_VERSION,
                                             &asid_generation);
    flush_context();

    asid = find_next_zero_bit(asid_map, NUM_USER_ASIDS, 1);

set_asid:
    __set_bit(asid, asid_map);
    cur_idx = asid;
    return asid2ctxid(asid, generation);
}
```

**分配策略**：

| 步骤 | 条件 | 操作 |
|------|------|------|
| 1 | ASID 在保留列表中 | 复用旧 ASID，更新 generation |
| 2 | ASID 被固定（Pinned） | 复用旧 ASID |
| 3 | ASID 位图位空闲 | 复用旧 ASID |
| 4 | 位图中有空闲位 | 分配新的空闲 ASID |
| 5 | ASID 空间耗尽 | 触发 generation 轮转 |

**generation 轮转时的操作**：
1. `generation = atomic64_add_return_relaxed(ASID_FIRST_VERSION, &asid_generation)` - 全局 generation + 1
2. `flush_context()` - 收集所有 CPU 的活跃 ASID，标记需要 TLB 刷新
3. `find_next_zero_bit()` - 重新分配空闲 ASID

---

### 4.6 flush_context（generation 轮转）

```c
// arch/arm64/mm/context.c:104
static void flush_context(void)
{
    int i;
    u64 asid;

    set_reserved_asid_bits();

    for_each_possible_cpu(i) {
        asid = atomic64_xchg_relaxed(&per_cpu(active_asids, i), 0);
        if (asid == 0)
            asid = per_cpu(reserved_asids, i);
        __set_bit(ctxid2asid(asid), asid_map);
        per_cpu(reserved_asids, i) = asid;
    }

    cpumask_setall(&tlb_flush_pending);
}
```

**分析**：
1. 更新保留的 ASID 位图
2. 遍历所有 CPU，收集它们的活跃 ASID
3. 将活跃 ASID 添加到位图和保留列表
4. 标记所有 CPU 需要 TLB 刷新（`tlb_flush_pending`）

**关键设计**：不立即发送 IPI 刷新 TLB，而是延迟到下次上下文切换时执行。

---

## 五、Lazy TLB 模式

### 5.1 设计思想

当内核线程（`task->mm == NULL`）运行时，CPU 保留上一个用户进程的页表，避免频繁切换：

```
用户进程 A → 内核线程 K → 用户进程 A
         │           │          │
         │           │          └─→ 快速路径：ASID 有效，直接复用
         │           │                 无需刷新 TLB
         │           └─→ enter_lazy_tlb()
         │                 └─→ TTBR0 指向零页（保留页表不刷新）
         └─→ check_and_switch_context()
               └─→ cpu_do_switch_mm()
```

### 5.2 调用时机

```c
// kernel/sched/core.c:5475
if (!next->mm) {                    // next 是内核线程
    if (prev->mm)                   // prev 是用户进程
        mmgrab_lazy_tlb(prev->active_mm);  // 保留 prev 的页表
    else
        prev->active_mm = NULL;
} else {                            // next 是用户进程
    switch_mm_irqs_off(prev->active_mm, next->mm, next);
}
```

---

## 六、完整执行流程图

```
check_and_switch_context(mm)
    │
    ├─→ 读取目标 ASID (asid = mm->context.id)
    │
    ├─→ 快速路径检查
    │     ├─→ old_active_asid != 0?
    │     │     └─→ 否 → 进入慢速路径
    │     │
    │     ├─→ asid_gen_match(asid)?
    │     │     └─→ 否 → 进入慢速路径
    │     │
    │     └─→ cmpxchg 成功?
    │           └─→ 否 → 进入慢速路径
    │                 │
    │                 ▼
    │     ┌───────────────────────────────┐
    │     │ 慢速路径                       │
    │     │  ├─→ 获取 cpu_asid_lock       │
    │     │  ├─→ 重新读取 ASID            │
    │     │  ├─→ generation 过期?         │
    │     │  │     └─→ 是 → new_context() │
    │     │  ├─→ 需要 TLB 刷新?           │
    │     │  │     └─→ 是 → local_flush   │
    │     │  ├─→ 更新 active_asids        │
    │     │  └─→ 释放 cpu_asid_lock       │
    │     └───────────────────────────────┘
    │
    └─→ switch_mm_fastpath
          ├─→ arm64_apply_bp_hardening()
          └─→ cpu_switch_mm(mm->pgd, mm)
                └─→ cpu_do_switch_mm()
                      ├─→ cpu_set_reserved_ttbr0_nosync()
                      ├─→ write_sysreg(ttbr1, ttbr1_el1)
                      ├─→ write_sysreg(ttbr0, ttbr0_el1)
                      └─→ isb()
```

---

## 七、关键设计总结

| 设计点 | 原理 | 代码实现 |
|--------|------|---------|
| **快速路径** | 优化常见路径，避免加锁和 TLB 刷新 | 三个条件检查 + cmpxchg |
| **ASID 管理** | 有限 ASID 空间的复用 | 全局位图 + generation 轮转 |
| **延迟刷新** | 避免 IPI shootdown 开销 | `tlb_flush_pending` 掩码 |
| **并发安全** | 保证 ASID 唯一性 | `cpu_asid_lock` + cmpxchg |
| **投机执行防护** | 防止切换期间的投机访问 | `cpu_set_reserved_ttbr0` |
| **内存屏障** | 确保寄存器写入生效 | `isb()` |

---

## 八、性能对比

| 路径 | 锁操作 | TLB 刷新 | 内存屏障 | 平均开销 |
|------|--------|----------|----------|----------|
| 快速路径 | 无 | 无 | 1 个 isb | ~50 ns |
| 慢速路径 | 1 次加锁/解锁 | 可能 1 次 | 1 个 isb | ~250 ns |

**快速路径占比**：在正常负载下，约 99% 的上下文切换走快速路径。

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
| **性能优先** | 快速路径无锁、ASID 复用、延迟刷新 |
| **正确性保障** | ASID generation、TLB shootdown、内存屏障 |
| **多 CPU 协调** | cpumask 更新、延迟刷新机制 |
| **安全增强** | Spectre 缓解、PAN 保护 |
| **架构适配** | 利用 ARM64 硬件特性（ASID、TTBRx_EL1、CnP） |

**核心设计思想**：通过分层 ASID 管理、延迟刷新和硬件特性利用，在页表切换的正确性和性能之间取得最佳平衡。

---

*本文由 [王孝雷](https://wangxiaolei12.github.io) 原创，转载请注明出处。*