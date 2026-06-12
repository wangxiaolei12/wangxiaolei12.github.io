---
layout: post
title: "Linux 软中断 (Softirq) 机制：处理流程与触发时机"
date: 2026-06-12 10:30:00 +0800
excerpt: "深入分析 Linux 内核软中断机制，包括 10 种 softirq 类型、3 个处理时机（irq_exit/local_bh_enable/ksoftirqd）、核心函数 handle_softirqs() 的执行逻辑，以及限时/限次策略。基于最新 mainline 源码。"
---

# Linux 软中断 (Softirq) 机制：处理流程与触发时机

基于 mainline `kernel/softirq.c` 源码分析

---

## 一、软中断类型

```c
enum {
    HI_SOFTIRQ = 0,       // 高优先级 tasklet
    TIMER_SOFTIRQ,        // 定时器
    NET_TX_SOFTIRQ,       // 网络发送
    NET_RX_SOFTIRQ,       // 网络接收
    BLOCK_SOFTIRQ,        // 块设备
    IRQ_POLL_SOFTIRQ,     // IRQ 轮询
    TASKLET_SOFTIRQ,      // 普通 tasklet
    SCHED_SOFTIRQ,        // 调度器负载均衡
    HRTIMER_SOFTIRQ,      // 高精度定时器
    RCU_SOFTIRQ,          // RCU (总是最后)
    NR_SOFTIRQS           // = 10
};
```

核心数据结构：
- `softirq_vec[NR_SOFTIRQS]` — 处理函数数组
- 每 CPU 一个 `pending` 位图：`local_softirq_pending()`
- 每 CPU 一个 `ksoftirqd/N` 内核线程

---

## 二、软中断的 3 个处理时机

```
┌─────────────────────────────────────────────────────────────────────┐
│  ① 硬中断退出时 (irq_exit)          ◀── 最主要的执行时机           │
│  ② local_bh_enable() 重新使能时     ◀── 进程上下文                 │
│  ③ ksoftirqd 内核线程调度执行时     ◀── 负载过重时延迟处理         │
└─────────────────────────────────────────────────────────────────────┘
```

### 时机 ①：硬中断退出 — irq_exit()

```
硬件中断发生
    │
    ▼
irq_enter()                        // preempt_count += HARDIRQ_OFFSET
    │
    ▼
[执行硬中断 handler，可能 raise_softirq()]
    │
    ▼
irq_exit() → __irq_exit_rcu()
    │
    ├── preempt_count_sub(HARDIRQ_OFFSET)
    │
    └── if (!in_interrupt() && local_softirq_pending())
            │
            ▼
        invoke_softirq()
            ├── [非 threadirqs] → __do_softirq()  // 直接在中断栈执行
            └── [threadirqs]   → wakeup_softirqd()
```

**条件**：退出最外层硬中断（`!in_interrupt()`）且有 pending softirq。

### 时机 ②：local_bh_enable()

```
__local_bh_enable_ip()
    │
    └── if (!in_interrupt() && local_softirq_pending())
            └── do_softirq()      // 在进程上下文中处理
```

### 时机 ③：ksoftirqd 线程

```
run_ksoftirqd(cpu)
    ├── local_irq_disable()
    ├── if (local_softirq_pending())
    │       └── handle_softirqs(true)
    └── local_irq_enable()
        cond_resched()
```

ksoftirqd 被唤醒的场景：
- `handle_softirqs()` 循环超时（>2ms 或 >10 次）
- `raise_softirq()` 在进程上下文调用
- `force_irqthreads` 模式下

---

## 三、核心函数 handle_softirqs()

```
handle_softirqs(bool ksirqd)
    │
    ├── pending = local_softirq_pending()
    ├── softirq_handle_begin()        // 标记 in_serving_softirq
    │
restart: ◀────────────────────────── 循环点
    │
    ├── set_softirq_pending(0)        // 清 pending（新 raise 的会重新设置）
    ├── local_irq_enable()            // ★ 开中断！允许硬中断嵌套
    │
    ├── while ((softirq_bit = ffs(pending))) {
    │       h->action();              // ★ 执行 softirq handler
    │       pending >>= softirq_bit;
    │   }
    │
    ├── local_irq_disable()           // 关中断检查新 pending
    ├── pending = local_softirq_pending()
    │
    └── if (pending) {
            if (未超时 && !need_resched() && 次数<10)
                goto restart;         // 继续处理
            else
                wakeup_softirqd();    // 交给 ksoftirqd
        }
```

**限制策略**：最多 **2ms** 或 **10 次循环**，防止 softirq 独占 CPU。

---

## 四、软中断的触发 — raise_softirq()

```
raise_softirq(nr)
    ├── local_irq_save()
    ├── or_softirq_pending(1UL << nr)    // 设置 pending 位
    ├── if (!in_interrupt())
    │       └── wakeup_softirqd()        // 进程上下文直接唤醒
    └── local_irq_restore()
```

| 场景 | 调用 |
|------|------|
| 网卡中断收包 | `raise_softirq(NET_RX_SOFTIRQ)` |
| 定时器到期 | `raise_softirq(TIMER_SOFTIRQ)` |
| 调度器负载均衡 | `raise_softirq(SCHED_SOFTIRQ)` |
| tasklet_schedule() | `raise_softirq(TASKLET_SOFTIRQ)` |
| RCU grace period | `raise_softirq(RCU_SOFTIRQ)` |

---

## 五、整体时序

```
时间 ────────────────────────────────────────────────────────────▶

硬中断              Softirq 上下文             进程上下文
────────            ─────────────             ──────────

网卡中断 ──┐
           │
 irq_enter()
 napi_schedule()
 raise(NET_RX)
 irq_exit() ───────▶ invoke_softirq()
                      __do_softirq()
                        开中断
                        net_rx_action()
                          napi_poll()
                          收取报文
                        关中断
                        检查 pending
                      (超时/超次数)
                      wakeup_softirqd() ─────▶ ksoftirqd 被唤醒
                                               handle_softirqs()
                                               处理剩余 pending
                                               cond_resched()
```

---

## 六、设计要点

| 特性 | 说明 |
|------|------|
| 不可睡眠 | handler 中禁止调用可能睡眠的函数 |
| 可被硬中断打断 | 处理期间开中断 |
| 同类可多 CPU 并行 | 不同 CPU 可同时执行同一 softirq handler |
| 不可嵌套自身 | `SOFTIRQ_OFFSET` 防止递归 |
| 限时限次 | 2ms / 10 次，超限交给 ksoftirqd |
| per-CPU pending | 无跨 CPU 锁竞争 |
| RT 差异 | `PREEMPT_RT` 下全部在线程中执行 |

---

## 七、源文件

| 文件 | 内容 |
|------|------|
| `kernel/softirq.c` | handle_softirqs, irq_exit, raise_softirq, ksoftirqd |
| `include/linux/interrupt.h` | softirq 枚举, NR_SOFTIRQS |
| `include/linux/preempt.h` | in_interrupt(), in_softirq() |
| `net/core/dev.c` | net_rx_action(), net_tx_action() |
| `kernel/time/timer.c` | run_timer_softirq() |
| `kernel/sched/fair.c` | run_rebalance_domains() |
| `kernel/rcu/tree.c` | rcu_core_si() |
