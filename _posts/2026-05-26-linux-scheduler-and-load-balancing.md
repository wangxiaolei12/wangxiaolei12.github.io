---
layout: post
title: "Linux CFS 调度器与负载均衡机制深入分析"
date: 2026-05-26 12:00:00 +0800
excerpt: "深入分析 Linux 内核 CFS 调度器的核心原理、vruntime 机制、抢占模型，以及 PELT 负载计算和多层次负载均衡策略。基于 mainline 内核源码。"
---

# Linux CFS 调度器与负载均衡机制深入分析

## 一、调度器整体架构

Linux 调度器采用模块化的调度类（sched_class）设计，按优先级从高到低排列：

```
stop_sched_class > dl_sched_class > rt_sched_class > [ext_sched_class] > fair_sched_class > idle_sched_class
```

每个 CPU 有一个 `struct rq`（运行队列），内部包含各调度类的子队列：
- `cfs_rq` — CFS（完全公平调度）
- `rt_rq` — 实时调度（SCHED_FIFO/SCHED_RR）
- `dl_rq` — Deadline 调度（SCHED_DEADLINE）
- `scx_rq` — sched_ext（BPF 可扩展调度，新特性）

### 1.1 核心数据结构

**`struct rq`**（per-CPU 运行队列）：

```c
struct rq {
    unsigned int        nr_running;      // 可运行任务总数
    struct task_struct  *donor;          // 调度上下文（决定谁被选中）
    struct task_struct  *curr;           // 执行上下文（实际在 CPU 上跑的）
    raw_spinlock_t      __lock;          // rq 锁
    struct cfs_rq       cfs;
    struct rt_rq        rt;
    struct dl_rq        dl;
    struct sched_domain *sd;             // 调度域（用于负载均衡）
    ...
};
```

注意 `donor` 和 `curr` 的分离——这是为了支持 **proxy execution**（代理执行），RT 内核中一个任务可以"借用"另一个被阻塞任务的调度优先级来执行。

**`struct sched_class`**（调度类接口）：

```c
struct sched_class {
    void (*enqueue_task)(struct rq *rq, struct task_struct *p, int flags);
    bool (*dequeue_task)(struct rq *rq, struct task_struct *p, int flags);
    void (*wakeup_preempt)(struct rq *rq, struct task_struct *p, int flags);
    struct task_struct *(*pick_task)(struct rq *rq, struct rq_flags *rf);
    void (*put_prev_task)(struct rq *rq, struct task_struct *p, struct task_struct *next);
    void (*set_next_task)(struct rq *rq, struct task_struct *p, bool first);
    int  (*select_task_rq)(struct task_struct *p, int task_cpu, int flags);
    void (*task_tick)(struct rq *rq, struct task_struct *p, int queued);
    ...
};
```


## 二、调度的触发时机

`__schedule()` 是核心调度函数，有以下触发路径：

1. **主动阻塞**（`SM_NONE`）：mutex、semaphore、waitqueue 等导致任务睡眠
2. **抢占**（`SM_PREEMPT`）：`TIF_NEED_RESCHED` 被设置后触发
3. **RT 锁等待**（`SM_RTLOCK_WAIT`）：PREEMPT_RT 下，spinlock/rwlock 转为 rt_mutex，竞争时需要调度
4. **Idle**（`SM_IDLE`）：idle 任务调用

### `__schedule()` 核心流程

```
__schedule(sched_mode)
  ├── local_irq_disable()
  ├── rq_lock(rq)                    // 获取 rq 锁
  ├── update_rq_clock(rq)
  │
  ├── 如果非抢占且 prev->state != RUNNING:
  │     try_to_block_task()          // 将任务从 rq 移除（dequeue）
  │
  ├── pick_next_task(rq, donor)      // 选择下一个任务
  │     ├── 快速路径：所有任务都是 CFS → 直接 pick_next_task_fair()
  │     └── 慢速路径：遍历调度类 for_each_active_class
  │           stop → dl → rt → [ext] → fair → idle
  │
  ├── 如果 prev != next:
  │     ├── rq->curr = next
  │     └── context_switch(prev, next)
  │           ├── switch_mm()        // 切换地址空间
  │           └── switch_to()        // 切换寄存器/栈
  │
  └── finish_task_switch(prev)       // 清理前一个任务
```

### 唤醒路径 `try_to_wake_up()`

```
try_to_wake_up(p, state, wake_flags)
  ├── 获取 p->pi_lock
  ├── 检查 p->state 是否匹配
  ├── 如果 p->on_rq（还在队列上）→ ttwu_runnable()
  ├── 否则：
  │     ├── p->state = TASK_WAKING
  │     ├── select_task_rq()         // 选择目标 CPU
  │     ├── set_task_cpu(p, cpu)     // 如果需要迁移
  │     └── ttwu_queue(p, cpu)
  │           ├── 可能走 wakelist（IPI 方式，避免远程 rq lock）
  │           └── 或直接 rq_lock + ttwu_do_activate()
  │                 ├── enqueue_task()
  │                 └── wakeup_preempt() → 可能 resched_curr()
  └── 释放 pi_lock
```

## 三、抢占机制

### TIF_NEED_RESCHED vs TIF_NEED_RESCHED_LAZY

这是 mainline 中新引入的 **lazy preemption** 机制：

- `TIF_NEED_RESCHED`：立即抢占（下一个 preempt_enable 或中断返回就调度）
- `TIF_NEED_RESCHED_LAZY`：延迟抢占（等到下一个 tick 或显式检查点才调度）

CFS 的 `task_tick` 和 `wakeup_preempt` 使用 `resched_curr_lazy()`，即设置 lazy 标志。在 `sched_tick()` 中：

```c
if (dynamic_preempt_lazy() && tif_test_bit(TIF_NEED_RESCHED_LAZY))
    resched_curr(rq);  // 将 lazy 提升为立即抢占
```

CFS 任务的抢占延迟最多一个 tick，而 RT/DL 任务使用 `resched_curr()`（立即抢占）。

### `resched_curr()` 的实现

```c
static void __resched_curr(struct rq *rq, int tif)
{
    // idle 任务总是立即抢占
    if (is_idle_task(curr) && tif == TIF_NEED_RESCHED_LAZY)
        tif = TIF_NEED_RESCHED;

    // 已经设置了就不重复
    if (cti->flags & ((1 << tif) | _TIF_NEED_RESCHED))
        return;

    if (cpu == smp_processor_id()) {
        set_ti_thread_flag(cti, tif);       // 本地 CPU 直接设标志
    } else {
        if (set_nr_and_not_polling(cti, tif))
            smp_send_reschedule(cpu);       // 远程 CPU 发 IPI
    }
}
```

### RT 内核对调度的关键改变

| 特性 | 非 RT | PREEMPT_RT |
|------|-------|------------|
| spinlock | 禁止抢占 | rt_mutex，可睡眠可抢占 |
| softirq | 中断上下文执行 | 线程化（ksoftirqd），可抢占 |
| 抢占模型 | TIF_NEED_RESCHED | + TIF_NEED_RESCHED_LAZY |
| 优先级继承 | 仅 rt_mutex | 所有 spinlock/rwlock |
| 调度模式 | SM_NONE / SM_PREEMPT | + SM_RTLOCK_WAIT |


## 四、CFS 调度器核心原理

### 4.1 传统 Unix 调度的问题

传统方式是 nice 值直接映射绝对时间片，有两个根本缺陷：

**问题 1：相对公平性随 nice 值非线性变化**

- nice=0 vs nice=1：时间片 100ms vs 95ms → 差距 5%
- nice=18 vs nice=19：时间片 10ms vs 5ms → 差距 100%

**问题 2：低优先级进程的切换风暴**

两个 nice=19 的进程各得 5ms 时间片，每秒切换 200 次。低优先级进程反而承受了更多的上下文切换开销。

### 4.2 CFS 的权重设计

CFS 让 nice 值对应不同的权重，每差 1 级 nice，CPU 占比差约 10%：

```c
static const int prio_to_weight[40] = {
/* -20 */ 88761, 71755, 56483, 46273, 36291,
/* -15 */ 29154, 23254, 18705, 14949, 11916,
/* -10 */  9548,  7620,  6100,  4904,  3906,
/*  -5 */  3121,  2501,  1991,  1586,  1277,
/*   0 */  1024,   820,   655,   526,   423,
/*   5 */   335,   272,   215,   172,   137,
/*  10 */   110,    87,    70,    56,    45,
/*  15 */    36,    29,    23,    18,    15,
};
```

无论在哪个 nice 区间，差 1 级的 CPU 占比差异始终约为 10%（乘法关系而非加法关系）。

### 4.3 虚拟运行时间（vruntime）

```
vruntime += delta_exec * (NICE_0_WEIGHT / weight)
         = delta_exec * (1024 / weight)
```

- 高权重进程：vruntime 增长慢
- 低权重进程：vruntime 增长快

### 4.4 为什么 vruntime 增速"理论上相同"

假设调度周期为 T，进程 i 的权重为 w_i，总权重为 W：

```
进程 i 的实际运行时间 = T * w_i / W
进程 i 的 vruntime 增量 = (T * w_i / W) * (1024 / w_i) = T * 1024 / W
```

所有进程的 vruntime 增量相同！这就是"完全公平"的含义。

### 4.5 具体例子

3 个进程 A(nice=0, w=1024)、B(nice=5, w=335)、C(nice=-5, w=3121)：

总权重 W = 4480，调度周期 T = 6ms

各进程实际运行时间：
- A: 6ms × 1024/4480 = 1.37ms
- B: 6ms × 335/4480 = 0.45ms
- C: 6ms × 3121/4480 = 4.18ms

各进程 vruntime 增量：
- A: 1.37ms × 1024/1024 = **1.37ms**
- B: 0.45ms × 1024/335 = **1.37ms**
- C: 4.18ms × 1024/3121 = **1.37ms**

全部相同！

### 4.6 红黑树组织

CFS 用红黑树按 vruntime 排序所有可运行进程：

```
        [vruntime=50]
       /             \
  [vruntime=30]    [vruntime=80]
  /
[vruntime=10]  ← 最左节点，下一个被调度
```

### 4.7 `place_entity()` — 唤醒/创建时的 vruntime 设置

```c
static void place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int initial)
{
    u64 vruntime = cfs_rq->min_vruntime;  // 以当前队列最小 vruntime 为基准

    // 新进程创建：惩罚，防止 fork bomb
    if (initial && sched_feat(START_DEBIT))
        vruntime += sched_vslice(cfs_rq, se);

    // 睡眠唤醒：给予补偿
    if (!initial) {
        unsigned long thresh = sysctl_sched_latency;  // 默认 6ms
        if (sched_feat(GENTLE_FAIR_SLEEPERS))
            thresh >>= 1;  // 减半为 3ms
        vruntime -= thresh;
    }

    // 永远不会让 vruntime 倒退
    se->vruntime = max_vruntime(se->vruntime, vruntime);
}
```

图示：

```
进程睡眠前的vruntime: |----X
当前 min_vruntime:              |------------------M
计算的补偿位置:                  |------------(M - thresh)

最终结果: se->vruntime = max(X, M - thresh) = M - thresh
（因为 X 远小于 M - thresh，所以用计算值）

如果进程只短暂睡眠:
进程的vruntime:                 |---------------X (接近 M)
计算的补偿位置:                  |------------(M - thresh)

最终结果: se->vruntime = max(X, M - thresh) = X
（保持原值，不给额外补偿）
```

| 场景 | vruntime 设置 | 效果 |
|------|--------------|------|
| 新 fork 进程 | min_vruntime + vslice | 排到队尾，不会立即抢占 |
| 长时间睡眠唤醒 | min_vruntime - 3ms | 有一定优势，很快被调度，但不会独占 |
| 短暂睡眠唤醒 | 保持原 vruntime | 无额外补偿 |


## 五、PELT 负载计算

### 5.1 核心数据结构

```c
struct sched_avg {
    u64  last_update_time;   // 上次更新时间（ns）
    u64  load_sum;           // 加权负载的累积和
    u64  runnable_sum;       // 可运行时间的累积和
    u32  util_sum;           // 实际运行时间的累积和
    u32  period_contrib;     // 当前周期已贡献的时间（us）
    unsigned long load_avg;  // 加权负载平均值
    unsigned long runnable_avg; // 可运行平均值
    unsigned long util_avg;  // 利用率平均值
    unsigned int  util_est;  // 利用率估计值
};
```

### 5.2 三个指标的含义

```
任务状态:     睡眠          在rq上等待        在CPU上运行
            ┌──────┐    ┌──────────────┐   ┌──────────────┐
            │      │    │              │   │              │
            │ 不计 │    │  runnable ✓  │   │  runnable ✓  │
            │ 入任 │    │  running  ✗  │   │  running  ✓  │
            │ 何指 │    │              │   │              │
            │ 标   │    │              │   │              │
            └──────┘    └──────────────┘   └──────────────┘

util_avg     = 运行时间 / 总时间 × 1024
runnable_avg = (等待+运行)时间 / 总时间 × 1024
load_avg     = weight × (等待+运行)时间 / 总时间
```

| 问题 | 看哪个指标 |
|------|-----------|
| CPU 需要跑多快？ | `util_avg`（实际干了多少活） |
| CPU 是否过载/任务在排队？ | `runnable_avg` vs `util_avg`（差距越大越过载） |
| 各 CPU 之间负载是否均衡？ | `load_avg`（考虑了优先级权重的公平分配） |

### 5.3 几何级数衰减

历史负载表示为几何级数，周期为 1024μs（约 1ms）：

```
load = u_0 + u_1*y + u_2*y^2 + u_3*y^3 + ...
```

其中 y^32 = 0.5，即：
- 32ms 前的贡献衰减为当前的 1/2
- 64ms 前衰减为 1/4
- 约 345ms 后贡献趋近于 0

最大值：`LOAD_AVG_MAX = 47742`

### 5.4 更新公式

```
           d1          d2           d3
           ^           ^            ^
           |           |            |
         |<->|<----------------->|<--->|
... |---x---|------| ... |------|-----x (now)

新的 sum = 旧sum * y^p + d1*y^p + 1024*Σ(y^n, n=1..p-1) + d3
```

代码实现：

```c
static __always_inline u32
accumulate_sum(u64 delta, struct sched_avg *sa,
               unsigned long load, unsigned long runnable, int running)
{
    // Step 1: 衰减旧值
    sa->load_sum = decay_load(sa->load_sum, periods);
    sa->runnable_sum = decay_load(sa->runnable_sum, periods);
    sa->util_sum = decay_load(sa->util_sum, periods);

    // Step 2: 计算新贡献 (d1*y^p + 完整周期 + d3)
    contrib = __accumulate_pelt_segments(periods, d1, d3);

    // Step 3: 按信号类型累加
    if (load)     sa->load_sum     += load * contrib;
    if (runnable) sa->runnable_sum += runnable * contrib;
    if (running)  sa->util_sum     += contrib;
}
```

### 5.5 从 sum 到 avg

```c
static void ___update_load_avg(struct sched_avg *sa, unsigned long load)
{
    u32 divider = LOAD_AVG_MAX - 1024 + sa->period_contrib;

    sa->load_avg     = load * sa->load_sum / divider;
    sa->runnable_avg = sa->runnable_sum / divider;
    sa->util_avg     = sa->util_sum / divider;
}
```

### 5.6 总结流程图

```
                    时间流逝
                       │
                       ▼
    ┌─────────────────────────────────┐
    │  ___update_load_sum()           │
    │  delta = now - last_update_time │
    │  衰减旧值 + 累加新贡献          │
    └──────────────┬──────────────────┘
                   │
         ┌─────────┼─────────┐
         ▼         ▼         ▼
    load_sum   runnable_sum  util_sum
    (权重×在队列) (在队列时间)  (运行时间)
         │         │         │
         ▼         ▼         ▼
    ┌─────────────────────────────────┐
    │  ___update_load_avg()           │
    │  avg = sum / divider            │
    └──────────────┬──────────────────┘
                   │
         ┌─────────┼─────────┐
         ▼         ▼         ▼
    load_avg   runnable_avg  util_avg
      │              │          │
      ▼              ▼          ▼
   负载均衡      过载判断     DVFS调频
   任务迁移      组类型分类   EAS能效调度
```


## 六、负载均衡机制

### 6.1 总体架构

| 类型 | 时机 | 方向 | 函数 |
|------|------|------|------|
| 任务放置 | 唤醒/fork/exec | 选择最优 CPU 放入 | `select_task_rq_fair()` |
| 周期性均衡 | tick 触发 softirq | 从忙 CPU 拉任务到闲 CPU | `sched_balance_rq()` |
| idle 均衡 | CPU 即将 idle | 主动从忙 CPU 拉任务 | `sched_balance_newidle()` |
| NOHZ 均衡 | 有 CPU 进入 tickless | 代替 idle CPU 做均衡 | `nohz_idle_balance()` |

### 6.2 调度域层次结构

```
                    ┌─────────────────────────────┐
Level 3 (NUMA)     │  SD_NUMA: 全系统所有 CPU      │
                    └──────────────┬──────────────┘
                         ┌─────────┴─────────┐
Level 2 (MC/LLC)   ┌────┴────┐         ┌────┴────┐
                    │ Node 0  │         │ Node 1  │
                    │ CPU 0-7 │         │ CPU 8-15│
                    └────┬────┘         └─────────┘
                    ┌────┴────┐
Level 1 (SMT)      │Core 0   │  ...
                    │CPU 0,1  │
                    └─────────┘
```

设计原则：低层级（SMT/LLC）均衡频繁且代价低，高层级（NUMA）均衡稀少但代价高。

### 6.3 任务放置（唤醒时的 CPU 选择）

```
select_task_rq_fair()
  │
  ├── 1. EAS（能效感知调度）：find_energy_efficient_cpu()
  │     如果系统未过载且有 Energy Model，选能效最优的 CPU
  │
  ├── 2. Wake Affine（亲和性）：wake_affine()
  │     判断是否应该把任务拉到唤醒者所在的 CPU
  │     ├── wake_affine_idle()：唤醒者 CPU 空闲就拉过来
  │     └── wake_affine_weight()：比较两边负载，轻的一边拉
  │
  ├── 3. select_idle_sibling()（快速路径）
  │     在目标 CPU 附近找空闲 CPU：
  │     ├── 目标 CPU 本身空闲？用它
  │     ├── prev_cpu 空闲？用它
  │     ├── select_idle_core()：找整个空闲的核
  │     ├── select_idle_cpu()：在 LLC 域内扫描空闲 CPU
  │     └── select_idle_smt()：找空闲的 SMT 兄弟
  │
  └── 4. sched_balance_find_dst_cpu()（慢速路径，fork/exec）
        在域内找最空闲的组，再找组内最空闲的 CPU
```

### 6.4 周期性负载均衡

触发路径：

```
sched_tick()
  → sched_balance_trigger(rq)
    → if (time_after_eq(jiffies, rq->next_balance))
        raise_softirq(SCHED_SOFTIRQ)

SCHED_SOFTIRQ handler:
  sched_balance_softirq()
    → sched_balance_domains(rq, idle)
      → for_each_domain(cpu, sd)  // 从低到高遍历每个调度域
          if (到了均衡时间)
            sched_balance_rq(cpu, rq, sd, idle)
```

`sched_balance_rq()` 核心流程：

```
sched_balance_rq()
  │
  ├── should_we_balance()
  │     只有域内第一个空闲 CPU 才执行均衡
  │
  ├── sched_balance_find_src_group()  ← 找最忙的组
  │     ├── update_sd_lb_stats()：统计域内每个组的负载
  │     ├── 判断组类型（group_type）
  │     └── calculate_imbalance()：计算需要迁移多少负载
  │
  ├── sched_balance_find_src_rq()  ← 在最忙组中找最忙的 rq
  │
  ├── detach_tasks()  ← 从忙 rq 摘取任务
  │     - 不能是 cache hot 的
  │     - 不能是 CPU 亲和性不允许的
  │     - 迁移后能减少不均衡
  │
  └── attach_tasks()  ← 将任务放到本地 rq
```

### 6.5 组类型（group_type）

```c
enum group_type {
    group_has_spare,      // 有空闲容量
    group_fully_busy,     // 满负荷但不竞争
    group_misfit_task,    // 有任务不适合当前 CPU（大核/小核）
    group_smt_balance,    // SMT 兄弟都忙，可以迁到空闲核
    group_asym_packing,   // 非对称打包（优先用高性能 CPU）
    group_imbalanced,     // 因亲和性约束导致的不均衡
    group_overloaded      // 过载，任务在竞争 CPU
};
```

迁移量计算根据不同的 `migration_type`：

| 迁移类型 | 含义 | 场景 |
|----------|------|------|
| `migrate_load` | 按负载权重迁移 | 两边都 overloaded |
| `migrate_util` | 按利用率迁移 | 一边 overloaded 一边有余量 |
| `migrate_task` | 按任务数迁移 | 一边有空闲 CPU |
| `migrate_misfit` | 迁移不匹配的任务 | 大小核场景 |

### 6.6 NOHZ 均衡

当 CPU 进入 tickless idle 后，它不再有 tick 来触发均衡：

```
忙 CPU 的 sched_tick()
  → nohz_balancer_kick(rq)
    → kick_ilb()：通过 IPI 唤醒一个 idle CPU

被唤醒的 idle CPU:
  sched_balance_softirq()
    → nohz_idle_balance()
      → 代替所有 tickless idle CPU 执行 sched_balance_domains()
```

### 6.7 完整的均衡决策流程图

```
                    ┌──────────────┐
                    │  sched_tick  │
                    └──────┬───────┘
                           │
              ┌────────────▼────────────┐
              │ sched_balance_trigger() │
              │ 到时间了？              │
              └────────────┬────────────┘
                           │ raise SCHED_SOFTIRQ
              ┌────────────▼────────────┐
              │ sched_balance_softirq() │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │ sched_balance_domains() │
              │ 遍历每个调度域层级       │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  sched_balance_rq()     │
              └────────────┬────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                  ▼
┌────────────────┐ ┌──────────────┐ ┌────────────────┐
│find_src_group()│ │find_src_rq() │ │ detach_tasks() │
│找最忙的组      │ │找最忙的rq    │ │ 摘取任务       │
└────────────────┘ └──────────────┘ └───────┬────────┘
                                            │
                                   ┌────────▼────────┐
                                   │ attach_tasks()  │
                                   │ 放到本地rq      │
                                   └─────────────────┘
```

### 6.8 关键调优参数

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `sched_migration_cost_ns` | 500000 (0.5ms) | 任务被认为 cache hot 的时间 |
| `sched_nr_migrate` | 32 | 一次均衡最多迁移的任务数 |
| `balance_interval` | 域相关 | 均衡检查间隔 |
| `imbalance_pct` | 125 | 负载差超过 25% 才迁移 |

## 七、总结

Linux 调度器是一个多层次的系统：

1. **CFS 公平调度**：通过 vruntime 和权重实现比例公平，用红黑树 O(log n) 选择下一个任务
2. **PELT 负载追踪**：用指数衰减的历史加权平均精确度量每个实体的负载/利用率
3. **多层次负载均衡**：唤醒时放置、idle 拉取、周期性检查、NOHZ 代理，保守迁移避免 cache 抖动
4. **RT 抢占支持**：lazy preemption、rt_mutex 优先级继承、proxy execution

设计哲学是**保守迁移**：迁移有代价（cache 失效、TLB flush），只在不均衡足够大时才行动。
