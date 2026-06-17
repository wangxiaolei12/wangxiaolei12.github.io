---
layout: post
title: "PREEMPT_RT 中断线程化机制源码深度分析"
date: 2026-06-17 14:30:00 +0800
excerpt: "结合 Linux mainline 源码分析 RT 内核中断线程化的完整实现：force_irqthreads 开关、irq_setup_forced_threading 转换逻辑、irq_thread 线程主循环、IRQF_ONESHOT mask 机制及其对实时性的影响。"
---

# PREEMPT_RT 中断线程化机制源码深度分析

源码：`kernel/irq/manage.c`、`include/linux/interrupt.h`

---

## 1. 核心思想

普通内核中，中断处理在**硬中断上下文**执行（不可抢占、不可睡眠）。RT 内核将中断处理移到**内核线程**中执行：

| | 普通内核 | RT 内核 |
|---|---|---|
| 中断处理上下文 | 硬中断（不可抢占） | 内核线程（可抢占、可睡眠） |
| 对 RT 任务的影响 | 无条件打断，延迟不可控 | 可被更高优先级 RT 任务抢占 |
| 调度优先级 | 无（最高，无条件执行） | SCHED_FIFO，可配置 |

```
普通内核：
    RT 任务运行 → 中断来了 → 强制抢占 → 中断处理（几百μs）→ RT 恢复
                                        ↑ 延迟不可控！

RT 内核：
    RT 任务(优先级99)运行 → 中断来了 → primary handler(几十ns) → 唤醒 irq 线程(优先级50)
                                                                → RT 任务优先级更高，继续运行！
                           → RT 任务让出 CPU → irq 线程才执行
```

---

## 2. 关键开关：force_irqthreads()

```c
// include/linux/interrupt.h
#ifdef CONFIG_IRQ_FORCED_THREADING
# ifdef CONFIG_PREEMPT_RT
#  define force_irqthreads()    (true)         // RT 内核：永远为 true
# else
DECLARE_STATIC_KEY_FALSE(force_irqthreads_key);
#  define force_irqthreads()    (static_branch_unlikely(&force_irqthreads_key))
                                               // 非 RT：通过启动参数控制
# endif
#else
#define force_irqthreads()      (false)        // 不支持
#endif
```

三种情况：

| 配置 | force_irqthreads() | 效果 |
|------|-------------------|------|
| `CONFIG_PREEMPT_RT=y` | **始终 true** | 所有中断强制线程化 |
| 非 RT + 启动参数 `threadirqs` | 运行时 true | 所有中断强制线程化 |
| 都没有 | false | 不线程化 |

启动参数注册：

```c
// kernel/irq/manage.c
DEFINE_STATIC_KEY_FALSE(force_irqthreads_key);

static int __init setup_forced_irqthreads(char *arg)
{
    static_branch_enable(&force_irqthreads_key);
    return 0;
}
early_param("threadirqs", setup_forced_irqthreads);
```

---

## 3. 转换机制：irq_setup_forced_threading()

`__setup_irq()` 中调用，把普通中断强制改造为线程化：

```c
// kernel/irq/manage.c
static int irq_setup_forced_threading(struct irqaction *new)
{
    // 条件1：没开强制线程化 → 不改
    if (!force_irqthreads())
        return 0;

    // 条件2：这些中断不能线程化
    if (new->flags & (IRQF_NO_THREAD | IRQF_PERCPU | IRQF_ONESHOT))
        return 0;

    // 条件3：已经是线程化中断 → 不用改
    if (new->handler == irq_default_primary_handler)
        return 0;

    // ═══════ 执行转换 ═══════

    // 线程处理期间保持中断 mask（防止中断风暴）
    new->flags |= IRQF_ONESHOT;

    // 情况：驱动同时提供了 handler + thread_fn
    if (new->handler && new->thread_fn) {
        // 原来的 thread_fn 放到 secondary 线程
        new->secondary = kzalloc(sizeof(struct irqaction), GFP_KERNEL);
        new->secondary->handler = irq_forced_secondary_handler;
        new->secondary->thread_fn = new->thread_fn;
        new->secondary->dev_id = new->dev_id;
        new->secondary->irq = new->irq;
        new->secondary->name = new->name;
    }

    // 核心替换：
    set_bit(IRQTF_FORCED_THREAD, &new->thread_flags);
    new->thread_fn = new->handler;              // 原 handler → 变成线程函数
    new->handler = irq_default_primary_handler; // 硬中断只做唤醒
    return 0;
}
```

**转换前后对比**：

```
驱动注册：request_irq(irq, my_handler, 0, "mydev", dev)

转换前：
    new->handler  = my_handler        (在硬中断执行)
    new->thread_fn = NULL

转换后：
    new->handler  = irq_default_primary_handler  (硬中断：只唤醒线程)
    new->thread_fn = my_handler                  (在线程中执行)
    new->flags |= IRQF_ONESHOT                   (处理期间 mask 中断)
```

---

## 4. irq_default_primary_handler — 硬中断中的最小工作

```c
// kernel/irq/manage.c
static irqreturn_t irq_default_primary_handler(int irq, void *dev_id)
{
    return IRQ_WAKE_THREAD;  // 唯一作用：告诉内核唤醒中断线程
}
```

整个硬中断阶段只做这一件事——几十纳秒级别。

---

## 5. 中断线程：irq_thread()

```c
// kernel/irq/manage.c
static int irq_thread(void *data)
{
    struct irqaction *action = data;
    struct irq_desc *desc = irq_to_desc(action->irq);
    irqreturn_t (*handler_fn)(...);

    // 设置实时调度策略 SCHED_FIFO
    if (action->handler == irq_forced_secondary_handler)
        sched_set_fifo_secondary(current);   // secondary 线程优先级稍低
    else
        sched_set_fifo(current);              // 默认 SCHED_FIFO 优先级 50

    // 选择处理函数
    if (force_irqthreads() && test_bit(IRQTF_FORCED_THREAD, &action->thread_flags))
        handler_fn = irq_forced_thread_fn;   // 强制线程化版本
    else
        handler_fn = irq_thread_fn;          // 原生线程化版本

    // ═══ 主循环 ═══
    while (!irq_wait_for_interrupt(desc, action)) {
        irqreturn_t action_ret;

        action_ret = handler_fn(desc, action);  // 执行实际中断处理！

        if (action_ret == IRQ_WAKE_THREAD)
            irq_wake_secondary(desc, action);   // 唤醒 secondary 线程

        wake_threads_waitq(desc);
    }

    return 0;
}
```

**线程主循环**：

```
irq_thread 创建后：

    ┌─→ irq_wait_for_interrupt()  ← 睡眠等待（set_current_state(TASK_INTERRUPTIBLE)）
    │            │
    │            ▼ (被唤醒：primary handler 返回 IRQ_WAKE_THREAD)
    │
    │   handler_fn(desc, action)   ← 执行原来的中断处理函数
    │            │
    │            ▼
    │   unmask 中断线               ← 处理完毕，恢复中断
    │            │
    └────────────┘ (循环)
```

---

## 6. 线程创建：setup_irq_thread()

```c
// kernel/irq/manage.c
static int setup_irq_thread(struct irqaction *new, unsigned int irq, bool secondary)
{
    struct task_struct *t;

    if (!secondary) {
        t = kthread_create(irq_thread, new, "irq/%d-%s", irq, new->name);
        // 例如：irq/45-i2c0
    } else {
        t = kthread_create(irq_thread, new, "irq/%d-s-%s", irq, new->name);
        // 例如：irq/45-s-i2c0
    }

    new->thread = get_task_struct(t);
    return 0;
}
```

系统中可见的中断线程：

```bash
$ ps -eo pid,cls,pri,comm | grep irq/
  PID CLS PRI COMMAND
   28  FF  49 irq/28-mmc0      ← SCHED_FIFO, 优先级 50（显示49=内核50-1）
   45  FF  49 irq/45-i2c0
   62  FF  49 irq/62-eth0
```

---

## 7. IRQF_ONESHOT — 为什么要 mask 中断

### 不 mask 的问题（中断风暴）

```
硬中断触发 → primary handler → IRQ_WAKE_THREAD
                                      │
硬件中断源还没清（线程还没跑到）──────── │
                                      │
立即又触发硬中断！→ primary handler → 又唤醒
立即又触发！→ ...
... CPU 被硬中断淹没，线程永远得不到执行
```

### ONESHOT 的正确流程

```
硬中断触发
    │
    ├─ mask 该中断线（屏蔽）
    ├─ irq_default_primary_handler() → IRQ_WAKE_THREAD
    │
    ▼
中断线程被调度执行：
    ├─ my_irq_handler()
    │   ├─ 读硬件寄存器
    │   ├─ 处理数据
    │   └─ 清除硬件中断源
    │
    └─ 内核自动 unmask ← 处理完才放开
    
硬件中断源已清 → unmask 后不会再触发
```

### 会不会丢中断？

**不会丢，但会合并**：

```
时间线：
mask ─────────────────────────────── unmask
      │     │     │                      │
      中断1  中断2  中断3（都 pending）    ├─ 只再触发 1 次
                                         │  （多次合并为一次）
                                         ▼
                                   再走一遍处理流程
```

- 中断控制器（GIC）会把 mask 期间的中断挂起（pending）
- unmask 后，pending 的中断立即触发
- 电平触发：只要源还在 assert 就会再触发
- 边沿触发：可能多次合并为一次（丢不了第一次，但分不清几次）

### 对延迟的影响

```
如果中断线程被高优先级任务抢占很久：

mask ──→ [线程等待调度 10ms] ──→ 线程执行 ──→ unmask

这 10ms 内该中断线所有新中断都被屏蔽！
```

这就是 RT 系统必须**合理设置中断线程优先级**的原因。

---

## 8. 不能线程化的中断

```c
if (new->flags & (IRQF_NO_THREAD | IRQF_PERCPU | IRQF_ONESHOT))
    return 0;  // 跳过，不线程化
```

| 标志 | 原因 |
|------|------|
| `IRQF_NO_THREAD` | 驱动明确声明不可线程化 |
| `IRQF_PERCPU` | per-CPU 中断（如 timer、IPI） |
| `IRQF_ONESHOT` | 已经是线程化中断了 |

典型不可线程化的中断：
- **定时器 tick** — 调度器本身依赖它
- **IPI（核间中断）** — 必须立即响应（SMP 同步）
- **NMI** — 不可屏蔽中断
- **架构相关的关键中断** — 如 PMU、watchdog

---

## 9. 优先级配置

默认所有中断线程优先级相同（SCHED_FIFO 50），实际 RT 系统需要手动调整：

```bash
# 查看中断线程优先级
ps -eo pid,cls,rtprio,comm | grep irq/

# 提升关键中断优先级（如网卡）
chrt -f -p 90 $(pgrep "irq/62-eth0")

# 降低非关键中断优先级
chrt -f -p 20 $(pgrep "irq/28-mmc0")
```

**优先级设置原则**：

```
优先级高
  │  99: 最关键的 RT 应用任务
  │  90: 该 RT 任务依赖的中断（如传感器采集）
  │  80: 通信中断（网卡、串口）
  │  50: 默认中断线程（大多数设备）
  │  20: 非关键中断（存储、USB）
  │   1: 后台 RT 任务
优先级低
```

---

## 10. 完整数据流总图

```
┌──────────────────────────────────────────────────────────────────┐
│ 驱动注册中断                                                      │
│                                                                  │
│ request_irq(irq, my_handler, 0, "mydev", dev)                    │
│     │                                                            │
│     ▼                                                            │
│ request_threaded_irq(irq, my_handler, NULL, 0, "mydev", dev)     │
│     │                                                            │
│     ▼                                                            │
│ __setup_irq(irq, desc, action)                                   │
│     │                                                            │
│     ├─ irq_setup_forced_threading(action)  ← RT 内核核心！        │
│     │     │                                                      │
│     │     ├─ action->thread_fn = action->handler  (偷梁换柱)     │
│     │     ├─ action->handler = irq_default_primary_handler       │
│     │     └─ action->flags |= IRQF_ONESHOT                      │
│     │                                                            │
│     └─ setup_irq_thread(action, irq)                             │
│           └─ kthread_create(irq_thread, ..., "irq/%d-%s")        │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ 运行时中断触发                                                    │
│                                                                  │
│ 硬件中断 →                                                       │
│     │                                                            │
│     ▼                                                            │
│ [硬中断上下文 - 几十 ns]                                          │
│     ├─ mask 中断线（IRQF_ONESHOT）                                │
│     ├─ irq_default_primary_handler()                             │
│     │     └─ return IRQ_WAKE_THREAD                              │
│     └─ __irq_wake_thread()                                       │
│           └─ wake_up_process(action->thread)                     │
│                                                                  │
│     ▼                                                            │
│ [调度器选择] — irq 线程 vs 其他 RT 任务，按优先级决定              │
│                                                                  │
│     ▼ (irq 线程被调度)                                            │
│ [irq_thread 内核线程 - SCHED_FIFO]                                │
│     ├─ handler_fn(desc, action)                                  │
│     │     └─ my_handler(irq, dev)  ← 真正的中断处理              │
│     │           ├─ 读寄存器                                       │
│     │           ├─ 处理数据                                       │
│     │           └─ 清中断源                                       │
│     │                                                            │
│     └─ unmask 中断线 ← 处理完毕，恢复                             │
│                                                                  │
│ 回到 irq_wait_for_interrupt() 等待下一次                          │
└──────────────────────────────────────────────────────────────────┘
```
