---
layout: post
title: "Linux 内核定时器全景：Timer Wheel、Hrtimer、Tick 与时间统计"
date: 2026-06-12 12:00:00 +0800
excerpt: "深入分析 Linux 内核时间子系统：clock source/event 硬件抽象、tick 周期中断、低精度 timer wheel 与高精度 hrtimer、CPU 时间统计 account_process_tick、调度器 sched_tick 的调用链。基于最新 mainline 源码。"
---

# Linux 内核定时器全景：Timer Wheel、Hrtimer、Tick 与时间统计

---

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         用户空间                                         │
│  sleep() / nanosleep() / alarm() / setitimer() / timer_create()        │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ syscall
┌────────────────────────────────────┼────────────────────────────────────┐
│                              内核时间子系统                               │
│                                    │                                    │
│  ┌─────────────────────────────────┼──────────────────────────────┐     │
│  │              Timer 核心层                                       │     │
│  │                                                                │     │
│  │   ┌─────────────────┐        ┌─────────────────────┐          │     │
│  │   │  Timer Wheel    │        │    Hrtimer (红黑树)   │          │     │
│  │   │  (低精度,jiffies)│        │  (高精度,nanosecond) │          │     │
│  │   │  kernel/time/   │        │  kernel/time/        │          │     │
│  │   │  timer.c        │        │  hrtimer.c           │          │     │
│  │   └────────┬────────┘        └──────────┬──────────┘          │     │
│  │            │                             │                     │     │
│  └────────────┼─────────────────────────────┼─────────────────────┘     │
│               │                             │                           │
│  ┌────────────┼─────────────────────────────┼─────────────────────┐     │
│  │            │       Tick 层               │                     │     │
│  │            │                             │                     │     │
│  │   ┌────────▼───────────────────────────--▼──────────┐          │     │
│  │   │  tick-common.c / tick-sched.c                   │          │     │
│  │   │  tick_handle_periodic() / tick_nohz_handler()   │          │     │
│  │   └──────────────────────┬──────────────────────────┘          │     │
│  └──────────────────────────┼─────────────────────────────────────┘     │
│                             │                                           │
│  ┌──────────────────────────┼─────────────────────────────────────┐     │
│  │         硬件抽象层        │                                     │     │
│  │                          │                                     │     │
│  │  ┌──────────────┐   ┌───▼──────────────┐                      │     │
│  │  │ Clock Source │   │  Clock Event     │                      │     │
│  │  │ (读取时间)    │   │  (产生中断)      │                      │     │
│  │  │ TSC/HPET/    │   │  LAPIC Timer/    │                      │     │
│  │  │ arch_timer   │   │  ARM arch_timer  │                      │     │
│  │  └──────────────┘   └──────────────────┘                      │     │
│  └────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Tick 中断 — 一切的起点

每个 CPU 都有一个周期性（或 oneshot）的 clock event device，产生 tick 中断。

### 周期 Tick 模式

```
硬件定时器中断 (每 1/HZ 秒)
    │
    ▼
tick_handle_periodic(dev)           [tick-common.c]
    │
    └── tick_periodic(cpu)
            │
            ├── do_timer(1)              // jiffies_64++（仅一个 CPU 负责）
            ├── update_wall_time()       // 更新墙上时钟 (xtime)
            │
            └── update_process_times(user_tick)    [timer.c]
                    │
                    ├── account_process_tick()      // ★ CPU 时间统计
                    ├── run_local_timers()          // ★ 检查 timer wheel
                    ├── rcu_sched_clock_irq()       // RCU 回调
                    ├── irq_work_tick()             // IRQ work
                    ├── sched_tick()                // ★ 调度器 tick
                    └── run_posix_cpu_timers()      // POSIX 定时器
```

### 高精度 Tick 模式 (hrtimer 驱动)

```
hrtimer 中断 (oneshot, 纳秒精度)
    │
    ▼
tick_nohz_handler(timer)            [tick-sched.c]
    │
    ├── tick_sched_do_timer()        // jiffies 更新
    └── tick_sched_handle(ts, regs)
            │
            ├── update_process_times(user_tick)   // 同上
            └── profile_tick()
```

---

## 三、CPU 时间统计 — account_process_tick()

每个 tick 中断都会统计当前 CPU 花在哪里：

```c
// kernel/sched/cputime.c
void account_process_tick(struct task_struct *p, int user_tick)
{
    u64 cputime = TICK_NSEC;  // 一个 tick 的时间

    if (user_tick) {
        account_user_time(p, cputime);    // p->utime += cputime
    } else if (p != this_rq()->idle) {
        account_system_time(p, cputime);  // p->stime += cputime
    } else {
        account_idle_time(cputime);       // idle 时间
    }
}
```

### 统计的去向（/proc/stat 和 top 看到的）

```
┌──────────────────────────────────────────────────────────┐
│  account_user_time()     → cpustat[CPUTIME_USER]   (us) │
│  account_nice_time()     → cpustat[CPUTIME_NICE]   (ni) │
│  account_system_time()   → cpustat[CPUTIME_SYSTEM] (sy) │
│  account_idle_time()     → cpustat[CPUTIME_IDLE]   (id) │
│  account_steal_time()    → cpustat[CPUTIME_STEAL]  (st) │
│  account_guest_time()    → cpustat[CPUTIME_GUEST]       │
│  (hardirq context)       → cpustat[CPUTIME_IRQ]    (hi) │
│  (softirq context)       → cpustat[CPUTIME_SOFTIRQ](si) │
│  (iowait)                → cpustat[CPUTIME_IOWAIT] (wa) │
└──────────────────────────────────────────────────────────┘

对应 /proc/stat:
cpu  user nice system idle iowait irq softirq steal guest
```

### 判断依据

```c
// 中断发生时 user_mode(regs) 判断是用户态还是内核态
user_tick = user_mode(get_irq_regs());
// 这就是为什么 CPU 时间统计是"采样"式的——只在 tick 时刻判断
```

---

## 四、调度器 Tick — sched_tick()

```c
// kernel/sched/core.c
void sched_tick(void)
{
    struct rq *rq = this_rq();
    struct task_struct *donor = rq->donor;

    sched_clock_tick();                    // 更新 sched_clock
    update_rq_clock(rq);                   // 更新运行队列时钟

    // ★ 调用当前调度类的 tick 回调
    donor->sched_class->task_tick(rq, donor, 0);
    //   CFS: task_tick_fair() → 检查 vruntime，判断是否需要抢占
    //   RT:  task_tick_rt()   → 检查时间片
    //   DL:  task_tick_dl()   → 检查 deadline

    calc_global_load_tick(rq);             // 全局负载统计
    sched_balance_trigger(rq);             // 触发负载均衡 (SCHED_SOFTIRQ)

    perf_event_task_tick();                // perf 事件
}
```

### CFS 中的 task_tick_fair

```c
task_tick_fair() → entity_tick()
    │
    ├── update_curr()          // 更新当前任务的 vruntime
    │     sum_exec_runtime += delta
    │     vruntime += delta * (NICE_0_LOAD / weight)
    │
    └── check_preempt_tick()   // 是否需要抢占？
          │
          ├── 当前任务运行时间 > ideal_runtime？
          │       └── resched_curr(rq)   // 设置 TIF_NEED_RESCHED
          │
          └── vruntime - leftmost->vruntime > ideal_runtime？
                  └── resched_curr(rq)   // 设置 TIF_NEED_RESCHED
```

---

## 五、Timer Wheel — 低精度定时器

### 数据结构：分层时间轮

```
struct timer_base (per-CPU):
    vectors[WHEEL_SIZE]     // WHEEL_SIZE = LVL_SIZE × LVL_DEPTH = 64 × 9 = 576 个桶

Level 0: [0-63]    粒度 1ms    范围 0~63ms       ← 大多数网络超时在这里
Level 1: [64-127]  粒度 8ms    范围 64~511ms
Level 2: [128-191] 粒度 64ms   范围 512ms~4s
Level 3: [192-255] 粒度 512ms  范围 4s~32s
Level 4: [256-319] 粒度 4s     范围 32s~4min
Level 5: [320-383] 粒度 32s    范围 4min~34min
Level 6: [384-447] 粒度 4min   范围 34min~4h
Level 7: [448-511] 粒度 34min  范围 4h~1d
Level 8: [512-575] 粒度 4h     范围 1d~12d

(以 HZ=1000 为例)
```

### 工作原理

```
添加定时器: mod_timer(&timer, jiffies + timeout)
    │
    ├── 计算 timeout 属于哪个 level
    │   (timeout 越大 → level 越高 → 粒度越粗)
    │
    └── 挂到对应 level 的 bucket (hash 链表)

执行定时器: TIMER_SOFTIRQ
    │
    ▼
run_timer_softirq()
    └── run_timer_base(BASE_LOCAL / BASE_GLOBAL / BASE_DEF)
            └── __run_timers(base)
                    │
                    ├── while (jiffies >= base->next_expiry)
                    │       ├── collect_expired_timers(base, heads)
                    │       │     // 从当前 clk 对应的桶中收集到期的 timer
                    │       ├── base->clk++
                    │       └── expire_timers(base, heads)
                    │               │
                    │               └── for each timer in heads:
                    │                       detach_timer(timer)
                    │                       call_timer_fn(timer, fn)
                    │                       // 调用 timer->function
                    └── (无级联！不像旧实现需要 cascade)
```

### API

```c
// 定义
struct timer_list my_timer;
timer_setup(&my_timer, my_callback, 0);

// 启动 (在 jiffies + delay 后触发)
mod_timer(&my_timer, jiffies + msecs_to_jiffies(100));

// 取消
del_timer_sync(&my_timer);

// 回调
void my_callback(struct timer_list *t) {
    // 在 softirq 上下文执行，不可睡眠
    // 如果需要重复，再次 mod_timer()
}
```

---

## 六、Hrtimer — 高精度定时器

### 与 timer wheel 的区别

| | Timer Wheel | Hrtimer |
|---|---|---|
| 精度 | jiffies (1~10ms) | 纳秒 |
| 数据结构 | 分层哈希桶 | 红黑树 (timerqueue) |
| 触发方式 | TIMER_SOFTIRQ | 直接在硬中断 或 HRTIMER_SOFTIRQ |
| 设计目标 | 超时（大多被取消） | 精确定时（大多会到期） |
| 典型用户 | 网络超时、看门狗 | nanosleep、POSIX timer、调度器 |

### 执行流程

```
clock_event_device 中断
    │
    ▼
hrtimer_interrupt(dev)                [hrtimer.c]
    │
    ├── 更新 cpu_base->expires_next = KTIME_MAX
    │
    ├── if (now >= softirq_expires_next)
    │       raise_timer_softirq(HRTIMER_SOFTIRQ)   // soft mode hrtimer
    │
    ├── __hrtimer_run_queues(HRTIMER_ACTIVE_HARD)  // hard mode hrtimer
    │       │
    │       └── 遍历红黑树，执行所有 expires <= now 的 hrtimer:
    │               fn = timer->function
    │               restart = fn(timer)
    │               if (restart == HRTIMER_RESTART)
    │                   重新入队
    │
    └── hrtimer_interrupt_rearm()
            └── 编程 clock_event_device 为下一个最早到期时间
```

### API

```c
struct hrtimer my_hr_timer;

hrtimer_init(&my_hr_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
my_hr_timer.function = my_hr_callback;
hrtimer_start(&my_hr_timer, ktime_set(0, 500000), HRTIMER_MODE_REL); // 500us

enum hrtimer_restart my_hr_callback(struct hrtimer *timer) {
    // 在硬中断上下文执行（HRTIMER_MODE_HARD）
    // 或 softirq 上下文（HRTIMER_MODE_SOFT）
    hrtimer_forward_now(timer, interval);
    return HRTIMER_RESTART;  // 或 HRTIMER_NORESTART
}
```

---

## 七、Tick 触发 Timer 的完整调用链

```
硬件定时器中断 (LAPIC Timer / ARM arch_timer)
    │
    ▼
tick_handle_periodic() 或 tick_nohz_handler()
    │
    ▼
update_process_times(user_tick)
    │
    ├── 1. account_process_tick(p, user_tick)
    │       └── 统计 user/system/idle/irq 时间
    │
    ├── 2. run_local_timers()
    │       ├── hrtimer_run_queues()           // 非高精度模式下运行 hrtimer
    │       └── if (jiffies >= base->next_expiry)
    │               raise_timer_softirq(TIMER_SOFTIRQ)   // 触发 timer wheel
    │
    ├── 3. rcu_sched_clock_irq()
    │       └── RCU grace period 推进
    │
    ├── 4. sched_tick()
    │       ├── update_rq_clock()
    │       ├── task_tick_fair/rt/dl()         // 调度类检查抢占
    │       └── sched_balance_trigger()        // 负载均衡
    │
    └── 5. run_posix_cpu_timers()
            └── 检查进程 CPU 时间限制 (RLIMIT_CPU, setitimer)
```

---

## 八、NO_HZ (Tickless) 模式

```
                    Tick 模式对比
┌──────────────────┬─────────────────────────────────┐
│  CONFIG_HZ_PERIODIC │ 始终产生周期 tick                │
├──────────────────┼─────────────────────────────────┤
│  CONFIG_NO_HZ_IDLE  │ CPU idle 时停止 tick            │
│  (最常用)           │ 有任务运行时恢复                │
├──────────────────┼─────────────────────────────────┤
│  CONFIG_NO_HZ_FULL  │ 仅一个任务运行时也停 tick        │
│  (实时/HPC)         │ 只保留 1Hz 的维护 tick          │
└──────────────────┴─────────────────────────────────┘
```

NO_HZ_IDLE 的关键：CPU 进入 idle 时：
```c
tick_nohz_idle_enter()
    → tick_nohz_stop_tick()
        → 计算下一个定时器到期时间
        → 编程 clock_event 为 oneshot 到那个时间
        → 中间不产生多余的 tick 中断
        → 省电！
```

---

## 九、Timer 三个 Base 的含义 (NO_HZ 模式)

```c
#define NR_BASES   3
#define BASE_LOCAL  0   // 绑定当前 CPU，不可迁移
#define BASE_GLOBAL 1   // 可被其他 CPU 代为执行（timer migration）
#define BASE_DEF    2   // deferrable，可延迟到 CPU 醒来再执行
```

- **BASE_LOCAL**: `add_timer()` 默认，绑定到发起的 CPU
- **BASE_GLOBAL**: `TIMER_PINNED` 未设置时，idle CPU 的 timer 可被忙 CPU 代执行
- **BASE_DEF**: `timer_setup(&t, fn, TIMER_DEFERRABLE)` — 不会把 CPU 从 idle 唤醒

---

## 十、常见定时器使用场景

| 场景 | 使用的机制 | 原因 |
|------|-----------|------|
| 网络超时 (TCP retransmit) | timer_wheel | 大部分被取消，粗粒度够用 |
| 看门狗 | timer_wheel | 超时才触发，精度不关键 |
| nanosleep / usleep | hrtimer | 需要纳秒精度 |
| 调度器时间片 | hrtimer (tick) | 精确控制调度周期 |
| 周期采样 (perf) | hrtimer | 精确采样间隔 |
| delayed_work | timer_wheel | 延迟工作队列底层用 timer |
| POSIX timer_create | hrtimer | 用户空间要求高精度 |

---

## 十一、源文件索引

| 文件 | 内容 |
|------|------|
| `kernel/time/timer.c` | timer wheel, run_timer_softirq, update_process_times |
| `kernel/time/hrtimer.c` | hrtimer 红黑树, hrtimer_interrupt |
| `kernel/time/tick-common.c` | tick_handle_periodic, tick_periodic |
| `kernel/time/tick-sched.c` | tick_nohz_handler, NO_HZ 逻辑 |
| `kernel/time/clocksource.c` | clock source 注册与选择 |
| `kernel/time/clockevents.c` | clock event device 管理 |
| `kernel/time/timekeeping.c` | 墙上时钟维护, update_wall_time |
| `kernel/sched/cputime.c` | account_process_tick, CPU 时间统计 |
| `kernel/sched/core.c` | sched_tick, task_tick 调度类回调 |
| `include/linux/timer.h` | struct timer_list, timer API |
| `include/linux/hrtimer.h` | struct hrtimer, hrtimer API |
