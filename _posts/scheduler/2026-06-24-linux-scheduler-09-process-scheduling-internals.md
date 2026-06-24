---
layout: post
title: "Linux 进程调度（九）：调度核心数据结构与调度流程源码分析"
date: 2026-06-24 10:00:00 +0800
excerpt: "从 task_struct 到 rq，从 sched_class 到 __schedule()，全面解剖 Linux 调度器核心数据结构及其关联关系。逐行分析 __schedule()、pick_next_task()、try_to_wake_up()、context_switch() 等关键函数，理解调度的完整生命周期。基于 mainline 源码。"
---

# Linux 进程调度（九）：调度核心数据结构与调度流程源码分析

基于 mainline `kernel/sched/core.c`、`kernel/sched/sched.h`、`include/linux/sched.h` 源码

---

## 一、整体架构概览

Linux 调度器采用**模块化设计**，通过 `sched_class` 抽象层将调度策略与核心逻辑解耦：

```
┌─────────────────────────────────────────────────────────────┐
│                     核心调度器 (core.c)                       │
│  __schedule() → pick_next_task() → context_switch()          │
└─────────────┬───────────────────────────────────────────────┘
              │ 通过 sched_class 虚函数表调用
              ▼
┌─────────┬──────────┬──────────┬──────────┬──────────┐
│  stop   │    dl    │    rt    │   fair   │   idle   │
│ (最高)   │ (deadline)│(realtime)│  (CFS)   │  (最低)  │
└─────────┴──────────┴──────────┴──────────┴──────────┘
     ↑ 优先级从高到低遍历（地址从低到高）
```

**调度类优先级顺序（从高到低）：**

```
stop > dl > rt > fair > idle
```

内核遍历时从最高优先级的 `stop_sched_class` 开始，依次调用每个类的 `pick_task()`，第一个返回非 NULL 的就是下一个要运行的任务。

---

## 二、核心数据结构关系图

```
                    Per-CPU
                 ┌──────────┐
                 │  struct   │
                 │    rq     │  ← 每个 CPU 一个运行队列
                 └────┬─────┘
                      │
         ┌────────────┼────────────┬──────────────┐
         │            │            │              │
    ┌────▼────┐  ┌────▼────┐  ┌───▼────┐   ┌────▼────┐
    │ cfs_rq  │  │  rt_rq  │  │ dl_rq  │   │ scx_rq  │
    │(红黑树)  │  │(优先级   │  │(红黑树  │   │(BPF调度)│
    │         │  │ 位图+链表)│  │按deadline)│   │         │
    └────┬────┘  └────┬────┘  └───┬────┘   └─────────┘
         │            │            │
    ┌────▼────┐  ┌────▼─────┐ ┌───▼──────────┐
    │sched_   │  │sched_rt_ │ │sched_dl_     │
    │entity   │  │entity    │ │entity        │
    │(se)     │  │(rt)      │ │(dl)          │
    └────┬────┘  └────┬─────┘ └───┬──────────┘
         │            │            │
         └────────────┼────────────┘
                      │
                 ┌────▼─────┐
                 │task_struct│  ← 每个进程/线程一个
                 │  .se      │
                 │  .rt      │
                 │  .dl      │
                 │  .sched_class │
                 └──────────┘
```

---

## 三、task_struct 中的调度相关字段

```c
// include/linux/sched.h:820
struct task_struct {
    unsigned int            __state;        // 进程状态 (TASK_RUNNING, etc.)

    int                     on_cpu;         // 是否正在某个 CPU 上执行
    int                     on_rq;          // 是否在运行队列上
    int                     wake_cpu;       // 唤醒目标 CPU

    int                     prio;           // 动态优先级 (考虑 PI 提升后的)
    int                     static_prio;    // 静态优先级 (用户设置的 nice 值映射)
    int                     normal_prio;    // 归一化优先级
    unsigned int            rt_priority;    // RT 优先级 (0~99)

    struct sched_entity     se;             // CFS 调度实体
    struct sched_rt_entity  rt;             // RT 调度实体
    struct sched_dl_entity  dl;             // Deadline 调度实体

    const struct sched_class *sched_class;  // 指向所属调度类

    unsigned int            policy;         // 调度策略 (SCHED_NORMAL/FIFO/RR/DEADLINE)
};
```

### 进程状态 `__state`

```
TASK_RUNNING (0)      : 可运行/正在运行
TASK_INTERRUPTIBLE (1): 可被信号唤醒的睡眠
TASK_UNINTERRUPTIBLE (2): 不可中断睡眠 (D 状态)
__TASK_STOPPED (4)    : 被 SIGSTOP 停止
__TASK_TRACED (8)     : 被 ptrace 跟踪
```

### 优先级体系

```
             ┌─────────────────────────────────────────────┐
             │            prio 值范围: 0 ~ 139              │
             ├──────────────────┬──────────────────────────┤
             │  0 ~ 99         │    100 ~ 139              │
             │  RT/DL 优先级    │    CFS 优先级             │
             │  (值越小优先级越高) │   (nice -20~+19 映射)     │
             └──────────────────┴──────────────────────────┘

static_prio = MAX_RT_PRIO + nice + 20 = 100 + nice + 20
            nice = -20 → static_prio = 100
            nice = 0   → static_prio = 120
            nice = +19 → static_prio = 139
```

---

## 四、struct rq —— 运行队列（Per-CPU）

```c
// kernel/sched/sched.h:1131
struct rq {
    unsigned int        nr_running;     // 当前 CPU 上所有可运行任务数

    unsigned long       cpu_capacity;   // CPU 容量 (用于负载均衡)

    /* 当前执行/调度上下文 */
    struct task_struct __rcu *donor;     // 调度上下文 (决定选谁运行)
    struct task_struct __rcu *curr;      // 执行上下文 (正在 CPU 上跑的)
    struct task_struct  *idle;          // 该 CPU 的 idle 线程

    /* 各调度类的子运行队列 */
    struct cfs_rq       cfs;           // CFS 运行队列
    struct rt_rq        rt;            // RT 运行队列
    struct dl_rq        dl;            // Deadline 运行队列

    /* 时钟 */
    u64                 clock_task;     // 任务时钟 (排除中断时间)
    u64                 clock_pelt;     // PELT 专用时钟
    u64                 clock;          // rq 时钟

    /* 调度域 & 负载均衡 */
    struct root_domain  *rd;           // 根域 (包含 PD 链表等)
    struct sched_domain __rcu *sd;     // 调度域层级

    /* 主动均衡 */
    unsigned long       misfit_task_load;  // misfit 任务的负载
    int                 active_balance;    // 是否正在做主动均衡
    int                 push_cpu;          // 主动均衡目标 CPU
    int                 cpu;               // 本 rq 所属 CPU 编号

    raw_spinlock_t      __lock;            // rq 锁 (热路径)
};
```

**为什么 donor 和 curr 要分开？**

这是 `CONFIG_SCHED_PROXY_EXEC`（代理执行）的设计。当任务 A 持有 mutex 阻塞了高优先级任务 B 时：
- `donor = B`（调度决策基于 B 的优先级）
- `curr = A`（实际执行的是 A，让它尽快释放锁）

非 proxy-exec 配置下，两者是同一个指针（union）。

---

## 五、struct cfs_rq —— CFS 运行队列

```c
// kernel/sched/sched.h:678
struct cfs_rq {
    struct load_weight  load;               // 队列总权重
    unsigned int        nr_queued;          // 排队的实体数
    unsigned int        h_nr_queued;        // 层级排队数 (含子组)
    unsigned int        h_nr_runnable;      // 层级可运行数

    /* EEVDF 虚拟时间管理 */
    s64                 sum_w_vruntime;     // Σ(weight × vruntime)
    u64                 sum_weight;         // Σ(weight)
    u64                 zero_vruntime;      // 虚拟时间零点 (用于比较)

    /* 红黑树 —— 核心数据结构 */
    struct rb_root_cached tasks_timeline;   // 按 deadline 排序的红黑树

    struct sched_entity *curr;              // 当前正在运行的调度实体
    struct sched_entity *next;              // 下一个将要运行的 (hint)

    /* PELT 负载追踪 */
    struct sched_avg    avg;                // 队列级别的平均负载
};
```

### 红黑树组织方式 (EEVDF)

当前 mainline 使用 **EEVDF (Earliest Eligible Virtual Deadline First)** 算法，任务按 `deadline` 排序在红黑树中：

```
               rb_root_cached
              /              \
       (deadline小)        (deadline大)
          /    \              /    \
        ...    ...          ...    ...

leftmost_cached → deadline 最小的节点 = 下一个要运行的
```

每个 `sched_entity` 的 `deadline = vruntime + slice/weight`，相当于"最迟必须开始运行的虚拟时间"。

---

## 六、struct sched_entity —— CFS 调度实体

```c
// include/linux/sched.h:575
struct sched_entity {
    struct load_weight      load;           // 权重 (由 nice 值决定)
    struct rb_node          run_node;       // 红黑树节点

    /* EEVDF 核心字段 */
    u64                     deadline;       // 虚拟截止时间
    u64                     min_vruntime;   // 最小 vruntime
    u64                     min_slice;      // 最小时间片
    u64                     max_slice;      // 最大时间片

    unsigned char           on_rq;          // 是否在运行队列
    unsigned char           sched_delayed;  // 延迟出队标记
    unsigned char           rel_deadline;   // 相对 deadline
    unsigned char           custom_slice;   // 用户自定义 slice

    /* 执行时间追踪 */
    u64                     exec_start;     // 本次开始执行的时间戳
    u64                     sum_exec_runtime;      // 累计实际执行时间
    u64                     prev_sum_exec_runtime; // 上次调度时的累计时间
    u64                     vruntime;       // 虚拟运行时间
    s64                     vlag;           // 近似虚拟延迟 (lag)
    u64                     slice;          // 当前分配的时间片

    /* PELT 负载追踪 */
    struct sched_avg        avg;            // 实体级别的负载/利用率

    /* 组调度支持 */
    struct sched_entity     *parent;        // 父实体 (cgroup 层级)
    struct cfs_rq           *cfs_rq;        // 所在的 cfs_rq
    struct cfs_rq           *my_q;          // 拥有的 cfs_rq (组调度)
};
```

### load_weight 与 nice 值的关系

```c
struct load_weight {
    unsigned long   weight;      // 权重值
    u32             inv_weight;  // weight 的倒数 (用于快速除法)
};
```

权重表 (部分)：

```
nice  weight      说明
-20   88761       最高优先级 CFS 任务
 -1    1277
  0    1024       基准权重 (NICE_0_LOAD)
  1     820
 19       15      最低优先级 CFS 任务
```

**相邻 nice 值的权重比约为 1.25:1**，即 nice 差 1，CPU 份额差约 10%。

---

## 七、struct rt_rq —— RT 运行队列

```c
// kernel/sched/sched.h:838
struct rt_rq {
    struct rt_prio_array    active;         // 优先级位图 + 链表数组
    unsigned int            rt_nr_running;  // RT 可运行任务数
    unsigned int            rr_nr_running;  // RR 策略任务数

    struct {
        int     curr;   // 当前最高优先级
        int     next;   // 次高优先级
    } highest_prio;

    bool                    overloaded;     // 是否有可推送任务
    struct plist_head       pushable_tasks; // 可推送到其他 CPU 的任务

    /* RT 带宽限制 */
    int                     rt_throttled;   // 是否被节流
    u64                     rt_time;        // 已消耗 RT 时间
    u64                     rt_runtime;     // 分配的 RT 时间配额
};
```

### RT 优先级数组

```c
struct rt_prio_array {
    DECLARE_BITMAP(bitmap, MAX_RT_PRIO + 1);  // 100 个 bit
    struct list_head queue[MAX_RT_PRIO];       // 100 个链表
};
```

```
bitmap:  [1][0][1][0][0]...[1][0]
          ↓       ↓             ↓
queue[0]: task_A → task_B       (优先级 0, 最高)
queue[2]: task_C                (优先级 2)
queue[97]: task_D               (优先级 97)

选择下一个任务: find_first_bit(bitmap) → O(1)
```

---

## 八、struct sched_class —— 调度类虚函数表

```c
// kernel/sched/sched.h:2519
struct sched_class {
    /* 入队/出队 */
    void (*enqueue_task)(struct rq *rq, struct task_struct *p, int flags);
    bool (*dequeue_task)(struct rq *rq, struct task_struct *p, int flags);

    /* 让出 CPU */
    void (*yield_task)(struct rq *rq);

    /* 抢占检查：新唤醒的任务是否应该抢占当前任务 */
    void (*wakeup_preempt)(struct rq *rq, struct task_struct *p, int flags);

    /* 负载均衡 */
    int (*balance)(struct rq *rq, struct task_struct *prev, struct rq_flags *rf);

    /* 选择下一个任务 */
    struct task_struct *(*pick_task)(struct rq *rq, struct rq_flags *rf);
    struct task_struct *(*pick_next_task)(struct rq *rq, struct task_struct *prev,
                                          struct rq_flags *rf);

    /* 切换时的处理 */
    void (*put_prev_task)(struct rq *rq, struct task_struct *p,
                          struct task_struct *next);
    void (*set_next_task)(struct rq *rq, struct task_struct *p, bool first);

    /* 选择 CPU (唤醒/fork/exec 时) */
    int (*select_task_rq)(struct task_struct *p, int task_cpu, int flags);

    /* 时钟 tick */
    void (*task_tick)(struct rq *rq, struct task_struct *p, int queued);

    /* 任务创建 */
    void (*task_fork)(struct task_struct *p);
};
```

### 调度类优先级通过 linker section 实现

```c
// kernel/sched/sched.h:2734
extern struct sched_class __sched_class_highest[];
extern struct sched_class __sched_class_lowest[];
```

各调度类通过 `DEFINE_SCHED_CLASS(name)` 宏放入特殊 linker section，链接器按地址排序：

```
地址低 ─────────────────────────────────────── 地址高
 stop_sched_class  dl  rt  [ext]  fair  idle_sched_class
   ↑ highest                                ↑ lowest
```

遍历宏：

```c
#define for_each_active_class(class)
    for (class = __sched_class_highest;
         class != __sched_class_lowest;
         class = next_active_class(class))
```

**地址越低优先级越高**，`sched_class_above(a, b)` 就是 `a < b`（地址比较）。

---

## 九、PELT 负载追踪

```c
// include/linux/sched.h:510
struct sched_avg {
    u64             last_update_time;   // 上次更新时间
    u64             load_sum;           // 负载累加和
    u64             runnable_sum;       // 可运行累加和
    u32             util_sum;           // 利用率累加和
    u32             period_contrib;     // 当前周期贡献

    unsigned long   load_avg;           // 负载平均值
    unsigned long   runnable_avg;       // 可运行平均值
    unsigned long   util_avg;           // 利用率平均值（最关键！）
    unsigned int    util_est;           // 利用率估计值
};
```

### 三个指标的含义

```
load_avg     = runnable% × weight     (带权重的可运行时间比例)
runnable_avg = runnable% × 1024       (在 rq 上的时间比例)
util_avg     = running%  × 1024       (实际在 CPU 上执行的时间比例)
```

**区别关键：**
- `runnable` 包括等待 CPU 的时间（在 rq 上排队）
- `running` 只算真正占用 CPU 的时间

```
时间线:  |--排队--|--运行--|--排队--|--运行--|--睡眠--|
         ├── runnable ──────────────────────┤
                   ├─ running ─┤      ├─run─┤
```

### PELT 衰减公式

```
avg = Σ (contribution_i × y^i)

其中 y = (2^32 - 1) / 2^32 ≈ 0.978 (每个周期衰减约 2.2%)
周期 = 1024 μs ≈ 1ms

半衰期 ≈ 32ms (经过 32 个周期后信号衰减到一半)
```

---

## 十、__schedule() —— 调度核心函数

这是 Linux 调度器的心脏，所有调度切换都通过此函数。

```c
// kernel/sched/core.c:7017
static void __sched notrace __schedule(int sched_mode)
{
    struct task_struct *prev, *next;
    bool preempt = sched_mode > SM_NONE;
    struct rq_flags rf;
    struct rq *rq;
    int cpu;

    cpu = smp_processor_id();
    rq = cpu_rq(cpu);              // 获取当前 CPU 的 rq
    prev = rq->curr;               // 当前正在运行的任务
```

### sched_mode 含义

| 值 | 含义 | 触发场景 |
|----|------|----------|
| `SM_NONE` | 主动调度 | `schedule()`，任务主动让出 CPU |
| `SM_PREEMPT` | 抢占调度 | 从中断/系统调用返回时检测到 TIF_NEED_RESCHED |
| `SM_IDLE` | idle 调度 | idle 任务检测到有新任务 |

### 完整流程

```c
    local_irq_disable();                    // 1. 关中断
    rq_lock(rq, &rf);                       // 2. 加 rq 锁
    smp_mb__after_spinlock();               // 3. 内存屏障

    update_rq_clock(rq);                    // 4. 更新 rq 时钟

    // 5. 处理主动睡眠 (非抢占场景)
    if (!preempt && prev_state) {
        try_to_block_task(rq, prev, ...);   // 将任务从 rq 移除
    }

    // 6. 选择下一个任务
    next = pick_next_task(rq, rq->donor, &rf);

    // 7. 如果选出的不是当前任务 → 切换
    if (prev != next) {
        rq->nr_switches++;
        RCU_INIT_POINTER(rq->curr, next);   // 更新 rq->curr

        // 8. 执行上下文切换
        rq = context_switch(rq, prev, next, &rf);
    } else {
        // 没有切换，解锁返回
        rq_unlock_irq(rq, &rf);
    }
}
```

### 流程图

```
__schedule(sched_mode)
    │
    ├── 1. 关中断 + 加 rq 锁
    │
    ├── 2. 更新 rq 时钟
    │
    ├── 3. 当前任务需要睡眠？
    │       │ Yes (非抢占 && state != RUNNING)
    │       └── try_to_block_task() → dequeue_task()
    │
    ├── 4. pick_next_task() → 选出 next
    │       │
    │       ├── 快速路径: 只有 CFS 任务
    │       │   └── pick_next_task_fair()
    │       │
    │       └── 慢速路径: 按优先级遍历所有调度类
    │           for_each_active_class:
    │             stop → dl → rt → fair → idle
    │
    ├── 5. prev == next？
    │       │ Yes → 解锁返回 (不需要切换)
    │       │ No  ↓
    │
    └── 6. context_switch(prev, next)
            ├── switch_mm() ← 切换页表 (地址空间)
            └── switch_to() ← 切换寄存器/栈 (执行流)
```

---

## 十一、pick_next_task() —— 选择下一个运行的任务

```c
// kernel/sched/core.c:5999
__pick_next_task(struct rq *rq, struct task_struct *prev, struct rq_flags *rf)
{
    const struct sched_class *class;
    struct task_struct *p;

    /*
     * 优化：如果所有任务都是 CFS 的，且 prev 不是更高优先级调度类，
     * 直接调用 CFS 的 pick_next_task，跳过遍历。
     */
    if (likely(!sched_class_above(prev->sched_class, &fair_sched_class) &&
               rq->nr_running == rq->cfs.h_nr_queued)) {

        p = pick_next_task_fair(rq, prev, rf);
        if (unlikely(p == RETRY_TASK))
            goto restart;

        if (!p) {
            p = pick_task_idle(rq, rf);     // 没有 CFS 任务，选 idle
            put_prev_set_next_task(rq, prev, p);
        }
        return p;
    }

restart:
    /* 慢速路径：按优先级从高到低遍历 */
    for_each_active_class(class) {
        if (class->pick_next_task) {
            p = class->pick_next_task(rq, prev, rf);
        } else {
            p = class->pick_task(rq, rf);
            if (p)
                put_prev_set_next_task(rq, prev, p);
        }
        if (p)
            return p;
    }

    BUG(); // idle 类必须返回任务，永远不会到这里
}
```

**为什么有快速路径？**

绝大多数场景下系统只有 CFS 任务在跑（普通用户态进程都是 `SCHED_NORMAL`）。快速路径直接跳过 stop/dl/rt 的遍历，减少一次条件判断的开销。条件 `rq->nr_running == rq->cfs.h_nr_queued` 确保没有 RT/DL 任务存在。

---

## 十二、try_to_wake_up() —— 唤醒路径

当一个睡眠的任务被唤醒时（信号、IO 完成、mutex 释放等），走这个路径：

```c
// kernel/sched/core.c:4152
int try_to_wake_up(struct task_struct *p, unsigned int state, int wake_flags)
{
    // 1. 检查任务状态是否匹配
    if (!ttwu_state_match(p, state, &success))
        return 0;

    // 2. 如果任务还在 rq 上 (sched_delayed)，直接唤醒
    if (READ_ONCE(p->on_rq) && ttwu_runnable(p, wake_flags))
        return 1;

    // 3. 等待任务完成上一次的 schedule()
    smp_cond_load_acquire(&p->on_cpu, !VAL);

    // 4. 选择目标 CPU
    cpu = select_task_rq(p, p->wake_cpu, &wake_flags);

    // 5. 如果目标 CPU 不同于当前 CPU → 迁移
    if (task_cpu(p) != cpu) {
        wake_flags |= WF_MIGRATED;
        set_task_cpu(p, cpu);
    }

    // 6. 将任务入队到目标 CPU 的 rq
    ttwu_queue(p, cpu, wake_flags);
}
```

### 唤醒流程图

```
try_to_wake_up(p)
    │
    ├── p->pi_lock 加锁
    │
    ├── 状态检查: p->__state & state ?
    │   No → return 0 (任务状态不匹配)
    │
    ├── p->on_rq? (任务还在队列上，如 sched_delayed)
    │   Yes → ttwu_runnable() → 直接标记可运行
    │
    ├── 等待 p->on_cpu == 0 (确保 prev schedule 完成)
    │
    ├── select_task_rq() → 选择最优 CPU
    │   ├── EAS 路径: find_energy_efficient_cpu()
    │   ├── 快速路径: select_idle_sibling()
    │   └── 慢速路径: find_idlest_cpu()
    │
    ├── set_task_cpu(p, cpu) (如需迁移)
    │
    └── ttwu_queue(p, cpu)
        └── ttwu_do_activate()
            ├── activate_task() → enqueue_task()
            └── wakeup_preempt() → 检查是否需要抢占当前任务
                └── resched_curr() → 设 TIF_NEED_RESCHED
```

---

## 十三、context_switch() —— 上下文切换

```c
// kernel/sched/core.c:5329
static struct rq *
context_switch(struct rq *rq, struct task_struct *prev,
               struct task_struct *next, struct rq_flags *rf)
{
    prepare_task_switch(rq, prev, next);

    /*
     * 切换地址空间 (mm_struct)
     * 四种情况:
     *   kernel → kernel: lazy TLB, 不切换页表
     *   user   → kernel: lazy TLB + mmgrab
     *   kernel → user  : 切换页表 (switch_mm)
     *   user   → user  : 切换页表 (switch_mm)
     */
    if (!next->mm) {                    // 切换到内核线程
        enter_lazy_tlb(prev->active_mm, next);
        next->active_mm = prev->active_mm;
    } else {                            // 切换到用户进程
        switch_mm_irqs_off(prev->active_mm, next->mm, next);
    }

    /* 切换寄存器状态和内核栈 */
    switch_to(prev, next, prev);        // 这里 CPU 就跑到 next 了！
    barrier();

    return finish_task_switch(prev);    // next 视角: prev 已经切走了
}
```

### switch_to() 的魔法

`switch_to(prev, next, last)` 是架构相关的宏/函数。在 ARM64 上：

```
switch_to(A, B, last):
  1. 保存 A 的 callee-saved 寄存器到 A 的 task_struct->thread
  2. 切换内核栈指针 sp 到 B 的内核栈
  3. 恢复 B 的 callee-saved 寄存器
  4. ret → B 从它上次 switch_to 的返回点继续执行
```

**关键理解：** `switch_to()` 之后的代码，是由 **next** 执行的（从它上次被切走的地方恢复），而不是 prev。

```
时间线:
         A 执行                              B 执行
           │                                   │
           │ switch_to(A, B, last)             │
           │ ─── 保存 A 寄存器 ────→           │
           │ ─── 切换到 B 的栈 ────→           │
           │                          ← 恢复 B 寄存器 ──
           │                          ← B 继续执行 ──────
           │ (A 被挂起，直到将来某次            │
           │  有人 switch_to(X, A, last))       │
```

---

## 十四、enqueue_task / dequeue_task —— 入队与出队

```c
// kernel/sched/core.c:2153
void enqueue_task(struct rq *rq, struct task_struct *p, int flags)
{
    if (!(flags & ENQUEUE_NOCLOCK))
        update_rq_clock(rq);

    uclamp_rq_inc(rq, p, flags);           // 更新 uclamp 聚合值

    p->sched_class->enqueue_task(rq, p, flags);  // 调用调度类的实现

    psi_enqueue(p, flags);                 // PSI 压力统计
}

bool dequeue_task(struct rq *rq, struct task_struct *p, int flags)
{
    uclamp_rq_dec(rq, p);                  // 更新 uclamp

    return p->sched_class->dequeue_task(rq, p, flags);
}
```

**enqueue_flags 常用标志：**

| Flag | 含义 |
|------|------|
| `ENQUEUE_WAKEUP` | 任务从睡眠中唤醒 |
| `ENQUEUE_MIGRATED` | 任务从其他 CPU 迁移过来 |
| `ENQUEUE_RESTORE` | 恢复（如从 throttle 恢复） |
| `ENQUEUE_NOCLOCK` | 不更新 rq 时钟（调用者已更新） |

---

## 十五、resched_curr() —— 触发重新调度

```c
// kernel/sched/core.c:1170
static void __resched_curr(struct rq *rq, int tif)
{
    struct task_struct *curr = rq->curr;

    // idle 任务总是立即抢占
    if (is_idle_task(curr) && tif == TIF_NEED_RESCHED_LAZY)
        tif = TIF_NEED_RESCHED;

    // 已经设置过了，不重复设置
    if (cti->flags & ((1 << tif) | _TIF_NEED_RESCHED))
        return;

    if (cpu == smp_processor_id()) {
        // 本地 CPU：直接设置标志
        set_ti_thread_flag(cti, tif);
    } else {
        // 远程 CPU：设置标志 + 发送 IPI 中断
        if (set_nr_and_not_polling(cti, tif)) {
            smp_send_reschedule(cpu);   // 发 IPI
        }
    }
}
```

**TIF_NEED_RESCHED vs TIF_NEED_RESCHED_LAZY：**

| 标志 | 含义 | 何时检查 |
|------|------|----------|
| `TIF_NEED_RESCHED` | 立即抢占 | 中断返回、系统调用返回、preempt_enable() |
| `TIF_NEED_RESCHED_LAZY` | 延迟抢占 | 只在用户态返回点检查 (PREEMPT_DYNAMIC) |

---

## 十六、调度触发时机总结

```
┌─────────────────────────────────────────────────────────────┐
│                   设置 TIF_NEED_RESCHED                      │
├─────────────────────────────────────────────────────────────┤
│ 1. wakeup_preempt()  : 唤醒的任务优先级更高                   │
│ 2. task_tick()       : 时间片耗尽 (CFS slice/RT time_slice)  │
│ 3. sched_setscheduler(): 优先级改变                          │
│ 4. yield()           : 任务主动让出                           │
│ 5. 负载均衡          : pull/push 任务后发现需要切换            │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                   检查 & 执行 schedule()                     │
├─────────────────────────────────────────────────────────────┤
│ 1. 中断返回用户态    : ret_to_user → do_notify_resume        │
│ 2. 中断返回内核态    : preempt_schedule_irq() [PREEMPT=y]    │
│ 3. preempt_enable()  : __preempt_schedule() [PREEMPT=y]      │
│ 4. 系统调用返回      : syscall_exit_to_user_mode             │
│ 5. 主动调用          : schedule(), cond_resched()            │
│ 6. 阻塞操作          : mutex_lock(), wait_event(), sleep()   │
└─────────────────────────────────────────────────────────────┘
```

---

## 十七、完整调度生命周期示例

假设任务 A 正在运行，任务 B 被唤醒且优先级更高：

```
CPU0 上正在运行任务 A
         │
         │  ← 某个 CPU 上执行 wake_up(B)
         │
         ▼
try_to_wake_up(B)
    │
    ├── select_task_rq(B) → 选择 CPU0
    ├── enqueue_task(rq0, B)
    │       └── B 加入 rq0 的红黑树/优先级队列
    └── wakeup_preempt(rq0, B)
            └── B 优先级 > A → resched_curr(rq0)
                    └── 设置 A 的 TIF_NEED_RESCHED
                        (如果是远程 CPU，发 IPI)
         │
         ▼
中断返回 / preempt_enable() 检查点
    │  发现 TIF_NEED_RESCHED 被设置
    ▼
__schedule(SM_PREEMPT)
    │
    ├── prev = A (当前)
    ├── pick_next_task() → next = B (更高优先级)
    ├── context_switch(A, B)
    │       ├── switch_mm(): 切换到 B 的地址空间
    │       └── switch_to(): 切换到 B 的内核栈和寄存器
    │
    └── B 开始在 CPU0 上执行！
        A 被挂起，等待下次被选中。
```

---

## 十八、关键设计思想总结

| 设计 | 原因 |
|------|------|
| Per-CPU rq + rq 锁 | 减少锁竞争，热路径只需本地锁 |
| sched_class 虚函数表 | 解耦策略与机制，可扩展（ext/BPF） |
| 按优先级遍历调度类 | 确保高优先级任务总是先被选中 |
| PELT 指数衰减 | 平滑负载信号，避免瞬时抖动 |
| TIF_NEED_RESCHED 标记 | 延迟决策：设置标记时不切换，到安全点再切 |
| rq->donor vs rq->curr | 支持优先级继承 (proxy exec) |
| 红黑树 (CFS/DL) | O(log n) 插入/删除，O(1) 取最左节点 |
| 位图+链表 (RT) | O(1) 选择最高优先级任务 |
| context_switch 中 lazy TLB | 内核线程不需要自己的页表，借用前一个 |

---

## 参考

- `kernel/sched/core.c` — 调度核心 (`__schedule`, `try_to_wake_up`, `context_switch`)
- `kernel/sched/sched.h` — 核心数据结构 (`rq`, `cfs_rq`, `rt_rq`, `sched_class`)
- `include/linux/sched.h` — `task_struct`, `sched_entity`, `sched_avg`
- `kernel/sched/fair.c` — CFS/EEVDF 实现
- `kernel/sched/rt.c` — RT 调度实现
- `kernel/sched/pelt.c` — PELT 负载追踪
