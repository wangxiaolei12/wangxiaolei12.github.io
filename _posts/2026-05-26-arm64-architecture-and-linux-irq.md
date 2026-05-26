---
layout: post
title: "ARM64 体系架构与 Linux 中断处理全路径分析"
date: 2026-05-26 20:00:00 +0800
excerpt: "详解 ARM64 异常级别、MMU 页表、Cache 体系、GIC 中断控制器，以及 Linux 内核从异常向量表到驱动 handler 的完整中断处理代码路径。"
---

# ARM64 体系架构与 Linux 中断处理全路径分析

## 一、异常级别与寄存器

### 1.1 异常级别

```
┌─────────────────────────────────────────┐
│  EL3 - Secure Monitor (ATF/TF-A)       │  ← 最高特权，安全世界切换
├─────────────────────────────────────────┤
│  EL2 - Hypervisor (KVM)                │  ← 虚拟化
├─────────────────────────────────────────┤
│  EL1 - OS Kernel (Linux)               │  ← 内核态
├─────────────────────────────────────────┤
│  EL0 - User Application                │  ← 用户态
└─────────────────────────────────────────┘
```

### 1.2 关键系统寄存器

| 寄存器 | 功能 |
|--------|------|
| `SCTLR_EL1` | 系统控制（MMU/Cache 使能） |
| `TCR_EL1` | 翻译控制（页大小、地址宽度） |
| `TTBR0_EL1` | 用户空间页表基地址 |
| `TTBR1_EL1` | 内核空间页表基地址 |
| `MAIR_EL1` | 内存属性索引 |
| `ESR_EL1` | 异常综合寄存器（异常原因） |
| `FAR_EL1` | 故障地址寄存器 |
| `VBAR_EL1` | 异常向量表基地址 |
| `DAIF` | 中断屏蔽位 |
| `SPSR_EL1` | 保存的程序状态 |
| `ELR_EL1` | 异常返回地址 |


## 二、MMU

### 2.1 虚拟地址空间划分

```
0x0000_0000_0000_0000 ┌──────────────────┐
                      │  用户空间 (256TB) │  ← TTBR0_EL1
0x0000_FFFF_FFFF_FFFF ├──────────────────┤
                      │  非规范地址空洞    │
0xFFFF_0000_0000_0000 ├──────────────────┤
                      │  内核空间 (256TB) │  ← TTBR1_EL1
0xFFFF_FFFF_FFFF_FFFF └──────────────────┘

bit[63]=0 → TTBR0    bit[63]=1 → TTBR1
```

### 2.2 4级页表（4KB粒度）

```
虚拟地址 (48-bit):
┌────────┬────────┬────────┬────────┬────────────┐
│L0[8:0] │L1[8:0] │L2[8:0] │L3[8:0] │Offset[11:0]│
│ 9 bits │ 9 bits │ 9 bits │ 9 bits │  12 bits   │
└────┬───┴────┬───┴────┬───┴────┬───┴────────────┘
     ▼        ▼        ▼        ▼
   PGD      PUD      PMD      PTE → 物理页(4KB)
```

映射粒度：L1=1GB Block, L2=2MB Block, L3=4KB Page

### 2.3 页表项格式

```
┌─────────────────────────────────────────────────────────┐
│63  59│58 55│54 52│51    12│11        2│1│0│
├──────┼─────┼─────┼────────┼───────────┼─┼─┤
│ PBHA │ SW  │UXN  │输出地址 │  属性位    │T│V│
│      │     │PXN  │[51:12] │           │ │ │
└──────┴─────┴─────┴────────┴───────────┴─┴─┘
属性位: AttrIndx[2:0], AP[2:1], SH[1:0], AF, nG
```

### 2.4 ASID

```
TTBR0_EL1: [ASID(16-bit) | 页表基地址]
- 每个进程唯一 ASID，TLB 条目带 ASID 标记
- 进程切换只需更新 TTBR0，无需 flush 整个 TLB
```

## 三、Cache 体系

### 3.1 层次结构

```
┌───────┐     ┌───────┐
│ Core 0│     │ Core 1│
│┌─────┐│     │┌─────┐│
││L1-I ││     ││L1-I ││  ← 32-64KB
│├─────┤│     │├─────┤│
││L1-D ││     ││L1-D ││  ← 32-64KB
│└──┬──┘│     │└──┬──┘│
│┌──▼──┐│     │┌──▼──┐│
││ L2  ││     ││ L2  ││  ← 256KB-1MB
│└──┬──┘│     │└──┬──┘│
└───┼───┘     └───┼───┘
    └──────┬──────┘
     ┌─────▼─────┐
     │  L3 共享   │  ← 4-32MB
     └─────┬─────┘
           ▼
        主存 DRAM
```

### 3.2 内存属性（MAIR）

| 属性 | 编码 | 用途 |
|------|------|------|
| Normal-WB | 0xFF | 普通 RAM（最常用） |
| Normal-NC | 0x44 | DMA 缓冲区 |
| Device-nGnRnE | 0x00 | MMIO 寄存器 |

### 3.3 Cache 维护指令

```
DC CIVAC, Xt    // Clean+Invalidate（刷回内存+无效化）
DC CVAC, Xt     // Clean（仅刷回内存）
DC IVAC, Xt     // Invalidate（仅无效化）
IC IALLU        // Invalidate 所有指令缓存
```

### 3.4 内存屏障

```
DMB ISH     // 数据内存屏障（smp_mb）
DSB ISH     // 数据同步屏障（TLB/Cache维护后）
ISB         // 指令同步屏障（刷流水线）
LDAR/STLR   // Load-Acquire / Store-Release
```


## 四、GIC 中断控制器

### 4.1 GICv3 架构

```
┌─────────────────────────────────────────┐
│          GIC Distributor (GICD)          │  ← 全局，中断路由/优先级
├─────────────────────────────────────────┤
│    ┌────────┐  ┌────────┐  ┌────────┐  │
│    │ GICR 0 │  │ GICR 1 │  │ GICR 2 │  │  ← Per-CPU Redistributor
│    └───┬────┘  └───┬────┘  └───┬────┘  │
│    ┌───▼────┐  ┌───▼────┐  ┌───▼────┐  │
│    │ICC_*   │  │ICC_*   │  │ICC_*   │  │  ← CPU Interface (系统寄存器)
│    └───┬────┘  └───┬────┘  └───┬────┘  │
│        ▼           ▼           ▼        │
│     Core 0      Core 1      Core 2     │
└─────────────────────────────────────────┘
```

### 4.2 中断类型

| 类型 | ID 范围 | 说明 |
|------|---------|------|
| SGI | 0-15 | 软件生成（IPI 核间通信） |
| PPI | 16-31 | 私有外设（定时器、PMU） |
| SPI | 32-1019 | 共享外设（UART、网卡） |
| LPI | 8192+ | 消息中断（PCIe MSI） |

## 五、Linux 中断处理完整路径

### 5.1 异常向量表

```c
// arch/arm64/kernel/entry.S
SYM_CODE_START(vectors)
    kernel_ventry  1, h, 64, sync     // +0x200 内核态同步异常
    kernel_ventry  1, h, 64, irq      // +0x280 内核态 IRQ ★
    kernel_ventry  1, h, 64, fiq      // +0x300 内核态 FIQ
    kernel_ventry  1, h, 64, error    // +0x380 内核态 SError

    kernel_ventry  0, t, 64, sync     // +0x400 用户态同步异常(syscall)
    kernel_ventry  0, t, 64, irq      // +0x480 用户态 IRQ ★
    kernel_ventry  0, t, 64, fiq      // +0x500
    kernel_ventry  0, t, 64, error    // +0x580
SYM_CODE_END(vectors)
```

### 5.2 汇编入口

```asm
// kernel_ventry: 128字节对齐，栈溢出检测后跳转
// entry_handler: 保存寄存器 + 调用 C handler

.macro entry_handler el, ht, regsize, label
    kernel_entry \el, \regsize    // 保存 x0-x29, LR, SP, PC, PSTATE
    mov   x0, sp                  // pt_regs 指针作为参数
    bl    el\el\ht_\regsize_\label_handler  // 调用 C 函数
    b     ret_to_kernel / ret_to_user
.endm
```

`kernel_entry` 保存的内容：

```asm
stp  x0, x1, [sp, #16 * 0]      // 保存 x0-x29
...
stp  x28, x29, [sp, #16 * 14]
mrs  x22, elr_el1               // 保存返回地址
mrs  x23, spsr_el1              // 保存 PSTATE
stp  x22, x23, [sp, #S_PC]
```

### 5.3 C 层处理（entry-common.c）

```c
// 内核态 IRQ
asmlinkage void noinstr el1h_64_irq_handler(struct pt_regs *regs)
{
    el1_interrupt(regs, handle_arch_irq);
}

static void __el1_irq(struct pt_regs *regs, void (*handler)(struct pt_regs *))
{
    irqentry_state_t state = arm64_enter_from_kernel_mode(regs);
    irq_enter_rcu();                    // preempt_count += HARDIRQ_OFFSET
    do_interrupt_handler(regs, handler); // 切换 IRQ 栈，调用 GIC handler
    irq_exit_rcu();                     // 处理 softirq
    arm64_exit_to_kernel_mode(regs, state);
}

// 用户态 IRQ
static void el0_interrupt(struct pt_regs *regs, void (*handler)(struct pt_regs *))
{
    arm64_enter_from_user_mode(regs);
    irq_enter_rcu();
    do_interrupt_handler(regs, handler);
    irq_exit_rcu();
    arm64_exit_to_user_mode(regs);      // 检查信号/调度
}

// IRQ 栈切换
static void do_interrupt_handler(struct pt_regs *regs, void (*handler)(struct pt_regs *))
{
    if (on_thread_stack())
        call_on_irq_stack(regs, handler);  // 切到独立 IRQ 栈
    else
        handler(regs);
}
```

### 5.4 GIC 驱动层

```c
// drivers/irqchip/irq-gic-v3.c
// 初始化: set_handle_irq(gic_handle_irq)

static void __gic_handle_irq(u32 irqnr, struct pt_regs *regs)
{
    gic_complete_ack(irqnr);            // 写 ICC_EOIR1_EL1 (EOI)
    generic_handle_domain_irq(gic_data.domain, irqnr);  // → 通用层
}

static void __gic_handle_irq_from_irqson(struct pt_regs *regs)
{
    u32 irqnr = gic_read_iar();         // 读 ICC_IAR1_EL1 (ACK+获取中断号)
    bool is_nmi = gic_rpr_is_nmi_prio();

    if (is_nmi) { nmi_enter(); __gic_handle_nmi(irqnr, regs); nmi_exit(); }
    gic_pmr_mask_irqs();                // 屏蔽普通IRQ，允许NMI嵌套
    gic_arch_enable_irqs();
    if (!is_nmi) __gic_handle_irq(irqnr, regs);
}
```

### 5.5 通用中断层

```c
// kernel/irq/irqdesc.h
generic_handle_irq_desc(desc) → desc->handle_irq(desc)

// kernel/irq/chip.c - GIC 最常用的流控函数
void handle_fasteoi_irq(struct irq_desc *desc)
{
    raw_spin_lock(&desc->lock);
    kstat_incr_irqs_this_cpu(desc);
    handle_irq_event(desc);             // 调用驱动 handler
    cond_unmask_eoi_irq(desc, chip);    // EOI
    raw_spin_unlock(&desc->lock);
}

// kernel/irq/handle.c
irqreturn_t __handle_irq_event_percpu(struct irq_desc *desc)
{
    for_each_action_of_desc(desc, action) {
        res = action->handler(irq, action->dev_id);  // ★ 驱动 handler
        if (res == IRQ_WAKE_THREAD)
            __irq_wake_thread(desc, action);          // 唤醒中断线程
    }
}
```

### 5.6 核心数据结构

```c
struct irq_desc {
    struct irq_data      irq_data;      // hwirq, chip
    irq_flow_handler_t   handle_irq;    // handle_fasteoi_irq 等
    struct irqaction     *action;       // 驱动 handler 链表
    raw_spinlock_t       lock;
};

struct irqaction {
    irq_handler_t        handler;       // 硬中断函数
    irq_handler_t        thread_fn;     // 线程化函数
    struct task_struct   *thread;       // 中断线程
    void                 *dev_id;
    unsigned int         flags;         // IRQF_SHARED 等
};
```

### 5.7 完整调用链

```
硬件中断 → GIC 路由到 CPU
  │
  ▼ CPU 跳转 VBAR_EL1+0x280
kernel_ventry 1,h,64,irq              [entry.S]
  │ kernel_entry 1 (保存寄存器)
  ▼
el1h_64_irq_handler(pt_regs)          [entry-common.c]
  │ irq_enter_rcu()
  ▼
do_interrupt_handler → call_on_irq_stack
  ▼
gic_handle_irq(regs)                  [irq-gic-v3.c]
  │ irqnr = gic_read_iar()  (ACK)
  │ gic_complete_ack()       (EOI)
  ▼
generic_handle_domain_irq(domain, hwirq)
  ▼
desc->handle_irq(desc)                [chip.c]
  │ = handle_fasteoi_irq()
  ▼
handle_irq_event → action->handler(irq, dev_id)  ← 驱动代码
  │
  │ 返回 IRQ_WAKE_THREAD → 唤醒中断线程
  ▼
irq_exit_rcu()                        [softirq.c]
  │ invoke_softirq() (如有 pending)
  ▼
ret_to_kernel: kernel_exit 1 → ERET   [entry.S]
```

### 5.8 中断线程化示例

```c
static irqreturn_t my_hardirq(int irq, void *dev_id)
{
    writel(IRQ_CLEAR, dev->regs + STATUS);  // 快速清中断
    return IRQ_WAKE_THREAD;
}

static irqreturn_t my_thread_fn(int irq, void *dev_id)
{
    // 可睡眠，做耗时处理
    process_data(dev);
    return IRQ_HANDLED;
}

request_threaded_irq(irq, my_hardirq, my_thread_fn,
                     IRQF_ONESHOT, "my-dev", dev);
```
