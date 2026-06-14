---
layout: post
title: "Linux 进程调度（一）：调度框架与调度时机"
date: 2026-06-14 19:00:00 +0800
excerpt: "以运行队列 (rq) 为中心，深入分析 Linux 调度器的整体框架：入队 (enqueue)、出队 (dequeue)、选择进程 (pick_next_task)，以及调度的触发时机——何时设置 TIF_NEED_RESCHED、何时真正执行 schedule()。结合 ARM64 entry.S 和 kernel/sched/core.c 源码。"
---

# Linux 进程调度（一）：调度框架与调度时机

基于 mainline `kernel/sched/core.c` 及 ARM64 `arch/arm64/kernel/entry.S` 源码分析

---

## 一、调度的核心：运行队列 (rq)

**rq (runqueue)** 是本 CPU 上所有可运行进程的队列集合。

- 每个 CPU 每种类型的 rq（CFS/RT/DL）只有一个
- 一个 rq 包含多个 runnable 的 task
- rq 当前正在运行的进程 (`rq->curr`) 只有一个

```
┌─────────────────────────────────────────────────┐
│              Per-CPU Run Queue (rq)              │
│                                                 │
│  rq->curr ──────▶ [当前运行的进程]               │
│                                                 │
│  rq->cfs  ──────▶ CFS 红黑树 (多个 runnable)    │
│  rq->rt   ──────▶ RT 优先级链表 (多个 runnable)  │
│  rq->dl   ──────▶ DL 红黑树 (多个 runnable)     │
└─────────────────────────────────────────────────┘
```

既然 rq 是中心，那么以下几点就是 **关键路径**：

1. 什么时候 task 入 rq？（enqueue）
2. 什么时候 task 出 rq？（dequeue）
3. rq 怎样从多个 runnable tasks 中选取一个作为 current running task？（pick_next_task）

理解了这三个关键路径，你就对 Linux 进程调度框架有了清晰的认识。

---

## 二、入 rq（enqueue）

只有 task **新创建** 或者 task 从 **blocked 状态被唤醒 (wakeup)** 时，task 才会被压入 rq。

### 2.1 步骤

```
try_to_wake_up(task)
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 步骤1：把 task 压入 rq (enqueue_task)             │
│        且把 task->state 设置为 TASK_RUNNING       │
├──────────────────────────────────────────────────┤
│ 步骤2：判断新 task 入队后的负载情况                 │
│        当前 task 需不需要被调度出去？               │
│        → 如果需要：设置 TIF_NEED_RESCHED 标志      │
│        → 注意：这里不会马上调用 schedule()！        │
├──────────────────────────────────────────────────┤
│ 步骤3：等待中断/异常发生并返回                      │
│        返回时检查 TIF_NEED_RESCHED                │
│        → 有置位则调用 schedule() 进行调度          │
└──────────────────────────────────────────────────┘
```

### 2.2 为什么唤醒时不马上调用 schedule()？

**重点：唤醒时只设置 TIF_NEED_RESCHED 标志，不会立即调度。真正的调度发生在中断/异常返回时。**

原因：
1. **唤醒经常在中断上下文中执行**，在中断上下文中直接调用 `schedule()` 是不允许的
2. **维护非抢占内核的传统**，不轻易中断进程的处理逻辑，除非进程主动放弃
3. 在普通进程上下文中，唤醒后接着调用 `schedule()` 其实是可以的——某些特殊函数就是这么干的（如 `smp_send_reschedule()`、`resched_curr()` 配合 `preempt_schedule()`）

### 2.3 源码：try_to_wake_up 关键路径

```c
try_to_wake_up(struct task_struct *p, unsigned int state, int wake_flags)
{
    // ...
    activate_task(rq, p, en_flags);    // 步骤1：enqueue
    
    check_preempt_curr(rq, p, ...);    // 步骤2：检查是否需要抢占当前进程
    // → 内部调用 resched_curr(rq) 设置 TIF_NEED_RESCHED
}
```

---

## 三、出 rq（dequeue）

在当前进程调用系统函数进入 **blocked 状态** 时，task 会出 rq。

### 3.1 步骤

```
当前进程主动 block（如 mutex_lock、wait_event、msleep）
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 步骤1：当前进程把 task->state 设置为              │
│        TASK_INTERRUPTIBLE / TASK_UNINTERRUPTIBLE  │
├──────────────────────────────────────────────────┤
│ 步骤2：立即调用 schedule() 进行调度               │
│        （注意：这里是立即调用！）                   │
├──────────────────────────────────────────────────┤
│ 步骤3：schedule() 内部判断 task->state 非         │
│        TASK_RUNNING，执行 dequeue 操作            │
│        然后调度其他进程到 rq->curr                 │
└──────────────────────────────────────────────────┘
```

### 3.2 block 与 wakeup 的关键区别

| | block | wakeup / scheduler_tick |
|--|-------|------------------------|
| 调度方式 | **立即**调用 `schedule()` | 只设置 `TIF_NEED_RESCHED`，等中断返回时才调度 |
| 原因 | 进程主动放弃 CPU，必须马上切走 | 在中断上下文中，不能直接 schedule |

### 3.3 典型 block 代码模式

```c
// mutex_lock 内部简化逻辑：
void mutex_lock(struct mutex *lock)
{
    if (!try_lock(lock)) {
        set_current_state(TASK_UNINTERRUPTIBLE);  // 步骤1
        schedule();                                // 步骤2：立即调度
        // 被唤醒后回到这里继续
    }
}
```

---

## 四、定时调度（scheduler_tick）

除了 enqueue/dequeue 时刻，系统还会 **周期性** 计算 rq 负载来决定是否调度，确保多进程在一个 CPU 上都能得到服务。

### 4.1 步骤

```
每1 tick，local timer 产生中断
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 步骤1：中断中调用 scheduler_tick()                │
│        计算 rq 的负载，判断是否需要重新调度        │
├──────────────────────────────────────────────────┤
│ 步骤2：如果当前进程需要被调度                      │
│        → 设置 TIF_NEED_RESCHED 标志               │
├──────────────────────────────────────────────────┤
│ 步骤3：local timer 中断返回时                     │
│        检查 TIF_NEED_RESCHED                      │
│        → 有置位则调用 schedule()                  │
└──────────────────────────────────────────────────┘
```

### 4.2 举例

假设 CFS 上有进程 A 和 B，时间片约 4ms（取决于 vruntime）：

```
时间线:
 0ms      4ms      8ms
  A────────┤B────────┤A────────┤...
           │         │
           │ tick 中断，scheduler_tick() 发现
           │ A 的 vruntime > B 的 vruntime
           │ → resched_curr() 设置 TIF_NEED_RESCHED
           │ → 中断返回时 schedule()
           │ → pick_next_task 选中 B
           │
           └── context_switch(A → B)
```

---

## 五、选择下一个进程（pick_next_task）

### 5.1 调度类优先级链

```c
// pick_next_task() 的逻辑：按优先级遍历调度类
for_each_class(class) {    // stop → dl → rt → cfs → idle
    p = class->pick_next_task(rq);
    if (p)
        return p;
}
```

| 优先级 | 调度类 | 说明 |
|--------|--------|------|
| 最高 | stop_sched_class | 内核 migration 线程 |
| 高 | dl_sched_class | SCHED_DEADLINE |
| 中高 | rt_sched_class | SCHED_FIFO / SCHED_RR |
| 中 | fair_sched_class | SCHED_NORMAL (CFS) |
| 最低 | idle_sched_class | idle 进程 |

**规则：高优先级调度类永远优先。只有高优先级没有可运行 task 时，才轮到低优先级。**

### 5.2 举例

系统上同时有 1 个 SCHED_FIFO 进程和 10 个 SCHED_NORMAL 进程：

- RT 进程在运行时，CFS 的 10 个进程**全部得不到 CPU**
- 只有 RT 进程睡眠或让出时，CFS 进程才有机会

---

## 六、__schedule() 核心函数

所有调度路径最终汇聚到 `__schedule()`：

```c
static void __sched notrace __schedule(int sched_mode)
{
    struct task_struct *prev, *next;
    bool preempt = sched_mode == SM_PREEMPT;

    cpu = smp_processor_id();
    rq = cpu_rq(cpu);
    prev = rq->curr;

    // 1. 关中断、锁 rq
    local_irq_disable();
    rq_lock(rq, &rf);
    update_rq_clock(rq);

    // 2. 处理 prev 进程：如果不是抢占且 state != RUNNING → dequeue
    if (!preempt && prev_state) {
        try_to_block_task(rq, prev, ...);  // dequeue
        switch_count = &prev->nvcsw;       // 主动切换计数
    }

    // 3. 选择下一个进程
    next = pick_next_task(rq, ...);

    // 4. 上下文切换
    if (prev != next) {
        rq->curr = next;
        context_switch(rq, prev, next, &rf);
    }
}
```

### 关键：preempt 参数的作用

```c
if (!preempt && prev_state) {
    // 只有"非抢占 + 进程非 RUNNING"才 dequeue
    deactivate_task(rq, prev, DEQUEUE_SLEEP);
}
```

为什么抢占时不 dequeue？看下面的"PREEMPT_ACTIVE 问题"。

---

## 七、PREEMPT_ACTIVE 与 preempt 参数

### 7.1 问题场景

```c
for (;;) {
    prepare_to_wait(&wq, &__wait, TASK_UNINTERRUPTIBLE);  // state = UNINTERRUPTIBLE
    if (condition)
        break;          // ← 如果这里发生抢占！
    schedule();
}
finish_wait();          // 恢复 TASK_RUNNING
```

假设在 `break` 处发生抢占：
1. 此时进程 state 已经是 `TASK_UNINTERRUPTIBLE`
2. 抢占调用 `schedule()` → 发现 state 非 RUNNING → dequeue
3. 但进程本意是退出循环恢复 RUNNING！结果被错误地移出队列，可能再也无法被唤醒

### 7.2 解决

**抢占路径调用 `__schedule(SM_PREEMPT)`**，schedule 内部判断是抢占则 **不做 dequeue**：

```c
// 新内核用参数代替了老内核的 PREEMPT_ACTIVE 标志
static void __schedule(int sched_mode)
{
    bool preempt = sched_mode == SM_PREEMPT;

    if (!preempt && prev_state) {   // 抢占时跳过 dequeue！
        deactivate_task(rq, prev, ...);
    }
}
```

老内核的做法（已废弃）：

```c
// 老内核：抢占前设置 PREEMPT_ACTIVE 标志
add_preempt_count(PREEMPT_ACTIVE);
schedule();
sub_preempt_count(PREEMPT_ACTIVE);

// schedule() 内部检查：
if (prev->state && !(preempt_count() & PREEMPT_ACTIVE)) {
    deactivate_task(prev, rq);  // 有 PREEMPT_ACTIVE 就跳过
}
```

---

## 八、中断/异常返回——真正的调度执行点

wakeup 和 scheduler_tick 只设置 `TIF_NEED_RESCHED`，真正执行 schedule() 的时机在 **中断/异常返回**。

在 ARM64 架构中（EL0=用户态，EL1=内核态），返回路径分 5 类：

### 8.1 五类返回路径总结

| # | 返回路径 | 是否检查调度 | 说明 |
|---|----------|-------------|------|
| 1 | 内核态异常返回 (el1_sync) | ❌ 不检查 | 大部分不可恢复，会 panic |
| 2 | 内核态中断返回 (el1_irq) | ✅ 检查 preempt_count + TIF_NEED_RESCHED | **内核抢占的唯一入口** |
| 3 | 用户态系统调用返回 (el0_svc → ret_fast_syscall) | ✅ 检查 TIF_NEED_RESCHED + _TIF_SIGPENDING | |
| 4 | 用户态其他异常返回 (el0_sync → ret_to_user) | ✅ 检查 TIF_NEED_RESCHED + _TIF_SIGPENDING | |
| 5 | 用户态中断返回 (el0_irq → ret_to_user) | ✅ 检查 TIF_NEED_RESCHED + _TIF_SIGPENDING | |

### 8.2 内核态中断返回（内核抢占）

```asm
el1_irq:
    kernel_entry 1
    irq_handler                         // 处理中断

#ifdef CONFIG_PREEMPT
    ldr    w24, [tsk, #TI_PREEMPT]      // 读 preempt_count
    cbnz   w24, 1f                      // ≠ 0 → 禁止抢占，直接返回
    ldr    x0, [tsk, #TI_FLAGS]
    tbz    x0, #TIF_NEED_RESCHED, 1f   // 未设置 → 直接返回
    bl     el1_preempt                  // preempt_count=0 且 NEED_RESCHED → 抢占！
1:
#endif
    kernel_exit 1

el1_preempt:
    mov    x24, lr
1:  bl     preempt_schedule_irq         // → __schedule(SM_PREEMPT)
    ldr    x0, [tsk, #TI_FLAGS]
    tbnz   x0, #TIF_NEED_RESCHED, 1b   // 循环直到不再需要调度
    ret    x24
```

**关键逻辑**：
1. `preempt_count != 0` → 禁止抢占，直接返回
2. `preempt_count == 0` 且 `TIF_NEED_RESCHED` → 调用 `preempt_schedule_irq()` → `__schedule(SM_PREEMPT)`

### 8.3 用户态返回（所有用户态路径共用 ret_to_user）

```asm
ret_to_user:
    disable_irq
    ldr    x1, [tsk, #TI_FLAGS]
    and    x2, x1, #_TIF_WORK_MASK     // 检查 NEED_RESCHED | SIGPENDING | ...
    cbnz   x2, work_pending            // 有 work → 处理
    kernel_exit 0                       // 无 work → 返回用户态

work_pending:
    tbnz   x1, #TIF_NEED_RESCHED, work_resched
    bl     do_notify_resume             // 处理信号等
    b      ret_to_user

work_resched:
    bl     schedule                     // TIF_NEED_RESCHED → schedule()!
    b      ret_to_user                  // schedule 返回后再检查一次
```

**用户态返回时不需要检查 preempt_count**——因为从用户态陷入内核时 preempt_count 一定是 0（用户态没有 preempt_disable）。

---

## 九、什么叫抢占（preempt）？

从上面 5 类返回路径可以看到，**是否配置 `CONFIG_PREEMPT` 只影响"内核态中断返回"这一条路径**：

| 配置 | 内核态中断返回 | 用户态返回 |
|------|---------------|-----------|
| `CONFIG_PREEMPT=n` | 不检查，直接返回 | 正常检查 TIF_NEED_RESCHED |
| `CONFIG_PREEMPT=y` | 检查 preempt_count + TIF_NEED_RESCHED | 正常检查 TIF_NEED_RESCHED |

**抢占 = 进程在内核态执行时被强制调度出去。** 非抢占内核只有在返回用户态时才可能发生调度切换。

---

## 十、调度框架全景图

```
┌─────────────────────────────────────────────────────────────┐
│                    入 rq (enqueue)                            │
│                                                             │
│   try_to_wake_up() / fork 创建新进程                         │
│     → enqueue_task()                                        │
│     → check_preempt_curr() → resched_curr()                 │
│       → 设置 TIF_NEED_RESCHED（不立即调度）                   │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│                 定时检查 (scheduler_tick)                     │
│                                                             │
│   每 tick: scheduler_tick() → task_tick_fair/rt()           │
│     → 判断当前进程是否跑太久                                 │
│     → 如果是：resched_curr() 设置 TIF_NEED_RESCHED          │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│            中断/异常返回（真正的调度执行点）                    │
│                                                             │
│   用户态返回: ret_to_user → 检查 TIF_NEED_RESCHED → schedule│
│   内核态中断返回 (PREEMPT=y):                                │
│     preempt_count==0 且 TIF_NEED_RESCHED → schedule         │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│                  schedule() → __schedule()                    │
│                                                             │
│   1. 如果非抢占且 state≠RUNNING → dequeue prev              │
│   2. pick_next_task(): stop→dl→rt→cfs→idle                  │
│   3. context_switch(prev, next)                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    出 rq (dequeue)                            │
│                                                             │
│   当前进程主动 block:                                        │
│     set_current_state(TASK_INTERRUPTIBLE)                    │
│     → 立即调用 schedule()                                    │
│     → __schedule() 中 deactivate_task() 将 prev 移出 rq     │
└─────────────────────────────────────────────────────────────┘
```

---

## 十一、关键入口函数总结

理解调度框架，从以下 4 个函数入手：

| 函数 | 作用 | 调度方式 |
|------|------|----------|
| `try_to_wake_up()` | 唤醒进程入 rq | 设置 TIF_NEED_RESCHED，延迟调度 |
| block 函数族 (`mutex_lock`/`schedule_timeout`/`msleep`) | 进程主动 block 出 rq | 立即 `schedule()` |
| `scheduler_tick()` | 周期性检查 | 设置 TIF_NEED_RESCHED，延迟调度 |
| `schedule()` / `__schedule()` | 真正执行切换 | 选进程 + context_switch |

---

## 十二、CONFIG_PREEMPT 选项对比

| 配置 | 内核态可被抢占？ | 延迟 | 适用场景 |
|------|-----------------|------|----------|
| `PREEMPT_NONE` | ❌ 只在返回用户态调度 | 高 | 服务器（吞吐优先） |
| `PREEMPT_VOLUNTARY` | ❌ + 显式 cond_resched() 点 | 中 | 桌面 |
| `PREEMPT` | ✅ 内核态可在任何可抢占点被调度 | 低 | 嵌入式/低延迟 |
| `PREEMPT_RT` | ✅ + 中断线程化 + spinlock 可睡眠 | 极低 | 硬实时 |

---

下一篇：[Linux 进程调度（二）：CFS 完全公平调度算法]
