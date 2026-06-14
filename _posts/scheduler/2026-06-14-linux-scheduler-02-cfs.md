---
layout: post
title: "Linux 进程调度（二）：CFS 完全公平调度算法"
date: 2026-06-14 19:30:00 +0800
excerpt: "深入分析 CFS/EEVDF 调度算法的核心原理：vruntime 计算、权重与 nice 值映射、时间片分配、pick_next_task 选择逻辑、以及新进程/唤醒进程的 vruntime 放置策略。结合 mainline kernel/sched/fair.c 源码。"
---

# Linux 进程调度（二）：CFS 完全公平调度算法

基于 mainline `kernel/sched/fair.c` 源码分析

---

## 一、CFS 的核心思想

CFS (Completely Fair Scheduler) 的目标：**让每个进程获得的 CPU 时间与其权重成正比**。

如果两个进程权重相同，它们应该各获得 50% 的 CPU 时间。如果进程 A 的权重是 B 的 2 倍，那么 A 应该获得 2/3，B 获得 1/3。

实现手段：**vruntime（虚拟运行时间）**。

---

## 二、vruntime——公平的度量

### 2.1 定义

```
vruntime = 实际运行时间 × (NICE_0_LOAD / 进程权重)
```

- 权重大的进程（高优先级），vruntime 增长慢
- 权重小的进程（低优先级），vruntime 增长快
- **CFS 永远选择 vruntime 最小的进程运行**

### 2.2 举例

假设进程 A（nice=0, weight=1024）和进程 B（nice=5, weight=335）同时可运行：

```
A 实际运行 1ms:
  vruntime_A += 1ms × (1024/1024) = 1ms

B 实际运行 1ms:
  vruntime_B += 1ms × (1024/335) ≈ 3.06ms
```

A 跑 1ms vruntime 增加 1ms，B 跑 1ms vruntime 增加 3.06ms。

结果：A 能获得更多的实际运行时间才会追上 B 的 vruntime → A 得到更多 CPU → **权重大的进程获得更多 CPU 时间**。

### 2.3 源码：calc_delta_fair

```c
/*
 * delta_exec * weight / lw->weight
 * 即：实际运行时间 * NICE_0_LOAD / 进程权重
 */
static inline u64 calc_delta_fair(u64 delta, struct sched_entity *se)
{
    if (unlikely(se->load.weight != NICE_0_LOAD))
        delta = __calc_delta(delta, NICE_0_LOAD, &se->load);
    return delta;
}
```

如果进程权重正好是 `NICE_0_LOAD`（nice=0），vruntime 增量就等于实际运行时间（不需要计算）。

---

## 三、权重与 nice 值

### 3.1 nice 值到权重的映射

Linux 用一个预计算表把 nice 值（-20 ~ 19）映射为权重：

```c
const int sched_prio_to_weight[40] = {
 /* -20 */  88761,  71755,  56483,  46273,  36291,
 /* -15 */  29154,  23254,  18705,  14949,  11916,
 /* -10 */   9548,   7620,   6100,   4904,   3906,
 /*  -5 */   3121,   2501,   1991,   1586,   1277,
 /*   0 */   1024,    820,    655,    526,    423,
 /*   5 */    335,    272,    215,    172,    137,
 /*  10 */    110,     87,     70,     56,     45,
 /*  15 */     36,     29,     23,     18,     15,
};
```

### 3.2 设计规则

**相邻 nice 值之间的权重比约为 1.25:1**（即 CPU 时间差约 10%）。

| nice | 权重 | 说明 |
|------|------|------|
| -20 | 88761 | 最高优先级普通进程 |
| 0 | 1024 | 基准 (NICE_0_LOAD) |
| 19 | 15 | 最低优先级普通进程 |

### 3.3 举例：nice=0 vs nice=5

```
weight_A = 1024 (nice=0)
weight_B = 335  (nice=5)

CPU 时间比 = weight_A : weight_B = 1024 : 335 ≈ 3:1

如果两个进程竞争一个 CPU：
  A 获得 1024/(1024+335) ≈ 75% 的 CPU
  B 获得 335/(1024+335) ≈ 25% 的 CPU
```

---

## 四、EEVDF：新一代 CFS（Linux 6.6+）

从 Linux 6.6 开始，CFS 引入了 **EEVDF (Earliest Eligible Virtual Deadline First)** 算法，替代了原来的纯 vruntime 红黑树选择。

### 4.1 核心变化

| | 旧 CFS | EEVDF |
|--|--------|-------|
| 选择依据 | vruntime 最小的进程 | **deadline 最早且 eligible 的进程** |
| 时间片 | sched_latency / nr_running | 固定 base_slice (默认 0.7ms) |
| 公平性 | 长期公平 | 短期也公平（有 lag 补偿） |

### 4.2 关键概念

- **slice**：每个进程的请求时间（默认 `sysctl_sched_base_slice = 700000ns = 0.7ms`）
- **deadline**：`vd_i = ve_i + r_i / w_i`（vruntime + 虚拟时间片）
- **eligible**：进程的 vruntime ≤ 队列平均 vruntime 时，才有资格被选中

### 4.3 源码：update_deadline

```c
static bool update_deadline(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    // 如果 vruntime 还没超过 deadline，继续运行
    if (vruntime_cmp(se->vruntime, "<", se->deadline))
        return false;

    // 时间片用完，计算新 deadline
    if (!se->custom_slice)
        se->slice = sysctl_sched_base_slice;  // 默认 0.7ms

    /*
     * EEVDF: vd_i = ve_i + r_i / w_i
     * deadline = vruntime + calc_delta_fair(slice, se)
     */
    se->deadline = se->vruntime + calc_delta_fair(se->slice, se);

    return true;  // 返回 true 表示需要重新调度
}
```

### 4.4 举例

进程 A（nice=0, weight=1024），slice=0.7ms：
```
virtual_slice = calc_delta_fair(0.7ms, A) = 0.7ms × (1024/1024) = 0.7ms
deadline_A = vruntime_A + 0.7ms
```

进程 B（nice=5, weight=335），slice=0.7ms：
```
virtual_slice = calc_delta_fair(0.7ms, B) = 0.7ms × (1024/335) ≈ 2.14ms
deadline_B = vruntime_B + 2.14ms
```

B 的 virtual slice 更大 → deadline 更远 → 更不容易被选中 → 低优先级进程得到更少的 CPU。

---

## 五、update_curr——vruntime 的更新

`update_curr()` 是 CFS 的核心函数，在几乎所有调度路径中被调用：

```c
static void update_curr(struct cfs_rq *cfs_rq)
{
    struct sched_entity *curr = cfs_rq->curr;
    s64 delta_exec;

    // 1. 计算实际运行时间
    delta_exec = update_se(rq, curr);
    if (delta_exec <= 0)
        return;

    // 2. 更新 vruntime
    curr->vruntime += calc_delta_fair(delta_exec, curr);

    // 3. 检查是否超过 deadline（时间片到期）
    resched = update_deadline(cfs_rq, curr);

    // 4. 如果时间片到期 → 标记需要重新调度
    if (resched || !protect_slice(curr)) {
        resched_curr_lazy(rq);  // 设置 TIF_NEED_RESCHED_LAZY
    }
}
```

### 调用时机

- `scheduler_tick()` → `task_tick_fair()` → `update_curr()`（每 tick）
- `enqueue_entity()` → `update_curr()`（入队时）
- `dequeue_entity()` → `update_curr()`（出队时）
- `pick_next_entity()` → `update_curr()`（选进程时）

---

## 六、pick_next_task——选择下一个进程

### 6.1 EEVDF 的选择逻辑

```c
static struct sched_entity *pick_eevdf(struct cfs_rq *cfs_rq)
{
    // 从红黑树中选择 deadline 最早且 eligible 的进程
    // eligible 条件：se->vruntime <= avg_vruntime(cfs_rq)
}
```

简化理解：
1. 遍历红黑树（按 deadline 排序）
2. 找到第一个 eligible（vruntime 不超过队列平均值）的进程
3. 返回该进程

### 6.2 为什么要 eligible 条件

如果只看 deadline，一个刚唤醒的进程（vruntime 很小）可能有极早的 deadline，会立刻抢占当前进程。eligible 条件确保只有"欠了 CPU 时间"的进程才能被选中，防止饥饿。

---

## 七、place_entity——新进程/唤醒进程的 vruntime 放置

### 7.1 问题

一个进程睡了很久，其 vruntime 远落后于其他进程。如果直接用旧 vruntime，它会长时间霸占 CPU 直到追上其他进程——这不公平。

### 7.2 EEVDF 的放置策略

```c
static void place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    u64 vruntime = avg_vruntime(cfs_rq);  // 队列平均 vruntime
    s64 lag = se->vlag;                    // 进程的虚拟延迟

    // 利用保存的 lag 来恢复相对位置
    // vruntime = V - vlag（V 是当前队列平均虚拟时间）
    se->vruntime = vruntime - lag;

    // 重新计算 deadline
    se->deadline = se->vruntime + calc_delta_fair(se->slice, se);
}
```

### 7.3 lag 的含义

```
lag_i = w_i × (V - v_i)
vlag_i = V - v_i
```

- `vlag > 0`：进程欠了 CPU 时间（之前跑得少），放置时给它更小的 vruntime
- `vlag < 0`：进程用了多余的 CPU 时间，放置时给它更大的 vruntime
- `vlag = 0`：刚好公平

这确保进程睡眠唤醒后，能恢复到它应有的公平位置，而不是极端靠前或靠后。

---

## 八、红黑树组织

CFS 用红黑树组织所有 runnable 的 sched_entity：

```
            (按 deadline 排序)
              ┌───────┐
              │  root │
              └───┬───┘
            ┌─────┴─────┐
        ┌───┴───┐   ┌───┴───┐
        │  B    │   │  D    │
        │ dl=5  │   │ dl=8  │
        └───┬───┘   └───┬───┘
      ┌─────┴──┐        └──┐
  ┌───┴───┐ ┌──┴──┐   ┌───┴───┐
  │  A    │ │  C  │   │  E    │
  │ dl=3  │ │ dl=6│   │ dl=10 │
  └───────┘ └─────┘   └───────┘

pick_eevdf(): 选择 deadline 最小且 eligible 的
→ A (dl=3)，如果 A 的 vruntime <= avg_vruntime → 选 A
```

---

## 九、sysctl 调优参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `sched_base_slice_ns` | 700000 (0.7ms) | 每个进程的基础时间片 |

在老 CFS 中还有：
| 参数 | 说明 |
|------|------|
| `sched_latency_ns` | 调度周期（所有进程跑一轮的时间） |
| `sched_min_granularity_ns` | 最小时间片 |
| `sched_wakeup_granularity_ns` | 唤醒抢占的 vruntime 差值门槛 |

EEVDF 简化了这些，核心参数只有 `sched_base_slice`。

---

## 十、完整例子：3 个进程的调度过程

进程 A(nice=0), B(nice=0), C(nice=5)，同时就绪：

```
初始状态:
  A: vruntime=0, weight=1024
  B: vruntime=0, weight=1024
  C: vruntime=0, weight=335

base_slice = 0.7ms

T0: pick_eevdf → 选 A（deadline 都一样时选第一个）
    A 运行 0.7ms
    A.vruntime += 0.7ms × (1024/1024) = 0.7ms
    A.deadline = 0.7 + 0.7 = 1.4ms
    → update_deadline 返回 true → resched

T1: pick_eevdf → B (vruntime=0 < avg, deadline=0.7)
    B 运行 0.7ms
    B.vruntime += 0.7ms
    B.deadline = 0.7 + 0.7 = 1.4ms
    → resched

T2: pick_eevdf → C (vruntime=0 < avg, deadline 最小)
    C 运行 0.7ms
    C.vruntime += 0.7ms × (1024/335) ≈ 2.14ms
    C.deadline = 2.14 + 2.14 = 4.28ms
    → resched

T3: pick_eevdf → A (vruntime=0.7, deadline=1.4, B 也是 1.4)
    A 再次运行...

结果：A 和 B 各运行了约 43% CPU，C 运行了约 14% CPU
      (1024:1024:335) ≈ 3:3:1 ✓
```

---

## 十一、总结

| 概念 | 说明 |
|------|------|
| vruntime | 虚拟运行时间，权重大增长慢 |
| weight | nice 映射的权重，决定 vruntime 增速 |
| slice | 基础时间片 (0.7ms)，到期后重新调度 |
| deadline | vruntime + virtual_slice，EEVDF 选择依据 |
| eligible | vruntime ≤ 队列平均 → 有资格被选中 |
| lag/vlag | 保存进程的公平性欠债，唤醒时恢复 |
| calc_delta_fair | 核心计算：delta × NICE_0_LOAD / weight |
| update_curr | 每 tick / 每次调度事件更新 vruntime |
| pick_eevdf | 选 deadline 最早且 eligible 的进程 |

CFS 的美妙之处：**用一个简单的 vruntime 概念，将不同权重的进程统一到同一个时间轴上比较，自然实现按比例分配 CPU 时间。**

---

下一篇：[Linux 进程调度（三）：RT 实时调度]
