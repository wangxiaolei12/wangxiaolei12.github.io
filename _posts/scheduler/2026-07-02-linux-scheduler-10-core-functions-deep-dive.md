---
layout: post
title: "Linux 进程调度（十）：core.c 核心函数深度解析"
date: 2026-07-02 10:00:00 +0800
excerpt: "深入剖析 kernel/sched/core.c 中调度器的核心辅助函数：CPU Hotplug、任务迁移机制、CPU Stopper、调度策略切换、优先级调整、migrate_disable 以及 rq 锁机制。这些函数构成了调度器完整功能的基石。"
---

# Linux 进程调度（十）：core.c 核心函数深度解析

基于 mainline `kernel/sched/core.c` 源码分析，聚焦调度器辅助功能

---

## 一、引言

`kernel/sched/core.c` 不仅包含 `__schedule()` 和 `context_switch()` 这样的核心调度函数，还包含大量支撑调度器完整功能的辅助函数。这些函数处理：

- **CPU Hotplug**：CPU 上线/下线时的调度器处理
- **任务迁移**：跨 CPU 移动任务
- **调度策略切换**：`sched_setscheduler()` 系统调用
- **优先级调整**：`set_user_nice()`
- **迁移禁用**：`migrate_disable()` 机制
- **锁机制**：rq 锁和 pi_lock 的复杂交互

本文将深入分析这些核心辅助函数。

---

## 二、CPU Hotplug —— sched_cpu_activate/deactivate

### 2.1 sched_cpu_activate() —— CPU 上线

```c
// kernel/sched/core.c:8661
int sched_cpu_activate(unsigned int cpu)
{
    struct rq *rq = cpu_rq(cpu);

    balance_push_set(cpu, false);        // 禁用 push 回调

    sched_smt_present_inc(cpu);          // 更新 SMT 状态
    set_cpu_active(cpu, true);           // 标记 CPU 活跃

    if (sched_smp_initialized) {
        sched_update_numa(cpu, true);          // 更新 NUMA 信息
        sched_domains_numa_masks_set(cpu);     // 设置 NUMA 掩码
        cpuset_cpu_active();                   // 通知 cpuset 子系统
    }

    scx_rq_activate(rq);                 // BPF 调度类激活

    sched_set_rq_online(rq, cpu);        // 将 rq 标记为 online

    return 0;
}
```

**执行步骤：**

| 步骤 | 函数 | 作用 |
|------|------|------|
| 1 | `balance_push_set(cpu, false)` | 禁用 balance_push 回调，允许正常调度 |
| 2 | `sched_smt_present_inc(cpu)` | 如果是 SMT 系统，增加 SMT 计数 |
| 3 | `set_cpu_active(cpu, true)` | 将 CPU 加入 cpu_active_mask |
| 4 | `sched_update_numa()` | 更新 NUMA 调度信息 |
| 5 | `sched_domains_numa_masks_set()` | 设置 NUMA 调度域掩码 |
| 6 | `cpuset_cpu_active()` | 通知 cpuset 子系统 CPU 状态变化 |
| 7 | `scx_rq_activate()` | 激活 BPF 调度类（如果启用） |
| 8 | `sched_set_rq_online()` | 将 rq 标记为 online，允许任务调度 |

### 2.2 sched_cpu_deactivate() —— CPU 下线

```c
// kernel/sched/core.c:8699
int sched_cpu_deactivate(unsigned int cpu)
{
    struct rq *rq = cpu_rq(cpu);
    int ret;

    ret = dl_bw_deactivate(cpu);         // 首先处理 Deadline 带宽
    if (ret)
        return ret;

    nohz_balance_exit_idle(rq);          // 退出 nohz idle 模式

    set_cpu_active(cpu, false);          // 标记 CPU 非活跃

    balance_push_set(cpu, true);         // 启用 push 回调

    synchronize_rcu();                   // 等待 RCU 读取器完成

    sched_domains_free_llc_id(cpu);      // 释放 LLC ID

    sched_set_rq_offline(rq, cpu);       // 将 rq 标记为 offline
    ...
}
```

**关键设计：**

1. **Deadline 带宽优先处理**：DL 任务有严格的带宽限制，必须先确保它们被迁移到其他 CPU
2. **balance_push_set(cpu, true)**：启用 push 回调后，该 CPU 会主动将任务推送到其他 CPU
3. **synchronize_rcu()**：确保所有使用 `cpu_active_mask` 的读操作完成，防止新任务被调度到该 CPU

**CPU 下线时的任务迁移流程：**

```
CPU0 准备下线
    │
    ├── sched_cpu_deactivate(0)
    │       ├── dl_bw_deactivate(0) → DL 任务迁移
    │       ├── set_cpu_active(0, false)
    │       └── balance_push_set(0, true)
    │
    ├── 其他 CPU 检测到 CPU0 不可用
    │       └── pull 任务从 CPU0
    │
    └── CPU0 的 balance_push 回调
            └── push 任务到其他 CPU
```

---

## 三、任务迁移机制

### 3.1 move_queued_task() —— 移动队列中的任务

```c
// kernel/sched/core.c:2546
static struct rq *move_queued_task(struct rq *rq, struct rq_flags *rf,
                                   struct task_struct *p, int new_cpu)
    __must_hold(__rq_lockp(rq))
{
    deactivate_task(rq, p, DEQUEUE_NOCLOCK);  // 从旧 rq 出队
    set_task_cpu(p, new_cpu);                  // 更新 p->cpu
    rq_unlock(rq, rf);                         // 释放旧 rq 锁

    rq = cpu_rq(new_cpu);                      // 获取新 rq
    rq_lock(rq, rf);                           // 获取新 rq 锁

    activate_task(rq, p, ENQUEUE_NOCLOCK);     // 入队到新 rq
    ...
    return rq;
}
```

**为什么只持有一个 rq 锁？**

传统迁移需要同时持有两个 rq 锁，但这会导致：
- 死锁风险（CPU0 持有 rq0 锁，等待 rq1 锁；CPU1 持有 rq1 锁，等待 rq0 锁）
- 性能问题（锁竞争激烈）

`move_queued_task()` 通过以下方式避免：
1. 先从旧 rq 出队，释放旧锁
2. 获取新 rq 锁，入队到新 rq

**状态转换：**

```
p->on_rq = TASK_ON_RQ_QUEUED
       │
       ▼ deactivate_task()
p->on_rq = TASK_ON_RQ_MIGRATING
       │
       ▼ set_task_cpu()
p->cpu = new_cpu
       │
       ▼ activate_task()
p->on_rq = TASK_ON_RQ_QUEUED (on new rq)
```

### 3.2 set_cpus_allowed_ptr() —— 设置 CPU 亲和性

```c
// kernel/sched/core.c:2887
void set_cpus_allowed_ptr(struct task_struct *p, const struct cpumask *new_mask)
{
    __set_cpus_allowed_ptr(p, new_mask, false);
}
```

**核心逻辑：**

```c
static int __set_cpus_allowed_ptr(struct task_struct *p,
                                  const struct cpumask *new_mask, bool check)
{
    // 1. 检查新 mask 是否有效
    if (check && cpumask_empty(new_mask))
        return -EINVAL;

    // 2. 如果任务正在运行且不在新 mask 中，需要踢走
    if (task_on_cpu(p) && !cpumask_test_cpu(task_cpu(p), new_mask)) {
        // 调用 CPU stopper 踢走任务
        stop_one_cpu(task_cpu(p), migration_cpu_stop, p);
    }

    // 3. 更新 cpumask
    p->cpus_ptr = new_mask;
    p->nr_cpus_allowed = cpumask_weight(new_mask);

    // 4. 如果任务在等待迁移，唤醒等待者
    if (p->migration_pending) {
        complete_all(&p->migration_pending->done);
    }

    return 0;
}
```

### 3.3 migration_cpu_stop() —— CPU Stopper 执行迁移

```c
// kernel/sched/core.c:2611
static int migration_cpu_stop(void *data)
{
    struct task_struct *p = data;
    struct rq_flags rf;
    struct rq *rq;
    int dest_cpu;

    rq = task_rq_lock(p, &rf);

    // 选择目标 CPU
    dest_cpu = select_fallback_rq(task_cpu(p), p);

    if (dest_cpu >= 0) {
        // 执行迁移
        rq = move_queued_task(rq, &rf, p, dest_cpu);
    }

    task_rq_unlock(rq, p, &rf);
    return 0;
}
```

**CPU Stopper 是什么？**

每个 CPU 有一个高优先级的 stopper 线程（`stop_sched_class`），可以抢占该 CPU 上的所有任务。当需要强制迁移一个正在运行的任务时，通过 stopper 线程执行。

---

## 四、migrate_disable —— 迁移禁用机制

### 4.1 什么是 migrate_disable？

某些临界区不允许任务被迁移到其他 CPU，例如：
- 访问 per-CPU 数据结构
- 持有硬件锁
- 执行时间敏感代码

```c
// kernel/sched/core.c:2480
void migrate_disable(void)
{
    __migrate_disable();
}

void migrate_enable(void)
{
    __migrate_enable();
}
```

### 4.2 实现原理

```c
// include/linux/sched.h
static __always_inline void __migrate_disable(void)
{
    current->migrate_disable_depth++;
    smp_mb();  // 内存屏障
}

static __always_inline void __migrate_enable(void)
{
    smp_mb();
    current->migrate_disable_depth--;

    // 如果有 pending 的迁移请求，执行迁移
    if (current->migrate_disable_depth == 0 && current->migration_pending) {
        __set_cpus_allowed_ptr(current, current->cpus_ptr);
        current->migration_pending = NULL;
    }
}
```

**migrate_disable 与 set_cpus_allowed_ptr 的交互：**

```
场景：P0 在 CPU0 上执行 migrate_disable()，P1 调用 set_cpus_allowed_ptr(P0, [1])

P0@CPU0                      P1
────────                      ────
migrate_disable();           set_cpus_allowed_ptr(P0, [1]);
   │                           │
   │                           ├── p->pi_lock 加锁
   │                           ├── 更新 p->cpus_ptr = [1]
   │                           ├── p->on_cpu == true
   │                           └── 创建 migration_pending
   │                               └── wait_for_completion() 阻塞
   │
   │  <继续执行临界区代码>
   │
migrate_enable();
   │
   ├── migrate_disable_depth == 0
   ├── migration_pending != NULL
   └── __set_cpus_allowed_ptr(current, [1])
           └── kick 本地 stopper
                   └── migration_cpu_stop()
                           └── move_queued_task(P0, CPU1)
                                   └── complete_all() → P1 被唤醒
```

---

## 五、调度策略切换 —— sched_setscheduler()

### 5.1 系统调用入口

```c
// kernel/sched/core.c
SYSCALL_DEFINE3(sched_setscheduler, pid_t, pid, int, policy,
                struct sched_param __user *, param)
{
    return __sched_setscheduler(pid, policy, param, false);
}
```

### 5.2 __sched_setscheduler() 核心逻辑

```c
static int __sched_setscheduler(struct task_struct *p, const struct sched_attr *attr,
                                bool user, bool pi)
{
    // 1. 参数验证
    if (attr->sched_policy < 0 || attr->sched_policy >= SCHED_DEADLINE)
        return -EINVAL;

    // 2. 权限检查
    if (user && !capable(CAP_SYS_NICE))
        return -EPERM;

    // 3. 获取任务锁和 rq 锁
    rq = task_rq_lock(p, &rf);

    // 4. 保存旧优先级
    old_prio = p->prio;

    // 5. 更新调度参数
    p->policy = attr->sched_policy;
    p->static_prio = NICE_TO_PRIO(attr->sched_nice);
    p->rt_priority = attr->sched_priority;

    // 6. 更新调度类
    p->sched_class = sched_class_highest;
    switch (p->policy) {
        case SCHED_NORMAL:
        case SCHED_BATCH:
        case SCHED_IDLE:
            p->sched_class = &fair_sched_class;
            break;
        case SCHED_FIFO:
        case SCHED_RR:
            p->sched_class = &rt_sched_class;
            break;
        case SCHED_DEADLINE:
            p->sched_class = &dl_sched_class;
            break;
    }

    // 7. 如果任务在运行队列上，重新入队
    if (task_on_rq_queued(p)) {
        deactivate_task(rq, p, 0);
        p->on_rq = 0;
        activate_task(rq, p, 0);
    }

    // 8. 如果新优先级更高，触发重新调度
    if (p->prio < old_prio)
        resched_curr(rq);

    // 9. 释放锁
    task_rq_unlock(rq, p, &rf);

    return 0;
}
```

**调度策略映射：**

| 策略 | 调度类 | 说明 |
|------|--------|------|
| `SCHED_NORMAL` | `fair_sched_class` | CFS 公平调度 |
| `SCHED_BATCH` | `fair_sched_class` | CFS 批量调度 |
| `SCHED_IDLE` | `fair_sched_class` | CFS 空闲调度 |
| `SCHED_FIFO` | `rt_sched_class` | 实时 FIFO |
| `SCHED_RR` | `rt_sched_class` | 实时 Round Robin |
| `SCHED_DEADLINE` | `dl_sched_class` | Deadline 调度 |

---

## 六、优先级调整 —— set_user_nice()

### 6.1 函数实现

```c
// kernel/sched/core.c
void set_user_nice(struct task_struct *p, long nice)
{
    struct rq_flags rf;
    struct rq *rq;
    int old_prio, delta;

    // 1. 验证 nice 值范围 (-20 ~ +19)
    if (nice < MIN_NICE || nice > MAX_NICE)
        return;

    // 2. 获取 rq 锁
    rq = task_rq_lock(p, &rf);

    // 3. 计算新优先级
    old_prio = p->static_prio;
    p->static_prio = NICE_TO_PRIO(nice);
    delta = p->static_prio - old_prio;

    // 4. 如果任务是 CFS 任务，更新权重
    if (task_has_dl_policy(p) || task_has_rt_policy(p))
        goto out_unlock;

    // 5. 更新调度实体的权重
    update_load_avg(cfs_rq_of(p), p->se, UPDATE_TG);
    set_load_weight(p);

    // 6. 如果优先级变化，重新计算
    if (delta) {
        p->se.vruntime += delta * NICE_0_LOAD;
        ...
    }

    // 7. 如果新优先级更高，触发重新调度
    if (p->prio < old_prio)
        resched_curr(rq);

out_unlock:
    task_rq_unlock(rq, p, &rf);
}
```

### 6.2 nice 值与权重的关系

```
nice  weight      说明
-20   88761       最高优先级
-10   26744
 -5   15795
 -1   1277
  0   1024        基准权重 (NICE_0_LOAD)
  1    820
  5    535
 10    335
 19      15       最低优先级
```

**相邻 nice 值的权重比约为 1.25:1**，即 nice 差 1，CPU 份额差约 10%。

---

## 七、rq 锁机制

### 7.1 rq 锁的获取与释放

```c
// kernel/sched/core.c:659
void raw_spin_rq_lock_nested(struct rq *rq, int subclass)
{
    preempt_disable();
    
    if (sched_core_disabled()) {
        raw_spin_lock_nested(&rq->__lock, subclass);
        preempt_enable_no_resched();
        return;
    }

    // Sched Core 启用时，需要处理 core 锁
    for (;;) {
        lock = __rq_lockp(rq);
        raw_spin_lock_nested(lock, subclass);
        if (likely(lock == __rq_lockp(rq))) {
            preempt_enable_no_resched();
            return;
        }
        raw_spin_unlock(lock);
    }
}
```

### 7.2 锁的层级关系

```
task_rq_lock(p, &rf)
    │
    ├── raw_spin_lock(&p->pi_lock)
    │       └── 保护 task_struct 的状态变化
    │
    └── raw_spin_rq_lock(rq, &rf)
            └── 保护 runqueue 的操作
```

**为什么需要 pi_lock？**

`pi_lock`（Priority Inheritance lock）用于：
1. 保护任务的状态变化（`__state`、`on_rq`、`on_cpu`）
2. 支持优先级继承（RT mutex）
3. 序列化 `set_cpus_allowed_ptr()` 和 `try_to_wake_up()`

### 7.3 锁的持有规则

| 操作 | 锁 |
|------|-----|
| `enqueue_task()` / `dequeue_task()` | `rq->__lock` |
| `try_to_wake_up()` | `p->pi_lock` |
| `set_cpus_allowed_ptr()` | `p->pi_lock` |
| `sched_setscheduler()` | `p->pi_lock` + `rq->__lock` |
| `__schedule()` | `rq->__lock` |

---

## 八、任务状态管理

### 8.1 p->on_rq 的三种状态

```c
// include/linux/sched.h
#define TASK_ON_RQ_QUEUED    1   // 任务在运行队列上
#define TASK_ON_RQ_MIGRATING 2   // 任务正在迁移中
```

**状态转换图：**

```
                    ┌─────────────────────┐
                    │   p->on_rq = 0      │  (睡眠/阻塞)
                    └──────────┬──────────┘
                               │ activate_task()
                               ▼
                    ┌─────────────────────┐
                    │   p->on_rq = 1      │  (可运行，在 rq 上)
                    │ (QUEUED)            │
                    └──────────┬──────────┘
                               │ deactivate_task()
                               ▼
                    ┌─────────────────────┐
                    │   p->on_rq = 0      │  (睡眠/阻塞)
                    └─────────────────────┘

                    ┌─────────────────────┐
                    │   p->on_rq = 1      │
                    └──────────┬──────────┘
                               │ move_queued_task()
                               ▼
                    ┌─────────────────────┐
                    │   p->on_rq = 2      │  (迁移中)
                    │ (MIGRATING)         │
                    └──────────┬──────────┘
                               │ activate_task() (on new rq)
                               ▼
                    ┌─────────────────────┐
                    │   p->on_rq = 1      │  (在新 rq 上)
                    └─────────────────────┘
```

### 8.2 p->on_cpu 的管理

```c
// 调度入时设置
void prepare_task(struct task_struct *p)
{
    p->on_cpu = 1;
}

// 调度出时清除
void finish_task(struct task_struct *p)
{
    p->on_cpu = 0;
}
```

`on_cpu` 用于：
1. `try_to_wake_up()` 等待任务完成调度
2. `set_cpus_allowed_ptr()` 检查任务是否在运行
3. RCU 调度器保护

---

## 九、核心函数关系图

```
┌─────────────────────────────────────────────────────────────────┐
│                    kernel/sched/core.c 函数关系                  │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                 │
│  │ __schedule()     │────▶│ context_switch() │                 │
│  │ (调度核心)        │     │ (上下文切换)      │                 │
│  └────────┬─────────┘     └──────────────────┘                 │
│           │                                                     │
│           ├── pick_next_task()                                  │
│           ├── try_to_block_task()                               │
│           └── resched_curr()                                    │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                 │
│  │ try_to_wake_up() │────▶│ activate_task()  │                 │
│  │ (唤醒路径)        │     │ (入队)           │                 │
│  └────────┬─────────┘     └──────────────────┘                 │
│           │                                                     │
│           ├── select_task_rq()                                  │
│           └── wakeup_preempt()                                  │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                 │
│  │ move_queued_task()│────▶│ set_task_cpu()   │                 │
│  │ (任务迁移)        │     │ (更新 CPU)       │                 │
│  └──────────────────┘     └──────────────────┘                 │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                 │
│  │ sched_cpu_activate │───▶│ sched_cpu_deactivate │            │
│  │ (CPU 上线)        │     │ (CPU 下线)        │                 │
│  └──────────────────┘     └──────────────────┘                 │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                 │
│  │ sched_setscheduler│───▶│ set_user_nice()  │                 │
│  │ (调度策略切换)     │     │ (优先级调整)     │                 │
│  └──────────────────┘     └──────────────────┘                 │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                 │
│  │ migrate_disable()│────▶│ migrate_enable() │                 │
│  │ (禁用迁移)        │     │ (启用迁移)        │                 │
│  └──────────────────┘     └──────────────────┘                 │
│                                                                 │
│  ┌──────────────────┐                                           │
│  │ raw_spin_rq_lock │───▶│ task_rq_lock()   │                  │
│  │ (rq 锁)           │     │ (pi_lock + rq锁) │                  │
│  └──────────────────┘     └──────────────────┘                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 十、关键设计思想总结

| 设计 | 原因 |
|------|------|
| Per-CPU rq + 本地锁 | 减少锁竞争，热路径只需本地锁 |
| 单锁迁移 (move_queued_task) | 避免双 rq 锁导致的死锁 |
| CPU Stopper | 强制迁移正在运行的任务 |
| migrate_disable | 保护临界区不被迁移打断 |
| pi_lock + rq 锁 | 分层锁，保护不同粒度的数据 |
| on_rq = MIGRATING | 标记迁移状态，避免并发问题 |
| balance_push (CPU 下线) | 主动推送任务到其他 CPU |

---

## 参考

- `kernel/sched/core.c` — 调度核心实现
- `kernel/sched/sched.h` — 核心数据结构定义
- `include/linux/sched.h` — task_struct 和调度实体定义