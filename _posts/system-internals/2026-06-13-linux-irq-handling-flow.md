---
layout: post
title: "Linux 中断子系统(2): 中断处理流程 — 从硬件触发到驱动 Handler"
date: 2026-06-13 08:31:00 +0800
excerpt: "Linux 中断的完整处理流程：ARM64 异常向量入口、GIC IAR 读取、irq_desc 分发、流控 handler、驱动 handler 执行、threaded IRQ、softirq 触发。逐函数分析。"
---

# Linux 中断子系统(2): 中断处理流程

---

## 一、完整调用链概览

```
硬件设备产生中断信号
    │
    ▼
GIC 接收，写入 pending 寄存器
    │
    ▼ (IRQ 信号送达 CPU)
CPU 跳转到异常向量表
    │
    ▼
el1_irq / el0_irq (arch/arm64/kernel/entry.S)
    │
    ▼
gic_handle_irq()                    [drivers/irqchip/irq-gic-v3.c]
    ├── 读 ICC_IAR1_EL1 → 获取 hwirq (INTID)
    ├── 如果是 IPI (hwirq < 16) → 处理核间中断
    └── generic_handle_domain_irq(gic_domain, hwirq)
            │
            ▼
    irq_desc = irq_resolve_mapping(domain, hwirq)
            │  通过 domain 的 revmap 找到 virq → irq_desc
            ▼
    generic_handle_irq_desc(desc)
            │
            ▼
    desc->handle_irq(desc)          ← 流控 handler
            │
            ├── handle_fasteoi_irq(desc)
            │       │
            │       ├── handle_irq_event(desc)
            │       │       │
            │       │       └── handle_irq_event_percpu(desc)
            │       │               │
            │       │               └── for each action:
            │       │                       action->handler(irq, dev_id)
            │       │                       ├── IRQ_HANDLED → 完成
            │       │                       ├── IRQ_WAKE_THREAD → 唤醒线程
            │       │                       └── IRQ_NONE → 试下一个 (共享)
            │       │
            │       └── chip->irq_eoi(&desc->irq_data)
            │               └── 写 ICC_EOIR1_EL1 (End of Interrupt)
            │
            └── 返回

el1_irq 返回:
    → irq_exit() → 检查 softirq pending → invoke_softirq()
```

---

## 二、ARM64 异常向量入口

```
// arch/arm64/kernel/entry.S

// 异常向量表 (VBAR_EL1 指向这里):
SYM_CODE_START(vectors)
    // 从 EL1 (内核态) 进来的 IRQ:
    kernel_ventry  el1t_64_irq          // SP_EL0
    kernel_ventry  el1h_64_irq          // SP_EL1 ← 最常见

    // 从 EL0 (用户态) 进来的 IRQ:
    kernel_ventry  el0t_64_irq          // AArch64 用户态
    kernel_ventry  el0t_32_irq          // AArch32 用户态
SYM_CODE_END(vectors)

// el1h_64_irq 处理:
el1h_64_irq:
    kernel_entry 1                      // 保存寄存器到栈 (pt_regs)
    el1_interrupt_handler handle_arch_irq  // 调用 C 函数
    kernel_exit 1                       // 恢复寄存器，eret 返回

// handle_arch_irq 指向 gic_handle_irq (GIC 驱动注册)
```

---

## 三、GIC 中断入口 — gic_handle_irq

```c
// drivers/irqchip/irq-gic-v3.c
static void __exception_irq_entry gic_handle_irq(struct pt_regs *regs)
{
    u32 irqnr;

    irqnr = gic_read_iar();  // ★ 读 ICC_IAR1_EL1，获取硬件中断号

    if (likely(irqnr > 15 && irqnr < 1020)) {
        // 普通外设中断 (SPI/PPI)
        if (generic_handle_domain_irq(gic_data.domain, irqnr))
            WARN_ONCE(...);  // 未映射的中断
        return;
    }

    if (irqnr < 16) {
        // IPI (SGI, 0~15)
        gic_handle_irq_ipi(irqnr, regs);
        return;
    }

    // 1023 = spurious interrupt
    gic_write_eoir(irqnr);  // 直接 EOI
}
```

---

## 四、Domain 查找 — hwirq 到 virq

```c
// kernel/irq/irqdomain.c
int generic_handle_domain_irq(struct irq_domain *domain, irq_hw_number_t hwirq)
{
    struct irq_desc *desc = irq_resolve_mapping(domain, hwirq);
    if (!desc)
        return -EINVAL;
    generic_handle_irq_desc(desc);
    return 0;
}

// 查找 revmap:
static struct irq_desc *irq_resolve_mapping(struct irq_domain *domain,
                                            irq_hw_number_t hwirq)
{
    struct irq_data *data;

    // 线性映射 (hwirq < revmap_size): O(1) 数组直接索引
    if (hwirq < domain->revmap_size)
        data = rcu_dereference(domain->revmap[hwirq]);
    else
        // 大号 hwirq: radix tree 查找
        data = radix_tree_lookup(&domain->revmap_tree, hwirq);

    return data ? irq_data_to_desc(data) : NULL;
}
```

---

## 五、流控 Handler — handle_fasteoi_irq

GIC 使用 fasteoi 模式（硬件自动 ack，软件只需 eoi）：

```c
// kernel/irq/chip.c
void handle_fasteoi_irq(struct irq_desc *desc)
{
    struct irq_chip *chip = desc->irq_data.chip;

    raw_spin_lock(&desc->lock);

    if (!irq_may_run(desc))         // 检查中断是否被 disable
        goto out;

    desc->istate &= ~(IRQS_REPLAY | IRQS_WAITING);

    if (unlikely(!desc->action || irqd_irq_disabled(&desc->irq_data))) {
        desc->istate |= IRQS_PENDING;
        mask_irq(desc);             // mask 掉避免反复触发
        goto out;
    }

    // ★ 执行所有注册的 handler
    if (desc->istate & IRQS_ONESHOT)
        mask_irq(desc);

    handle_irq_event(desc);

out_eoi:
    // ★ 写 EOI 通知 GIC 中断处理完毕
    chip->irq_eoi(&desc->irq_data);

out_unlock:
    raw_spin_unlock(&desc->lock);
}
```

### handle_irq_event — 调用驱动 handler

```c
// kernel/irq/handle.c
irqreturn_t handle_irq_event_percpu(struct irq_desc *desc)
{
    struct irqaction *action = desc->action;
    irqreturn_t retval = IRQ_NONE;

    // ★ 遍历 action 链表（共享中断有多个）
    for_each_action_of_desc(desc, action) {
        irqreturn_t res;

        res = action->handler(desc->irq_data.irq, action->dev_id);
        //    ^^^^^^^^^^^^^^^^ 驱动注册的 handler

        switch (res) {
        case IRQ_HANDLED:
            retval |= IRQ_HANDLED;
            break;
        case IRQ_WAKE_THREAD:
            // 唤醒 threaded handler 内核线程
            irq_wake_thread(desc, action);
            retval |= IRQ_WAKE_THREAD;
            break;
        case IRQ_NONE:
            break;  // 不是这个设备的中断
        }
    }
    return retval;
}
```

---

## 六、Threaded IRQ — 中断线程化

```c
// 驱动注册:
request_threaded_irq(irq, my_hardirq, my_thread_fn, IRQF_ONESHOT, "dev", dev);

// my_hardirq (硬中断上下文):
//   快速检查是否是自己的中断
//   返回 IRQ_WAKE_THREAD → 唤醒线程处理

// my_thread_fn (进程上下文, 可睡眠):
//   执行耗时操作: I2C/SPI 通信, 内存分配...
```

### 线程化处理流程

```
硬中断:
  handle_fasteoi_irq()
    → action->handler() returns IRQ_WAKE_THREAD
    → irq_wake_thread(desc, action)
        → wake_up_process(action->thread)  // 唤醒 irq/N-name 内核线程
    → chip->irq_eoi()  // EOI，但中断仍被 mask (IRQF_ONESHOT)

内核线程 (irq/167-eth0):
  irq_thread()
    → action->thread_fn(irq, dev_id)   // ★ 驱动的 threaded handler
    → irq_finalize_oneshot()
        → unmask_irq(desc)              // 重新 unmask，接收下一个中断
```

---

## 七、中断注册 — request_irq 内部

```c
// kernel/irq/manage.c
int request_threaded_irq(unsigned int irq, irq_handler_t handler,
                         irq_handler_t thread_fn, unsigned long irqflags,
                         const char *devname, void *dev_id)
{
    struct irq_desc *desc = irq_to_desc(irq);
    struct irqaction *action;

    // 分配 irqaction
    action = kzalloc(sizeof(*action), GFP_KERNEL);
    action->handler = handler;
    action->thread_fn = thread_fn;
    action->flags = irqflags;
    action->name = devname;
    action->dev_id = dev_id;

    // 如果有 thread_fn，创建内核线程
    if (thread_fn)
        setup_irq_thread(action, irq);  // 创建 "irq/167-eth0" 线程

    // ★ 将 action 挂到 desc->action 链表
    __setup_irq(irq, desc, action);
    //  → 检查 IRQF_SHARED 兼容性
    //  → irq_startup(desc) → chip->irq_unmask() 使能硬件中断

    return 0;
}
```

---

## 八、中断亲和性 (Affinity)

```c
// 设置中断只在特定 CPU 上处理:
irq_set_affinity(irq, cpumask);
    → chip->irq_set_affinity(data, cpumask, force)
        → GIC: 写 GICD_IROUTER 寄存器，路由到指定 CPU

// 用户空间设置:
echo 2 > /proc/irq/167/smp_affinity   // 绑定到 CPU 1
echo f > /proc/irq/167/smp_affinity   // CPU 0-3 均可
```

---

## 九、完整时序示例

```
时间 ──────────────────────────────────────────────────────────────────▶

硬件                    CPU                       内核线程
─────                   ───                       ────────

网卡收到包
  │ 拉高 IRQ 线
  ▼
GIC 记录 pending
GIC → CPU (IRQ signal)
                    EL1h_irq 入口
                    保存寄存器
                    gic_handle_irq()
                      IAR 读 → hwirq=72
                      domain lookup → virq=167
                      handle_fasteoi_irq()
                        e1000_intr() → 关 DMA 中断
                        return IRQ_WAKE_THREAD
                        wake_up(irq/167-e1000)
                      chip->irq_eoi() (GICD_EOIR)
                    irq_exit()
                      softirq pending? → invoke
                    恢复寄存器, eret
                                                  irq/167-e1000 被唤醒
                                                  e1000_thread_fn()
                                                    NAPI poll 收包
                                                    处理完毕
                                                  unmask_irq()
                                                  → 网卡中断重新使能
```

---

## 十、源文件索引

| 文件 | 内容 |
|------|------|
| `arch/arm64/kernel/entry.S` | 异常向量表，el1_irq 入口 |
| `drivers/irqchip/irq-gic-v3.c` | GICv3: gic_handle_irq, chip ops |
| `kernel/irq/irqdomain.c` | domain: 创建、映射、revmap 查找 |
| `kernel/irq/chip.c` | handle_fasteoi_irq, handle_level_irq |
| `kernel/irq/handle.c` | handle_irq_event, 遍历 action |
| `kernel/irq/manage.c` | request_irq, setup_irq, 线程创建 |
| `kernel/irq/irqdesc.c` | irq_desc 分配 |
| `include/linux/irq.h` | irq_data, irq_chip 定义 |
| `include/linux/interrupt.h` | irqaction, request_irq API |
