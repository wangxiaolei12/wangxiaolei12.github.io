---
layout: post
title: "Linux 进程调度（三）：RT 实时调度"
date: 2026-06-14 20:00:00 +0800
excerpt: "深入分析 Linux RT 调度器：SCHED_FIFO 和 SCHED_RR 的区别、优先级位图选择算法、RT throttling 带宽限制机制、以及 RT 调度对 CFS 的绝对优先关系。结合 mainline kernel/sched/rt.c 源码。"
---

# Linux 进程调度（三）：RT 实时调度

基于 mainline `kernel/sched/rt.c` 源码分析

---

## 一、RT 调度类的定位

```
调度类优先级链：stop → dl → RT → cfs → idle
                              ↑
                          本文分析
```

RT 调度类服务于 `SCHED_FIFO` 和 `SCHED_RR` 两种策略，**绝对优先于 CFS**。只要有 RT 进程可运行，CFS 进程就得不到 CPU。

---

## 二、SCHED_FIFO vs SCHED_RR

| | SCHED_FIFO | SCHED_RR |
|--|-----------|----------|
| 时间片 | **无**（一直运行直到主动让出或被更高优先级抢占） | 有（默认 100ms） |
| 同优先级行为 | 先来先服务，不轮转 | 时间片到期后轮转到同优先级末尾 |
| 让出 CPU 的条件 | 主动 yield/sleep/更高优先级抢占 | + 时间片到期 |

### 举例

3 个 RT 进程，优先级都是 50：

**SCHED_FIFO：**
```
A 先入队 → A 一直运行 → A 永远不会让给 B、C
（除非 A 主动 sleep 或 yield）
```

**SCHED_RR：**
```
A 运行 100ms → 时间片到期 → 移到队尾 → B 运行 100ms → C 运行 100ms → A...
```

---

## 三、RT 优先级

### 3.1 优先级范围

```
RT 优先级: 0 ~ 99（数字越大优先级越高）
对应内核 prio: 0 ~ 99（MAX_RT_PRIO = 100）

用户空间 sched_priority: 1 ~ 99
内核 prio = 99 - sched_priority

所以用户设 sched_priority=99 → 内核 prio=0 → 最高优先级
```

### 3.2 数据结构：优先级数组

```c
struct rt_prio_array {
    DECLARE_BITMAP(bitmap, MAX_RT_PRIO + 1);  // 100+1 bit 位图
    struct list_head queue[MAX_RT_PRIO];       // 100 个链表
};
```

```
bitmap:  [0][1][2]...[49][50]...[98][99]
          │               │
          ▼               ▼
queue[0]: task_a → task_b   queue[50]: task_c → task_d
```

- `bitmap` 中每个 bit 表示对应优先级链表是否有可运行 task
- 选择最高优先级进程 = `sched_find_first_bit(bitmap)`，O(1)

---

## 四、pick_next_task_rt——选择进程

```c
static struct task_struct *_pick_next_task_rt(struct rq *rq)
{
    struct sched_rt_entity *rt_se;
    struct rt_rq *rt_rq = &rq->rt;

    do {
        rt_se = pick_next_rt_entity(rt_rq);  // 从最高优先级链表取第一个
        rt_rq = group_rt_rq(rt_se);          // 处理 group scheduling
    } while (rt_rq);

    return rt_task_of(rt_se);
}
```

`pick_next_rt_entity` 内部：
```c
// 1. 找到 bitmap 中第一个置位的 bit（最高优先级）
idx = sched_find_first_bit(array->bitmap);
// 2. 从对应链表取第一个 entry
queue = array->queue + idx;
return list_first_entry(queue, ...);
```

**时间复杂度：O(1)**——不管有多少 RT 进程，选择操作都是常数时间。

---

## 五、task_tick_rt——时钟 tick 处理

```c
static void task_tick_rt(struct rq *rq, struct task_struct *p, int queued)
{
    update_curr_rt(rq);

    // SCHED_FIFO 不做时间片管理
    if (p->policy != SCHED_RR)
        return;

    // SCHED_RR：时间片递减
    if (--p->rt.time_slice)
        return;

    // 时间片到期：重填 + 移到队尾 + resched
    p->rt.time_slice = sched_rr_timeslice;  // 默认 100ms

    // 如果同优先级还有其他进程，才轮转
    for_each_sched_rt_entity(rt_se) {
        if (rt_se->run_list.prev != rt_se->run_list.next) {
            requeue_task_rt(rq, p, 0);  // 移到链表末尾
            resched_curr(rq);           // 标记需要重调度
            return;
        }
    }
}
```

### 关键点

- SCHED_FIFO：`task_tick_rt` 直接 return，不做任何事——永不超时
- SCHED_RR：每 tick 递减 `time_slice`，到 0 时轮转
- **只在同优先级有多个进程时才轮转**，如果是独占优先级，即使 time_slice 到期也不切换（没别人可切）

### RR 时间片

```c
#define RR_TIMESLICE  (100 * HZ / 1000)  // 100ms

int sched_rr_timeslice = RR_TIMESLICE;
// 可通过 /proc/sys/kernel/sched_rr_timeslice_ms 调整
```

---

## 六、RT 抢占——check_preempt_curr

当一个 RT 进程被唤醒时，会检查是否需要抢占当前进程：

```c
static void wakeup_preempt_rt(struct rq *rq, struct task_struct *p, int flags)
{
    // 如果新唤醒的 RT 进程优先级高于当前进程 → 立即抢占
    if (p->prio < rq->curr->prio) {
        resched_curr(rq);
        return;
    }
}
```

### 举例

```
当前运行: 进程 A (SCHED_FIFO, prio=50)
唤醒:     进程 B (SCHED_FIFO, prio=30)  ← 30 < 50，优先级更高

→ resched_curr() → 中断返回时 schedule()
→ pick_next_task_rt() 选中 B
→ A 被抢占，B 开始运行
```

**同优先级不抢占**：如果 B 也是 prio=50，不会抢占 A（FIFO 先来先服务）。

---

## 七、RT Throttling——防止 RT 饿死 CFS

### 7.1 问题

如果 RT 进程有 bug（死循环），CFS 进程永远得不到 CPU，系统变得不可用。

### 7.2 解决：RT 带宽限制

```c
int sysctl_sched_rt_period  = 1000000;  // 1 秒周期
int sysctl_sched_rt_runtime =  950000;  // RT 最多用 0.95 秒
```

**含义：每 1 秒中，RT 进程最多运行 950ms，剩余 50ms 留给 CFS。**

### 7.3 Throttling 触发

```c
static int sched_rt_runtime_exceeded(struct rt_rq *rt_rq)
{
    u64 runtime = sched_rt_runtime(rt_rq);  // 950ms

    // runtime >= period 说明无限制
    if (runtime >= sched_rt_period(rt_rq))
        return 0;

    // RT 实际运行时间超过分配的 runtime
    if (rt_rq->rt_time > runtime) {
        rt_rq->rt_throttled = 1;
        printk_deferred_once("sched: RT throttling activated\n");
        sched_rt_rq_dequeue(rt_rq);  // 将 RT 整体从 rq 移除
        return 1;
    }
    return 0;
}
```

被 throttle 后，RT 进程暂停运行，CFS 得到 CPU。等到下一个 period 开始时，`rt_time` 重置，RT 重新获得运行权。

### 7.4 举例

```
时间线 (1 秒内):
0ms                              950ms        1000ms
├── RT 进程运行 ─────────────────┤ CFS 运行 ──┤
                                 ↑
                          RT throttled!
                          "sched: RT throttling activated"
```

### 7.5 禁用 throttling

```bash
# 设置 rt_runtime = -1 表示无限制（危险！RT 可以饿死所有 CFS）
echo -1 > /proc/sys/kernel/sched_rt_runtime_us
```

---

## 八、RT 调度的完整流程

### 8.1 进程创建/设置 RT 策略

```c
// 用户空间设置进程为 RT
struct sched_param param = { .sched_priority = 50 };
sched_setscheduler(pid, SCHED_FIFO, &param);
```

### 8.2 运行时流程

```
1. RT 进程被唤醒
   → enqueue_task_rt(): 加入对应优先级链表 + 置 bitmap bit
   → check_preempt_curr(): 如果比当前进程优先级高 → resched_curr()

2. 中断返回时 schedule()
   → pick_next_task(): 先查 rt_sched_class
   → _pick_next_task_rt(): bitmap 找最高优先级 → 取链表头
   → context_switch() 切换到 RT 进程

3. RT 进程运行中，每 tick:
   → task_tick_rt():
     FIFO: 什么都不做
     RR: time_slice--, 到0则轮转

4. RT 进程睡眠
   → dequeue_task_rt(): 从优先级链表移除
   → 可能清 bitmap bit
   → schedule() 选下一个（可能是另一个 RT 或 CFS）
```

---

## 九、RT 优先级 vs CFS nice 值

```
┌──────────────────────────────────────────────────┐
│  内核优先级 (prio)                                │
│                                                  │
│  0 ─────── 99: RT 优先级 (SCHED_FIFO/RR)         │
│  100 ───── 139: CFS 普通优先级 (nice -20 ~ 19)   │
│                                                  │
│  数字越小优先级越高                                │
└──────────────────────────────────────────────────┘
```

所以 **最低优先级的 RT 进程 (prio=99)** 仍然高于 **最高优先级的 CFS 进程 (prio=100, nice=-20)**。

---

## 十、sysctl 参数总结

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `sched_rt_period_us` | 1000000 (1s) | RT 带宽统计周期 |
| `sched_rt_runtime_us` | 950000 (0.95s) | 每周期 RT 最大运行时间，-1=无限 |
| `sched_rr_timeslice_ms` | 100 | SCHED_RR 的时间片 |

---

## 十一、实际应用场景

| 场景 | 策略选择 | 原因 |
|------|----------|------|
| 音频 ALSA 线程 | SCHED_FIFO, prio=50~80 | 不能被打断，否则 underrun |
| 工业控制 | SCHED_FIFO, prio=90+ | 严格延迟要求 |
| 周期性采集 | SCHED_RR, prio=50 | 多个同优先级采集线程公平轮转 |
| migration 线程 | SCHED_FIFO, prio=99 | 内核最高优先级，负载均衡 |
| watchdog | SCHED_FIFO, prio=99 | 必须能抢占一切 |

---

## 十二、总结

| 概念 | 说明 |
|------|------|
| 调度策略 | SCHED_FIFO（无时间片）/ SCHED_RR（100ms 轮转） |
| 优先级范围 | 用户 1~99，越大越高；内核 0~99，越小越高 |
| 选择算法 | 位图 + 链表，O(1) |
| 抢占规则 | 高优先级 RT 立即抢占低优先级任何进程 |
| 同优先级 | FIFO 不轮转，RR 轮转 |
| Throttling | 默认每秒 RT 最多跑 950ms，防止饿死 CFS |
| 与 CFS 关系 | RT 绝对优先于 CFS |

---

下一篇：[Linux 进程调度（四）：vruntime 在特殊时刻的变化]
