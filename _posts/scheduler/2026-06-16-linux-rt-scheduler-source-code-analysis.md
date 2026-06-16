---
layout: post
title: "Linux RT 调度器源码深度解析（kernel/sched/rt.c）"
date: 2026-06-16 22:00:00 +0800
excerpt: "基于 mainline kernel/sched/rt.c 全部 2945 行源码的系统性分析。涵盖关键常量与特殊值解释、RT 带宽控制与 Runtime 借用、SMP Push/Pull 负载均衡、IPI 优化、Pushable Tasks 管理、RT Group Scheduling 等高级机制。"
---

# Linux RT 调度器源码深度解析（kernel/sched/rt.c）

基于 mainline `kernel/sched/rt.c`（约 2945 行）全量源码分析。

本文是 [Linux 进程调度（三）：RT 实时调度]({% post_url scheduler/2026-06-14-linux-scheduler-03-rt %}) 的深入补充，聚焦源码中的**关键常量/特殊值**、**SMP 均衡**和**带宽控制**高级机制。

---

## 一、关键常量与特殊值详解

源码中大量出现一些"魔法值"和宏定义，理解它们是读懂代码的前提。

### 1.1 MAX_RT_PRIO = 100

```c
// include/linux/sched/prio.h
#define MAX_RT_PRIO     100
```

| 含义 | 说明 |
|------|------|
| RT 优先级范围 | 内核 prio 0~99，共 100 级 |
| 数字越小优先级越高 | prio=0 是最高 RT 优先级 |
| 用户空间映射 | `sched_priority` 1~99，内核 `prio = 99 - sched_priority` |
| 哨兵用途 | `__set_bit(MAX_RT_PRIO, array->bitmap)` 设第 100 位为哨兵，保证 `find_first_bit` 不越界 |

```c
// init_rt_rq() 中：
for (i = 0; i < MAX_RT_PRIO; i++) {
    INIT_LIST_HEAD(array->queue + i);
    __clear_bit(i, array->bitmap);
}
__set_bit(MAX_RT_PRIO, array->bitmap);  // ★ 第 100 位作为哨兵终止搜索
```

### 1.2 MAX_RT_PRIO - 1 = 99

```c
rt_rq->highest_prio.curr = MAX_RT_PRIO - 1;  // 初始化为 99
rt_rq->highest_prio.next = MAX_RT_PRIO - 1;
```

| 含义 | 说明 |
|------|------|
| "最低的 RT 优先级" | 99 是 RT 范围内数字最大 = 优先级最低 |
| 初始化含义 | 队列为空时设为 99，表示"没有高优先级任务" |
| 判断依据 | 如果 `highest_prio.curr == 99`，说明要么没有 RT 任务，要么只有最低优先级的 |

### 1.3 RUNTIME_INF

```c
// kernel/sched/sched.h
#define RUNTIME_INF     ((u64)~0ULL)   // 0xFFFFFFFFFFFFFFFF，即 u64 最大值
```

| 含义 | 说明 |
|------|------|
| "无限运行时间" | 表示不受带宽限制 |
| 出现场景 1 | `rt_bandwidth_enabled()` 返回 false 时，runtime 设为 INF |
| 出现场景 2 | `__disable_runtime()` 中将 `rt_rq->rt_runtime = RUNTIME_INF` 表示"已禁用，不参与借用" |
| 出现场景 3 | 用户设置 `sched_rt_runtime_us = -1` 时转换为 RUNTIME_INF |
| 判断逻辑 | `if (rt_rq->rt_runtime == RUNTIME_INF)` → 跳过 throttle 检查 |

```c
// sched_rt_runtime_exceeded() 中：
if (runtime >= sched_rt_period(rt_rq))
    return 0;  // runtime >= period → 不限制，等效于 INF

// do_balance_runtime() 中：
if (iter->rt_runtime == RUNTIME_INF)
    goto next;  // 标记为 INF 的队列不参与 runtime 借用
```

### 1.4 RR_TIMESLICE

```c
// include/linux/sched/rt.h
#define RR_TIMESLICE    (100 * HZ / 1000)  // 100ms 对应的 jiffies 数
```

| 含义 | 说明 |
|------|------|
| SCHED_RR 的默认时间片 | 100ms |
| HZ=1000 时 | RR_TIMESLICE = 100 个 tick |
| HZ=250 时 | RR_TIMESLICE = 25 个 tick |
| 重置时机 | `task_tick_rt()` 中时间片耗尽后：`p->rt.time_slice = sched_rr_timeslice` |

### 1.5 sysctl_sched_rt_period / sysctl_sched_rt_runtime

```c
int sysctl_sched_rt_period  = 1000000;   // 1秒，单位微秒
int sysctl_sched_rt_runtime = 1000000;   // 1秒（较新内核默认不限制）
                                          // 早期内核默认 950000（限制 95%）
```

| 值 | 含义 |
|----|------|
| runtime == period | **不限制**，RT 可以 100% 占用 CPU |
| runtime < period（如 950000） | 每周期最多跑 runtime μs，剩余留给 CFS |
| runtime == -1 | 用户空间设置，内核转为 `RUNTIME_INF`，完全禁用 throttling |
| runtime == 0 | 不允许 RT 运行（会阻止 RT 任务调度） |

### 1.6 RT_MAX_TRIES = 3

```c
#define RT_MAX_TRIES 3
```

| 含义 | 说明 |
|------|------|
| Push/Pull 最大重试次数 | `find_lock_lowest_rq()` 中尝试锁定目标 rq 的最大次数 |
| 原因 | 在多 CPU 竞争下，目标 rq 的优先级可能在加锁过程中发生变化，需要重试 |
| 设计权衡 | 3 次够用又不会因为无限重试导致延迟 |

### 1.7 CPUPRI_INVALID

```c
// kernel/sched/cpupri.h
#define CPUPRI_INVALID  -1
```

| 含义 | 说明 |
|------|------|
| "此 CPU 不可用" | CPU offline 时设为此值 |
| 使用场景 | `rq_offline_rt()` → `cpupri_set(&rq->rd->cpupri, rq->cpu, CPUPRI_INVALID)` |
| 效果 | 标记后，`cpupri_find()` 不会将此 CPU 作为迁移目标 |

### 1.8 overloaded 标志

```c
rt_rq->overloaded = 1;  // 或 0
```

| 值 | 含义 |
|----|------|
| 0 | 该 CPU 的 RT 运行队列中 ≤ 1 个可推送任务 |
| 1 | 有 ≥ 2 个可运行的 RT 任务（其中至少一个可迁移） |
| 作用 | overloaded 时该 CPU 被加入 `rto_mask`，push/pull 机制才会关注它 |

### 1.9 highest_prio.curr 与 highest_prio.next

```c
struct {
    int curr;   // 当前队列中最高优先级
    int next;   // 可推送任务中最高优先级（不含正在运行的）
} highest_prio;
```

| 字段 | 用途 |
|------|------|
| `.curr` | 本 CPU RT 队列的最高优先级，用于 `cpupri` 更新，其他 CPU 据此判断能否推任务过来 |
| `.next` | pushable_tasks 链表中最高优先级，用于 pull 判断——只有 `.next` 比目标 CPU 的 `.curr` 高才值得拉取 |

### 1.10 rt_bandwidth.rt_period_active

```c
rt_b->rt_period_active = 0;  // 或 1
```

| 值 | 含义 |
|----|------|
| 0 | hrtimer 未激活，没有 RT 任务在跑 |
| 1 | hrtimer 正在运行，周期性检查 throttle |
| 设计 | 避免没有 RT 任务时白白触发定时器中断 |

---

## 二、RT 带宽控制深入

### 2.1 Runtime 借用（RT_RUNTIME_SHARE）

当一个 CPU 的 `rt_time` 超过本地 `rt_runtime` 时，可以从同一 root_domain 中其他 CPU 借用空闲的 runtime：

```c
static void do_balance_runtime(struct rt_rq *rt_rq)
{
    weight = cpumask_weight(rd->span);  // 域内 CPU 数量

    for_each_cpu(i, rd->span) {
        struct rt_rq *iter = sched_rt_period_rt_rq(rt_b, i);

        if (iter == rt_rq)
            continue;

        if (iter->rt_runtime == RUNTIME_INF)  // ★ 被禁用的不参与
            goto next;

        // 从有余量的 CPU 按 1/N 比例借取
        diff = iter->rt_runtime - iter->rt_time;  // 剩余量
        if (diff > 0) {
            diff = div_u64((u64)diff, weight);          // 取 1/N
            if (rt_rq->rt_runtime + diff > rt_period)
                diff = rt_period - rt_rq->rt_runtime;   // 不超过一个周期
            iter->rt_runtime -= diff;   // 出借方减少
            rt_rq->rt_runtime += diff;  // 借入方增加
        }
    }
}
```

**示意**：
```
4 CPU 系统，每 CPU 初始 rt_runtime = 950ms

CPU0: RT 任务密集，rt_time 已用完 950ms
CPU1: 空闲，rt_time = 0，剩余 950ms
CPU2: 空闲，rt_time = 0，剩余 950ms
CPU3: 空闲，rt_time = 200ms，剩余 750ms

CPU0 借用:
  从 CPU1 借: 950/4 = 237ms
  从 CPU2 借: 950/4 = 237ms
  从 CPU3 借: 750/4 = 187ms
  → CPU0 的 rt_runtime 增加到 950+237+237+187 = 限制在 rt_period(1000ms)
```

### 2.2 __disable_runtime / __enable_runtime

CPU hotplug 时：

```c
// CPU 下线时
static void __disable_runtime(struct rq *rq)
{
    // 回收借出的 runtime
    want = rt_b->rt_runtime - rt_rq->rt_runtime;  // 借出量

    for_each_cpu(i, rd->span) {
        // 从其他 CPU 回收
        diff = min_t(s64, iter->rt_runtime, want);
        iter->rt_runtime -= diff;
        want -= diff;
    }

    // 设为 RUNTIME_INF 表示"已禁用，别来借"
    rt_rq->rt_runtime = RUNTIME_INF;
    rt_rq->rt_throttled = 0;
}

// CPU 上线时
static void __enable_runtime(struct rq *rq)
{
    // 重置为初始值
    rt_rq->rt_runtime = rt_b->rt_runtime;
    rt_rq->rt_time = 0;
    rt_rq->rt_throttled = 0;
}
```

### 2.3 周期定时器

```c
static int do_sched_rt_period_timer(struct rt_bandwidth *rt_b, int overrun)
{
    for_each_cpu(i, span) {
        // 新周期开始，减去上周期应扣的时间
        rt_rq->rt_time -= min(rt_rq->rt_time, overrun * runtime);

        // 如果之前被 throttle，现在时间够了 → 解除
        if (rt_rq->rt_throttled && rt_rq->rt_time < runtime) {
            rt_rq->rt_throttled = 0;
            sched_rt_rq_enqueue(rt_rq);  // RT 重新可调度
        }
    }
}
```

---

## 三、SMP 负载均衡——Push/Pull 机制

RT 调度器**不使用** CFS 的周期性 load_balance，而是**事件驱动**的 push/pull。

### 3.1 Pushable Tasks 管理

```c
static void enqueue_pushable_task(struct rq *rq, struct task_struct *p)
{
    // plist: 按优先级排序的链表，高优先级在前
    plist_add(&p->pushable_tasks, &rq->rt.pushable_tasks);

    // 更新 highest_prio.next
    if (p->prio < rq->rt.highest_prio.next)
        rq->rt.highest_prio.next = p->prio;

    // 首次有可推送任务 → 标记 overloaded
    if (!rq->rt.overloaded) {
        rt_set_overload(rq);     // 在 rto_mask 中设置本 CPU 的 bit
        rq->rt.overloaded = 1;
    }
}
```

**什么样的任务是 pushable 的**：
- 不在当前 CPU 上运行（不是 current）
- `p->nr_cpus_allowed > 1`（没有绑核）
- 是 RT 任务

### 3.2 Push：推送任务到其他 CPU

```c
static int push_rt_task(struct rq *rq, bool pull)
{
    if (!rq->rt.overloaded)      // 没有多余 RT 任务
        return 0;

    next_task = pick_next_pushable_task(rq);  // 取 plist 头（最高优先级可推送任务）

    // 找优先级最低的目标 CPU
    lowest_rq = find_lock_lowest_rq(next_task, rq);

    // 迁移任务
    move_queued_task_locked(rq, lowest_rq, next_task);
    resched_curr(lowest_rq);  // 让目标 CPU 重新调度
}
```

**find_lowest_rq() 的查找逻辑**：
```
1. cpupri_find() → O(1) 找到所有优先级低于 task 的 CPU 集合
2. 优先选 task 之前运行的 CPU（cache 亲和）
3. 按 sched_domain 拓扑选最近的 CPU（减少 NUMA 距离）
4. 都没有 → 返回 -1（推送失败）
```

### 3.3 Pull：从其他 CPU 拉取任务

```c
static void pull_rt_task(struct rq *this_rq)
{
    for_each_cpu(cpu, this_rq->rd->rto_mask) {  // 遍历 overloaded 的 CPU
        // 只关注 src 上 next 优先级高于本 CPU curr 优先级的
        if (src_rq->rt.highest_prio.next >= this_rq->rt.highest_prio.curr)
            continue;

        p = pick_highest_pushable_task(src_rq, this_cpu);

        if (p && p->prio < this_rq->rt.highest_prio.curr)
            move_queued_task_locked(src_rq, this_rq, p);  // 拉过来
    }
}
```

### 3.4 RT_PUSH_IPI 优化

大规模系统中逐一 pull 开销大，改为 IPI 链式传播：

```
CPU A (变空闲，需要 RT 任务)
  → atomic_inc(rto_loop_next)
  → 发 IPI 到第一个 overloaded CPU
     → 该 CPU 本地执行 push_rt_task()
     → 完成后发 IPI 到下一个 overloaded CPU
     → ... 直到 rto_mask 遍历完
```

**优势**：避免一个 CPU 持有所有远程 rq 的锁，降低 IPI 风暴风险。

---

## 四、抢占逻辑中的特殊处理

### 4.1 同优先级特殊处理

```c
static void check_preempt_equal_prio(struct rq *rq, struct task_struct *p)
{
    // 当前任务可迁移吗？
    if (rq->curr->nr_cpus_allowed == 1)
        return;  // 当前任务绑核了，不能推走

    // 新任务不可迁移 + 当前任务可迁移 → 让当前任务被推走
    if (p->nr_cpus_allowed != 1 && cpupri_find(..., p, NULL))
        return;  // 新任务也可迁移，让 push 逻辑处理

    // 新任务绑核无法迁移 → 重新调度让当前任务被推到其他 CPU
    requeue_task_rt(rq, p, 1);  // 新任务放到队首
    resched_curr(rq);
}
```

**场景**：优先级相同时，绑核的任务优先留在本 CPU，可迁移的任务被推走。

### 4.2 Migration Disabled 处理

```c
if (is_migration_disabled(next_task)) {
    // 任务不能迁移，但可以把当前 CPU 上的 curr 推走
    push_task = get_push_task(rq);
    stop_one_cpu_nowait(rq->cpu, push_cpu_stop, push_task, ...);
}
```

当要推送的任务禁止迁移时，反过来把当前正在运行的任务推到其他 CPU，腾出位置。

---

## 五、Watchdog（RLIMIT_RTTIME）

```c
static void watchdog(struct rq *rq, struct task_struct *p)
{
    soft = task_rlimit(p, RLIMIT_RTTIME);   // 软限制
    hard = task_rlimit_max(p, RLIMIT_RTTIME); // 硬限制

    if (p->rt.watchdog_stamp != jiffies) {
        p->rt.timeout++;                  // 每 tick 加 1
        p->rt.watchdog_stamp = jiffies;
    }

    next = DIV_ROUND_UP(min(soft, hard), USEC_PER_SEC/HZ);
    if (p->rt.timeout > next)
        posix_cputimers_rt_watchdog(...);  // 发送 SIGXCPU/SIGKILL
}
```

| RLIMIT_RTTIME | 效果 |
|---------------|------|
| 软限制到达 | 发送 SIGXCPU（可捕获） |
| 硬限制到达 | 发送 SIGKILL（不可捕获，强杀） |
| RLIM_INFINITY | 不做任何检查 |

**与 RT Throttling 的区别**：Throttling 是全局限制所有 RT 的总运行比例；Watchdog 是 per-task 的，限制单个 RT 进程的连续运行时间。

---

## 六、RT Group Scheduling（CONFIG_RT_GROUP_SCHED）

### 6.1 层次结构

```
root_task_group
  ├── rt_bandwidth: period=1s, runtime=950ms
  ├── group_A
  │     └── rt_bandwidth: period=1s, runtime=200ms
  └── group_B
        └── rt_bandwidth: period=1s, runtime=300ms
```

**约束**：子组 runtime 之和 ≤ 父组 runtime（`tg_rt_schedulable()` 检查）

### 6.2 关键值

```c
// 每个 task_group 每个 CPU 有独立的 rt_rq
struct rt_rq {
    struct rt_bandwidth *tg;  // 所属的 task_group
    u64 rt_time;              // 本组在此 CPU 上的已用时间
    u64 rt_runtime;           // 本组在此 CPU 上的配额
    int rt_throttled;         // 本组是否被限流
    int rt_nr_boosted;        // 因优先级继承而提升的任务数
};
```

### 6.3 rt_nr_boosted

```c
static int rt_se_boosted(struct sched_rt_entity *rt_se)
{
    struct task_struct *p = rt_task_of(rt_se);
    return p->prio != p->normal_prio;  // 当前优先级 ≠ 正常优先级 → 被 boost 了
}
```

| 值 | 含义 |
|----|------|
| `prio == normal_prio` | 正常状态 |
| `prio < normal_prio` | 因为优先级继承（PI mutex）被提升 |
| `rt_nr_boosted > 0` | 该组有被提升的任务，即使组 runtime=0 也不能完全阻止其运行 |

---

## 七、调度类操作函数表

```c
DEFINE_SCHED_CLASS(rt) = {
    .enqueue_task       = enqueue_task_rt,      // 入队
    .dequeue_task       = dequeue_task_rt,      // 出队
    .yield_task         = yield_task_rt,        // 主动让出
    .wakeup_preempt     = wakeup_preempt_rt,   // 唤醒时的抢占检查
    .pick_task          = pick_task_rt,         // 选择下一个任务
    .put_prev_task      = put_prev_task_rt,     // 放回前一个任务
    .set_next_task      = set_next_task_rt,     // 设置下一个运行的任务
    .balance            = balance_rt,           // SMP 均衡入口
    .select_task_rq     = select_task_rq_rt,   // 唤醒时选 CPU
    .task_woken         = task_woken_rt,        // 唤醒后的 push 检查
    .switched_from      = switched_from_rt,     // 从 RT 切到其他类
    .switched_to        = switched_to_rt,       // 从其他类切到 RT
    .prio_changed       = prio_changed_rt,      // 优先级变化处理
    .task_tick          = task_tick_rt,         // tick 处理（RR 轮转）
    .update_curr        = update_curr_rt,       // 时间记账
};
```

---

## 八、总结：关键值速查表

| 常量/变量 | 值 | 含义 |
|-----------|-----|------|
| `MAX_RT_PRIO` | 100 | RT 优先级总数，范围 0~99 |
| `MAX_RT_PRIO - 1` | 99 | RT 最低优先级，队列空时的默认值 |
| `RUNTIME_INF` | `~0ULL` | 无限 runtime，表示不限制或已禁用 |
| `RR_TIMESLICE` | `100*HZ/1000` | SCHED_RR 默认时间片 100ms |
| `RT_MAX_TRIES` | 3 | push 时查找目标 CPU 的最大重试次数 |
| `CPUPRI_INVALID` | -1 | CPU 不可用（offline） |
| `sched_rt_period` | 1000000 μs | 带宽统计周期（1秒） |
| `sched_rt_runtime` | 950000~1000000 μs | 每周期 RT 允许运行时间 |
| `rt_throttled = 1` | — | 该 rt_rq 已被限流 |
| `overloaded = 1` | — | 该 CPU 有多个可运行 RT 任务 |
| `rt_period_active = 1` | — | 带宽控制定时器正在运行 |
| `highest_prio.curr` | 0~99 | 队列中最高优先级（最小数字） |
| `highest_prio.next` | 0~99 | 可推送任务中最高优先级 |
| `rt_nr_boosted > 0` | — | 有任务因 PI 被优先级提升 |

---

下一篇：[Linux 进程调度（四）：vruntime 在特殊时刻的变化]({% post_url scheduler/2026-06-14-linux-scheduler-04-vruntime-special %})
