---
layout: post
title: "Linux 进程调度（四）：vruntime 在特殊时刻的变化"
date: 2026-06-14 20:30:00 +0800
excerpt: "分析 CFS 中 vruntime 在几个关键时刻的变化规则：新进程创建、进程唤醒、进程睡眠、进程迁移（CPU 间）。理解这些边界情况是掌握 CFS 公平性的关键。"
---

# Linux 进程调度（四）：vruntime 在特殊时刻的变化

---

## 一、为什么需要特殊处理

vruntime 正常运行时的更新很简单：`vruntime += delta × (NICE_0_LOAD / weight)`。但以下特殊时刻如果不做处理，会破坏公平性：

| 时刻 | 问题 |
|------|------|
| 新进程创建 | vruntime=0 会导致新进程疯狂抢占 |
| 进程唤醒 | 长时间睡眠后 vruntime 远落后，醒来会霸占 CPU |
| 进程迁移 | 不同 CPU 的 rq 有不同的 min_vruntime 基准 |
| cfs_rq 空了又来进程 | min_vruntime 不能倒退 |

---

## 二、新进程创建时的 vruntime

### 2.1 问题

如果新进程 vruntime=0，而队列中其他进程的 vruntime 已经跑到了 100ms：
- 新进程 vruntime 最小 → 一直被选中运行
- 直到它追上 100ms 才公平 → 期间其他进程被饿死

### 2.2 解决：place_entity

新进程入队时，`place_entity()` 把它的 vruntime 放到队列当前水平附近：

```c
static void place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    u64 vruntime = avg_vruntime(cfs_rq);  // 队列加权平均 vruntime
    s64 lag = se->vlag;

    se->vruntime = vruntime - lag;
    // 新进程 vlag=0 → vruntime = 队列平均值
    // 不会太前（不霸占），也不会太后（不饿死）
}
```

### 2.3 举例

```
队列现状：A.vruntime=50ms, B.vruntime=52ms
         avg_vruntime ≈ 51ms

新进程 C fork：
  C.vlag = 0（新创建，没有历史欠债）
  C.vruntime = 51ms - 0 = 51ms

结果：C 从平均水平开始竞争，不会饿死也不会霸占
```

---

## 三、进程唤醒时的 vruntime

### 3.1 问题

进程睡了 10 秒，此时队列 avg_vruntime 已经推进了 10 秒。如果用旧 vruntime，它会一直被选中直到追上——**sleep 奖励过大**。

### 3.2 EEVDF 的解决：vlag 补偿

进程 dequeue（睡眠）时保存 `vlag`：

```c
// dequeue 时（进程进入睡眠）：
se->vlag = avg_vruntime(cfs_rq) - se->vruntime;
// vlag > 0: 说明进程 vruntime 落后于平均，欠了 CPU 时间
// vlag < 0: 说明进程 vruntime 领先于平均，多用了 CPU 时间
```

进程 enqueue（被唤醒）时恢复：

```c
// wakeup enqueue 时：
se->vruntime = avg_vruntime(cfs_rq) - se->vlag;
```

### 3.3 举例

```
进程 X 睡眠前：
  avg_vruntime = 100ms
  X.vruntime = 98ms
  X.vlag = 100 - 98 = 2ms  (欠了 2ms 的 CPU 时间)

进程 X 醒来时（10秒后）：
  avg_vruntime = 200ms（其他进程跑了 10 秒）
  X.vruntime = 200ms - 2ms = 198ms

结果：X 醒来后 vruntime = 198ms，比平均(200ms)少 2ms
      → 它有一点点优先权（补偿之前欠的），但不会霸占太久
      → 只"欠"2ms 就还完了，然后回到公平竞争
```

### 3.4 对比老 CFS 的做法

老 CFS 在唤醒时直接把 vruntime 设为 `max(vruntime, min_vruntime - 半个延迟)`，比较粗暴。EEVDF 的 vlag 方案更精确地保留了历史公平性信息。

---

## 四、进程睡眠（dequeue）时的处理

### 4.1 保存 vlag

```c
// 进程从 cfs_rq 移除时
static void dequeue_entity(...)
{
    update_entity_lag(cfs_rq, se);
    // → se->vlag = avg_vruntime(cfs_rq) - se->vruntime
}
```

### 4.2 min_vruntime 的维护

cfs_rq 维护一个 `min_vruntime`，它 **只会单调递增**：

```c
// min_vruntime 更新规则：
cfs_rq->min_vruntime = max(cfs_rq->min_vruntime, 新计算的 min)
```

**为什么不能倒退？** 如果 min_vruntime 倒退了，新创建/唤醒的进程会获得一个过小的 vruntime，对已有进程不公平。

### 4.3 举例：最后一个进程离开

```
队列只有 A (vruntime=100ms)
A 睡眠 → dequeue → cfs_rq 空了

min_vruntime 保持 100ms（不倒退）

后来 B 新创建入队：
  B.vruntime ≈ min_vruntime = 100ms
  → 不会回到 0
```

---

## 五、进程迁移（CPU 间）时的 vruntime

### 5.1 问题

每个 CPU 的 cfs_rq 有自己的 min_vruntime，它们不同步：

```
CPU0: min_vruntime = 50ms（负载轻，跑得少）
CPU1: min_vruntime = 200ms（负载重，跑得多）
```

如果进程从 CPU1 (vruntime=198ms) 迁移到 CPU0 (min_vruntime=50ms)：
- 198ms 远大于 50ms → 这个进程到了 CPU0 后永远不会被选中！

### 5.2 解决：归一化

**出队（离开源 CPU）时减去源 CPU 的 min_vruntime：**

```c
// 迁移 dequeue 时：
se->vruntime -= src_cfs_rq->min_vruntime;
// 得到一个"相对值"
```

**入队（进入目标 CPU）时加上目标 CPU 的 min_vruntime：**

```c
// 迁移 enqueue 时：
se->vruntime += dst_cfs_rq->min_vruntime;
```

### 5.3 举例

```
进程 X 在 CPU1: vruntime = 198ms, min_vruntime = 200ms
  → 出队：X.vruntime = 198 - 200 = -2ms（相对值：比平均少 2ms）

迁移到 CPU0: min_vruntime = 50ms
  → 入队：X.vruntime = -2 + 50 = 48ms

CPU0 上其他进程 vruntime ≈ 50ms
X.vruntime = 48ms → 比它们稍小 → X 会被优先调度一小会儿（补偿 2ms）

结果：迁移前后 X 的相对公平性被保持
```

---

## 六、scheduler_tick 中的 vruntime 更新

每个 tick 中断时：

```c
scheduler_tick()
  → task_tick_fair()
    → update_curr(cfs_rq)
      → delta_exec = now - curr->exec_start
      → curr->vruntime += calc_delta_fair(delta_exec, curr)
      → update_deadline(): 检查是否超过 deadline
        → 超过了 → resched_curr_lazy()
```

### 举例

进程 A（nice=0, weight=1024），tick 间隔 4ms（HZ=250）：

```
每 tick:
  delta_exec = 4ms
  vruntime += 4ms × (1024/1024) = 4ms

进程 B（nice=5, weight=335）：
  vruntime += 4ms × (1024/335) ≈ 12.2ms
```

B 的 vruntime 增长快 3 倍 → 很快超过 A → 调度器选 A 运行 → B 被切换走。

---

## 七、fork 时子进程的 vruntime

```c
// fork → sched_cgroup_fork → task_fork_fair
static void task_fork_fair(struct task_struct *p)
{
    struct sched_entity *se = &p->se;
    struct cfs_rq *cfs_rq = cfs_rq_of(&current->se);

    update_curr(cfs_rq);

    // 子进程继承父进程的 vruntime
    se->vruntime = current->se.vruntime;
    // 后续 place_entity 会调整
}
```

子进程初始 vruntime = 父进程当前 vruntime，然后 `place_entity` 做微调。这确保 fork bomb（大量 fork 新进程）不会获得不公平的优势——子进程从父进程的位置开始，而不是从 0 开始。

---

## 八、总结对照表

| 时刻 | vruntime 处理 | 目的 |
|------|--------------|------|
| 正常运行 | `+= delta × (NICE_0_LOAD / weight)` | 按权重比例增长 |
| 新进程创建 | `= avg_vruntime(cfs_rq)` | 从平均水平开始 |
| 进程唤醒 | `= avg_vruntime - vlag` | 精确恢复睡前相对位置 |
| 进程睡眠 | 保存 `vlag = avg - vruntime` | 记住欠债/多用情况 |
| CPU 迁移出 | `-= src_min_vruntime` | 归一化为相对值 |
| CPU 迁移入 | `+= dst_min_vruntime` | 适配新 CPU 的基准 |
| fork 子进程 | 继承父进程 vruntime | 防止 fork bomb |
| cfs_rq 空后重新入队 | min_vruntime 不倒退 | 防止新进程不公平 |
| deadline 到期 | `deadline = vruntime + virtual_slice` | 时间片管理 |

---

下一篇：[Linux 进程调度（五）：CFS Bandwidth Control]
