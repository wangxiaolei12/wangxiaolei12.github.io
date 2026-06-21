---
layout: post
title: "Linux 内核 Soft Lockup 与 Hard Lockup 检测机制源码分析"
date: 2026-06-21 16:40:00 +0800
excerpt: "基于 mainline 内核 kernel/watchdog.c 和 kernel/watchdog_perf.c 源码，深入分析 softlockup 和 hardlockup 的检测原理：hrtimer 定时器驱动、per-CPU 上下文切换检测、NMI/perf 事件触发硬锁检测、buddy 机制及 sysctl 参数调优。"
---

# Linux 内核 Soft Lockup 与 Hard Lockup 检测机制源码分析

源码：`kernel/watchdog.c`、`kernel/watchdog_perf.c`、`kernel/watchdog_buddy.c`

---

## 1. 概念区分

| | Soft Lockup | Hard Lockup |
|---|---|---|
| 定义 | CPU 被内核代码长时间占用，无法调度其他任务 | CPU 被长时间卡住，连中断都无法响应 |
| 本质 | 禁止抢占时间过长（关抢占/自旋锁） | 禁止中断时间过长（关中断/NMI 级别卡死） |
| 检测手段 | hrtimer 中断 + 检查是否有上下文切换 | NMI（perf PMU 溢出）检查 hrtimer 是否还在跑 |
| 默认阈值 | `watchdog_thresh * 2` = 20 秒 | `watchdog_thresh` = 10 秒 |
| 典型原因 | 长时间持有 spinlock、死循环、关抢占 | 长时间关中断、NMI 级死锁 |

dmesg 中的典型告警：

```
BUG: soft lockup - CPU#3 stuck for 22s! [xxx:1234]
Watchdog detected hard LOCKUP on cpu 2
```

---

## 2. 整体架构

```
lockup_detector_init()
       │
       ▼
watchdog_enable(cpu)  ← 每个 CPU 上执行
       │
       ├──→ hrtimer (watchdog_hrtimer)
       │       │
       │       ├──→ watchdog_timer_fn()  每 sample_period 触发（4秒）
       │       │       │
       │       │       ├──→ watchdog_hardlockup_kick()  递增 hrtimer_interrupts
       │       │       │
       │       │       ├──→ softlockup_fn() via stop_one_cpu  更新 touch_ts
       │       │       │
       │       │       └──→ is_softlockup()  检查 touch_ts 是否超时
       │       │
       │       └──→ [softlockup 告警]
       │
       └──→ perf event (PMU NMI) / buddy CPU
               │
               └──→ watchdog_hardlockup_check()
                       │
                       └──→ is_hardlockup()  检查 hrtimer_interrupts 是否变化
                               │
                               └──→ [hardlockup 告警/panic]
```

---

## 3. Soft Lockup 检测原理

### 3.1 核心思路

在每个 CPU 上启动一个 **hrtimer**（硬件定时器中断），每 `sample_period`（约 4 秒）触发一次。在 hrtimer 回调中：

1. 通过 `stop_one_cpu` 调度一个高优先级任务 `softlockup_fn`，更新 `watchdog_touch_ts` 时间戳
2. 检查 `watchdog_touch_ts` 是否超过 `2 * watchdog_thresh`（默认 20 秒）没有被更新

如果 `softlockup_fn` 长时间无法执行（因为 CPU 被占着无法调度），时间戳就不会更新，触发 soft lockup 告警。

### 3.2 关键数据结构

```c
static DEFINE_PER_CPU(unsigned long, watchdog_touch_ts);     // 上次成功调度的时间戳
static DEFINE_PER_CPU(unsigned long, watchdog_report_ts);    // 上次报告的时间戳
static DEFINE_PER_CPU(struct hrtimer, watchdog_hrtimer);     // per-CPU 高精度定时器
```

### 3.3 喂狗函数：softlockup_fn()

```c
static int softlockup_fn(void *data)
{
    update_touch_ts();        // 更新 watchdog_touch_ts = 当前时间
    stop_counting_irqs();
    complete(this_cpu_ptr(&softlockup_completion));
    return 0;
}
```

这个函数通过 `stop_one_cpu_nowait()` 调度执行，它使用的是**最高优先级的 stopper 线程**（migration/N）。如果连 stopper 线程都跑不了，说明 CPU 确实被锁死了。

### 3.4 判断逻辑：is_softlockup()

```c
static int is_softlockup(unsigned long touch_ts,
                          unsigned long period_ts,
                          unsigned long now)
{
    if ((watchdog_enabled & WATCHDOG_SOFTOCKUP_ENABLED) && watchdog_thresh) {
        /* 超过阈值未更新 → softlockup */
        if (time_after(now, period_ts + get_softlockup_thresh()))
            return now - touch_ts;
    }
    return 0;
}
```

`get_softlockup_thresh()` 返回 `watchdog_thresh * 2`，默认 20 秒。

### 3.5 hrtimer 回调：watchdog_timer_fn()

```c
static enum hrtimer_restart watchdog_timer_fn(struct hrtimer *hrtimer)
{
    /* 1. 给 hardlockup 检测器喂狗 */
    watchdog_hardlockup_kick();

    /* 2. 触发 softlockup_fn 去更新时间戳 */
    if (completion_done(this_cpu_ptr(&softlockup_completion))) {
        reinit_completion(this_cpu_ptr(&softlockup_completion));
        stop_one_cpu_nowait(smp_processor_id(),
                softlockup_fn, NULL,
                this_cpu_ptr(&softlockup_stop_work));
    }

    /* 3. 重新设置定时器 */
    hrtimer_forward_now(hrtimer, ns_to_ktime(sample_period));

    /* 4. 检查是否 softlockup */
    now = get_timestamp();
    period_ts = READ_ONCE(*this_cpu_ptr(&watchdog_report_ts));
    touch_ts = __this_cpu_read(watchdog_touch_ts);
    duration = is_softlockup(touch_ts, period_ts, now);

    if (unlikely(duration)) {
        pr_emerg("BUG: soft lockup - CPU#%d stuck for %us! [%s:%d]\n",
            smp_processor_id(), duration,
            current->comm, task_pid_nr(current));
        show_regs(regs);

        if (softlockup_panic)
            panic("softlockup: hung tasks");
    }

    return HRTIMER_RESTART;
}
```

### 3.6 时间关系图

```
时间轴:
|----4s----|----4s----|----4s----|----4s----|----4s----|
^hrtimer   ^hrtimer   ^hrtimer   ^hrtimer   ^hrtimer
 kick+feed  kick+feed  kick+check kick+check kick+ALARM!
 touch_ts↑  touch_ts↑  (无法调度)  (无法调度)  超过20s→报警

|<------------ softlockup_thresh = 20s ------------->|
```

---

## 4. Hard Lockup 检测原理

### 4.1 核心思路

Hard lockup 意味着 CPU 连中断都无法响应了，所以 **hrtimer 本身也跑不了**。需要更底层的机制来检测——**NMI（Non-Maskable Interrupt）**。

实现方式有两种：
1. **Perf PMU 方式**（`watchdog_perf.c`）：注册一个 perf 硬件事件，CPU cycles 溢出时触发 NMI
2. **Buddy CPU 方式**（`watchdog_buddy.c`）：让相邻 CPU 互相检查（无 PMU NMI 支持时使用）

### 4.2 Perf PMU 方式（主流 x86/arm64）

```c
static struct perf_event_attr wd_hw_attr = {
    .type       = PERF_TYPE_HARDWARE,
    .config     = PERF_COUNT_HW_CPU_CYCLES,
    .pinned     = 1,
    .disabled   = 1,
};

static void watchdog_overflow_callback(struct perf_event *event,
                                       struct perf_sample_data *data,
                                       struct pt_regs *regs)
{
    /* 防止被节流 */
    event->hw.interrupts = 0;

    if (!watchdog_check_timestamp())
        return;

    watchdog_hardlockup_check(smp_processor_id(), regs);
}
```

当 CPU cycles 计数器溢出（约每 `watchdog_thresh` 秒一次），触发 NMI 中断，在 NMI handler 中检查 hrtimer 是否还在运行。

### 4.3 判断逻辑：is_hardlockup()

```c
static DEFINE_PER_CPU(atomic_t, hrtimer_interrupts);       // hrtimer 每次触发递增
static DEFINE_PER_CPU(int, hrtimer_interrupts_saved);      // 上次 NMI 时记录的值

static bool is_hardlockup(unsigned int cpu)
{
    int hrint = atomic_read(&per_cpu(hrtimer_interrupts, cpu));

    // hrtimer_interrupts 有变化 → hrtimer 还在跑 → 没有 hard lockup
    if (per_cpu(hrtimer_interrupts_saved, cpu) != hrint) {
        watchdog_hardlockup_update_reset(cpu);
        return false;
    }

    // 连续 miss 次数达到阈值 → hard lockup
    per_cpu(hrtimer_interrupts_missed, cpu)++;
    if (per_cpu(hrtimer_interrupts_missed, cpu) % watchdog_hardlockup_miss_thresh)
        return false;

    return true;
}
```

**核心判断**：每次 NMI 触发时，检查 `hrtimer_interrupts` 是否有增长。如果连续几次 NMI 都发现它没变，说明 hrtimer 中断已经跑不了了——CPU 连普通中断都无法响应，即 hard lockup。

### 4.4 喂狗（hrtimer 端）

```c
static void watchdog_hardlockup_kick(void)
{
    int new_interrupts;
    new_interrupts = atomic_inc_return(this_cpu_ptr(&hrtimer_interrupts));
    watchdog_buddy_check_hardlockup(new_interrupts);  // buddy 方式额外检查
}
```

每次 hrtimer 触发都会递增 `hrtimer_interrupts`，这就是给 hard lockup detector 的"喂狗"。

### 4.5 Buddy CPU 方式（无 NMI 平台）

对于不支持 PMU NMI 的平台，使用"伙伴 CPU"互相检查：

```c
void watchdog_buddy_check_hardlockup(int hrtimer_interrupts)
{
    unsigned int next_cpu;

    next_cpu = watchdog_next_cpu(smp_processor_id());
    if (next_cpu >= nr_cpu_ids)
        return;

    smp_rmb();
    watchdog_hardlockup_check(next_cpu, NULL);  // 检查下一个 CPU
}
```

CPU-A 的 hrtimer 中断去检查 CPU-B 的 `hrtimer_interrupts` 是否在增长。如果 CPU-B 的值不变，说明 CPU-B 的 hrtimer 跑不了了。

### 4.6 告警处理

```c
void watchdog_hardlockup_check(unsigned int cpu, struct pt_regs *regs)
{
    if (per_cpu(watchdog_hardlockup_touched, cpu)) {
        watchdog_hardlockup_update_reset(cpu);
        per_cpu(watchdog_hardlockup_touched, cpu) = false;
        return;
    }

    if (!is_hardlockup(cpu))
        return;

    pr_emerg("CPU%u: Watchdog detected hard LOCKUP on cpu %u\n", this_cpu, cpu);
    print_modules();
    show_regs(regs);

    if (hardlockup_panic)
        nmi_panic(regs, "Hard LOCKUP");
}
```

---

## 5. 层级关系总结

```
┌─────────────────────────────────────────────────────┐
│              NMI / Perf PMU overflow                  │
│    (或 buddy CPU 的 hrtimer 中断)                     │
│                                                      │
│    检测：hrtimer_interrupts 是否还在增长              │
│    → 不增长 = Hard Lockup (CPU 连中断都无法响应)      │
├─────────────────────────────────────────────────────┤
│              hrtimer 中断 (硬中断上下文)               │
│                                                      │
│    1. 递增 hrtimer_interrupts (给 hardlockup 喂狗)   │
│    2. 调度 softlockup_fn (给 softlockup 喂狗)        │
│    3. 检查 touch_ts 是否超时                          │
│    → 超时 = Soft Lockup (CPU 无法调度)                │
├─────────────────────────────────────────────────────┤
│              进程调度上下文                            │
│                                                      │
│    softlockup_fn → update_touch_ts()                 │
│    (需要被调度才能执行)                               │
└─────────────────────────────────────────────────────┘
```

**检测层级**：
- 进程能跑 → 正常
- 进程跑不了，但 hrtimer 能跑 → **Soft Lockup**
- hrtimer 也跑不了，但 NMI 能触发 → **Hard Lockup**

---

## 6. 可调参数

| 参数 | 路径 | 含义 |
|------|------|------|
| `watchdog` | `/proc/sys/kernel/watchdog` | 总开关（0 关闭）|
| `watchdog_thresh` | `/proc/sys/kernel/watchdog_thresh` | 基础阈值，默认 10s |
| `soft_watchdog` | `/proc/sys/kernel/soft_watchdog` | softlockup 开关 |
| `nmi_watchdog` | `/proc/sys/kernel/nmi_watchdog` | hardlockup 开关 |
| `softlockup_panic` | `/proc/sys/kernel/softlockup_panic` | softlockup 时 panic |
| `hardlockup_panic` | `/proc/sys/kernel/hardlockup_panic` | hardlockup 时 panic |
| `watchdog_cpumask` | `/proc/sys/kernel/watchdog_cpumask` | 监控哪些 CPU |

阈值关系：
- Hard lockup 阈值 = `watchdog_thresh` = 10s
- Soft lockup 阈值 = `watchdog_thresh * 2` = 20s
- hrtimer 采样周期 = `(watchdog_thresh * 2) / 5` ≈ 4s

```bash
# 关闭 watchdog
echo 0 > /proc/sys/kernel/watchdog

# 只关 hardlockup
echo 0 > /proc/sys/kernel/nmi_watchdog

# 设置 softlockup 触发 panic（配合 kdump）
echo 1 > /proc/sys/kernel/softlockup_panic

# 修改阈值为 30s（soft=60s, hard=30s）
echo 30 > /proc/sys/kernel/watchdog_thresh
```

内核启动参数：
```
nosoftlockup                    # 禁用 soft lockup 检测
nowatchdog                      # 禁用整个 watchdog
nmi_watchdog=0                  # 禁用 hard lockup 检测
nmi_watchdog=panic              # hard lockup 时 panic
softlockup_panic=1              # soft lockup 时 panic
watchdog_thresh=20              # 设置阈值
```

---

## 7. 中断风暴检测（CONFIG_SOFTLOCKUP_DETECTOR_INTR_STORM）

新版内核在 softlockup 检测中加入了**中断风暴识别**：

```c
static bool need_counting_irqs(void)
{
    u8 util;
    int tail = __this_cpu_read(cpustat_tail);
    tail = (tail + NUM_SAMPLE_PERIODS - 1) % NUM_SAMPLE_PERIODS;
    util = __this_cpu_read(cpustat_util[tail][STATS_HARDIRQ]);
    return util > HARDIRQ_PERCENT_THRESH;  // hardirq 占比超过 50%
}
```

如果检测到 softlockup 期间 hardirq 占用超过 50%，会自动统计哪个中断号触发最频繁，帮助定位中断风暴问题：

```
CPU#2 Detect HardIRQ Time exceeds 50%. Most frequent HardIRQs:
    #1: 1523456    irq#38
    #2: 234567     irq#12
```

---

## 8. 总结

| 项目 | Soft Lockup | Hard Lockup |
|------|-------------|-------------|
| 含义 | CPU 无法调度（关抢占太久） | CPU 无法响应中断（关中断太久） |
| 检测者 | hrtimer 中断回调 | NMI（perf PMU）或 buddy CPU |
| 被检测量 | `watchdog_touch_ts` 是否更新 | `hrtimer_interrupts` 是否增长 |
| 喂狗动作 | `softlockup_fn` 被调度时更新 ts | hrtimer 每次触发递增计数器 |
| 阈值 | `watchdog_thresh * 2` (20s) | `watchdog_thresh` (10s) |
| 告警级别 | pr_emerg + 可选 panic | pr_emerg + 可选 nmi_panic |
| 关闭方式 | `nosoftlockup` / sysctl | `nmi_watchdog=0` / sysctl |

两者是**分层监控**的关系：soft lockup detector 需要 hrtimer 能跑，hard lockup detector 需要 NMI 能触发。Hard lockup 比 soft lockup 更严重——如果连 hrtimer 中断都无法响应，系统基本处于完全卡死状态。
