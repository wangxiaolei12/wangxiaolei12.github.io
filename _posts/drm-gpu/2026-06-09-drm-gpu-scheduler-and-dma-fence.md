---
layout: post
title: "Linux DRM GPU 调度器与 dma_fence 机制深度源码分析"
date: 2026-06-09 14:00:00 +0800
excerpt: "结合 Linux mainline 源码深入分析 DRM GPU 通用调度框架的完整工作原理：从 job 提交、entity 选择、依赖解析、流控到超时恢复，以及 dma_fence 同步原语的每个字段在代码中如何流转。"
---

# Linux DRM GPU 调度器与 dma_fence 机制深度源码分析

源码路径：`drivers/gpu/drm/scheduler/`

---

## 第一部分：DRM GPU 调度器架构

### 1.1 设计目标

DRM GPU Scheduler 是一个**通用的软件调度层**，位于用户态驱动和 GPU 硬件之间。它不直接操作硬件，而是通过 `backend_ops` 回调让各 GPU 驱动实现硬件相关操作。

核心文件：

```
drivers/gpu/drm/scheduler/
├── sched_main.c        # 调度主逻辑
├── sched_entity.c      # entity 管理、依赖解析
├── sched_fence.c       # fence 创建与 signal
├── sched_internal.h    # 内部接口
└── gpu_scheduler_trace.h  # trace 事件
```

### 1.2 整体架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                     用户空间 (Mesa / Vulkan)                      │
│                                                                 │
│  App → libdrm → ioctl(DRM_IOCTL_*_SUBMIT) → 提交 GPU 命令       │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│              内核 DRM 驱动 (amdgpu/panfrost/etnaviv...)           │
│                                                                 │
│  1. drm_sched_job_init(job, entity, credits)                    │
│  2. drm_sched_job_add_dependency(job, fence)                    │
│  3. drm_sched_job_arm(job)         ← 分配 seqno，初始化 fence    │
│  4. drm_sched_entity_push_job(job) ← 入队，唤醒 scheduler       │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DRM GPU Scheduler                             │
│                                                                 │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  Scheduler Instance (drm_gpu_scheduler)                  │  │
│   │  ═══════════════════════════════════════                  │  │
│   │                                                          │  │
│   │  ┌────────────┐  ┌────────────┐  ┌────────────┐         │  │
│   │  │ sched_rq[0]│  │ sched_rq[1]│  │ sched_rq[2]│ ...     │  │
│   │  │  KERNEL    │  │   HIGH     │  │  NORMAL    │         │  │
│   │  │            │  │            │  │            │         │  │
│   │  │ ┌────────┐ │  │ ┌────────┐ │  │ ┌────────┐ │         │  │
│   │  │ │entity A│ │  │ │entity C│ │  │ │entity E│ │         │  │
│   │  │ │ job1   │ │  │ │ job4   │ │  │ │ job7   │ │         │  │
│   │  │ │ job2   │ │  │ └────────┘ │  │ │ job8   │ │         │  │
│   │  │ └────────┘ │  │ ┌────────┐ │  │ └────────┘ │         │  │
│   │  │ ┌────────┐ │  │ │entity D│ │  │ ┌────────┐ │         │  │
│   │  │ │entity B│ │  │ │ job5   │ │  │ │entity F│ │         │  │
│   │  │ │ job3   │ │  │ │ job6   │ │  │ │ job9   │ │         │  │
│   │  │ └────────┘ │  │ └────────┘ │  │ └────────┘ │         │  │
│   │  └────────────┘  └────────────┘  └────────────┘         │  │
│   │                                                          │  │
│   │          │ drm_sched_select_entity()                     │  │
│   │          ▼                                               │  │
│   │  ┌─────────────────────┐                                 │  │
│   │  │  work_run_job        │  ← workqueue worker            │  │
│   │  │  ops->run_job(job)   │  → 返回硬件 fence (parent)     │  │
│   │  └──────────┬──────────┘                                 │  │
│   │             │                                            │  │
│   │             ▼                                            │  │
│   │  ┌─────────────────────┐                                 │  │
│   │  │   pending_list       │  等待 GPU 完成                  │  │
│   │  │   [job1] → [job4]   │                                │  │
│   │  └──────────┬──────────┘                                 │  │
│   │             │ dma_fence_add_callback(parent, done_cb)     │  │
│   │             ▼                                            │  │
│   │  ┌─────────────────────┐                                 │  │
│   │  │  work_free_job       │  ← parent fence signal 后触发  │  │
│   │  │  ops->free_job(job)  │                                │  │
│   │  └─────────────────────┘                                 │  │
│   └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
                                  ▼
                          GPU Hardware Ring
```

### 1.3 核心数据结构关系图

```
drm_gpu_scheduler
│
├── ops: drm_sched_backend_ops*    ──→ { run_job, timedout_job, free_job, ... }
│
├── sched_rq[0]: KERNEL ──→ drm_sched_rq
│                            ├── entities (链表): [entity_A] → [entity_B] → ...
│                            ├── rb_tree_root (红黑树, FIFO 策略用)
│                            └── current_entity (RR 策略用)
│
├── sched_rq[1]: HIGH ──→ drm_sched_rq { ... }
├── sched_rq[2]: NORMAL ──→ drm_sched_rq { ... }
├── sched_rq[3]: LOW ──→ drm_sched_rq { ... }
│
├── pending_list: [job_X] → [job_Y] → ...   (已提交到 HW，等完成)
├── work_run_job    (提交下一个 job)
├── work_free_job   (释放完成的 job)
└── work_tdr        (超时检测)

drm_sched_entity
├── job_queue (SPSC): [job1] → [job2] → [job3]  (用户提交的 job 队列)
├── priority: NORMAL
├── rq: 指向所属的 drm_sched_rq
├── sched_list[]: 可调度到的 scheduler 列表（负载均衡）
├── dependency: 当前等待的 dma_fence*
├── fence_context: 分配的 fence 时间线 ID（一次分配 2 个）
├── fence_seq: 原子递增的序号
├── rb_tree_node: FIFO 红黑树节点
└── oldest_job_waiting: 红黑树排序 key

drm_sched_job
├── entity: 所属 entity
├── sched: 所属 scheduler
├── s_fence: drm_sched_fence*  ──→ { scheduled, finished, parent }
├── credits: 消耗的 credit 值
├── dependencies: xarray of dma_fence*  (依赖列表)
├── submit_ts: 提交时间
├── karma: 超时累计
└── queue_node: SPSC 队列节点
```

---

## 第二部分：调度流程源码分析

### 2.1 Job 提交流程

#### Step 1: drm_sched_job_init() — 初始化 job

```c
// sched_main.c
int drm_sched_job_init(struct drm_sched_job *job,
                       struct drm_sched_entity *entity,
                       u32 credits, void *owner, uint64_t drm_client_id)
{
    // 清零，防止未初始化字段的 UB
    memset(job, 0, sizeof(*job));

    job->entity = entity;
    job->credits = credits;

    // 分配 sched_fence（从 slab cache）
    job->s_fence = drm_sched_fence_alloc(entity, owner, drm_client_id);

    INIT_LIST_HEAD(&job->list);
    xa_init_flags(&job->dependencies, XA_FLAGS_ALLOC);
    return 0;
}
```

此时 fence 只是分配了内存，还未初始化 context/seqno。

#### Step 2: drm_sched_job_arm() — 武装 job

```c
// sched_main.c
void drm_sched_job_arm(struct drm_sched_job *job)
{
    struct drm_sched_entity *entity = job->entity;

    // 负载均衡：选择最佳 scheduler
    drm_sched_entity_select_rq(entity);

    sched = entity->rq->sched;
    job->sched = sched;
    job->s_priority = entity->priority;

    // 初始化两个 fence 的 context + seqno
    drm_sched_fence_init(job->s_fence, entity);
}
```

fence 初始化的核心代码：

```c
// sched_fence.c
void drm_sched_fence_init(struct drm_sched_fence *fence,
                           struct drm_sched_entity *entity)
{
    unsigned seq;

    fence->sched = entity->rq->sched;
    seq = atomic_inc_return(&entity->fence_seq);  // 原子递增

    // scheduled fence: context = entity->fence_context, seqno = seq
    dma_fence_init(&fence->scheduled, &drm_sched_fence_ops_scheduled,
                   &fence->lock, entity->fence_context, seq);

    // finished fence: context = entity->fence_context + 1, seqno = seq
    dma_fence_init(&fence->finished, &drm_sched_fence_ops_finished,
                   &fence->lock, entity->fence_context + 1, seq);
}
```

**关键点**：scheduled 和 finished 使用不同的 context（相差 1），但相同的 seqno。这样外部可以通过 context 区分是哪种 fence。

#### Step 3: drm_sched_entity_push_job() — 入队

```c
// sched_entity.c
void drm_sched_entity_push_job(struct drm_sched_job *sched_job)
{
    struct drm_sched_entity *entity = sched_job->entity;

    // 记录提交时间（FIFO 排序用）
    sched_job->submit_ts = submit_ts = ktime_get();

    // SPSC 无锁队列入队
    first = spsc_queue_push(&entity->job_queue, &sched_job->queue_node);

    // 如果是 entity 的第一个 job，需要把 entity 加入 run queue
    if (first) {
        rq = entity->rq;
        sched = rq->sched;

        spin_lock(&rq->lock);
        drm_sched_rq_add_entity(rq, entity);   // 加入链表

        // FIFO 策略：插入红黑树
        if (drm_sched_policy == DRM_SCHED_POLICY_FIFO)
            drm_sched_rq_update_fifo_locked(entity, rq, submit_ts);
        spin_unlock(&rq->lock);

        // 唤醒 scheduler worker
        drm_sched_wakeup(sched);
    }
}
```

**流程图**：

```
push_job()
    │
    ├─ 记录 submit_ts
    │
    ├─ spsc_queue_push (入队)
    │
    ├─ 第一个 job？
    │      │
    │      ├─ YES → add_entity 到 rq
    │      │         ├─ list_add_tail (RR 链表)
    │      │         └─ rb_add_cached (FIFO 红黑树)
    │      │         └─ drm_sched_wakeup() → queue_work(work_run_job)
    │      │
    │      └─ NO  → 不需要唤醒，scheduler 会自动取下一个
    │
    └─ 返回（job 可能随时被调度执行）
```

### 2.2 调度选择流程

当 `work_run_job` worker 执行时：

```c
// sched_main.c
static void drm_sched_run_job_work(struct work_struct *w)
{
    struct drm_gpu_scheduler *sched = container_of(w, ...);

    // ① 选择 entity
    entity = drm_sched_select_entity(sched);
    if (!entity)
        return;  // 没有就绪的 entity

    // ② 弹出 job（含依赖解析）
    sched_job = drm_sched_entity_pop_job(entity);
    if (!sched_job) {
        complete_all(&entity->entity_idle);
        drm_sched_run_job_queue(sched);  // 重新调度
        return;
    }

    // ③ 流控：增加 credit
    atomic_add(sched_job->credits, &sched->credit_count);

    // ④ 加入 pending list + 启动超时计时器
    drm_sched_job_begin(sched_job);

    // ⑤ 调用驱动提交到硬件！
    fence = sched->ops->run_job(sched_job);

    // ⑥ signal scheduled fence，设置 parent
    complete_all(&entity->entity_idle);
    drm_sched_fence_scheduled(s_fence, fence);

    // ⑦ 注册 parent fence 完成回调
    if (!IS_ERR_OR_NULL(fence)) {
        r = dma_fence_add_callback(fence, &sched_job->cb,
                                   drm_sched_job_done_cb);
        if (r == -ENOENT)
            drm_sched_job_done(sched_job, fence->error);
        dma_fence_put(fence);
    } else {
        drm_sched_job_done(sched_job, IS_ERR(fence) ? PTR_ERR(fence) : 0);
    }

    // ⑧ 继续调度下一个
    wake_up(&sched->job_scheduled);
    drm_sched_run_job_queue(sched);
}
```

**完整调度时序图**：

```
    work_run_job 触发
         │
         ▼
┌─ select_entity ─────────────────────────────────────┐
│                                                     │
│  for (i = KERNEL; i < num_rqs; i++) {               │
│      entity = select_from_rq(sched_rq[i]);          │
│      if (entity) break;  // 严格优先级               │
│  }                                                  │
│                                                     │
│  FIFO: 红黑树最左节点（oldest_job_waiting 最小）      │
│  RR:   current_entity 的下一个就绪 entity           │
│                                                     │
└──────────────────────────┬──────────────────────────┘
                           │
                           ▼
┌─ entity_pop_job ────────────────────────────────────┐
│                                                     │
│  peek job from queue                                │
│  while (有依赖未满足) {                               │
│      if (dependency 是同 scheduler 的 sched_fence)   │
│          等 scheduled fence (pipeline!)              │
│      else                                           │
│          等 finished fence                           │
│      注册 wakeup 回调 → return NULL (暂时不调度)     │
│  }                                                  │
│  pop job from queue                                 │
│  更新 FIFO 红黑树 (下一个 job 的 submit_ts)          │
│                                                     │
└──────────────────────────┬──────────────────────────┘
                           │
                           ▼
┌─ run_job ───────────────────────────────────────────┐
│                                                     │
│  credit_count += credits     (流控)                  │
│  pending_list.add(job)       (超时监控)               │
│  start_timeout(TDR timer)                           │
│                                                     │
│  hw_fence = ops->run_job(job)  ← 驱动提交到 GPU     │
│                                                     │
│  signal scheduled_fence      ← "已提交"             │
│  parent = hw_fence                                  │
│  add_callback(parent, done_cb)                      │
│                                                     │
└──────────────────────────┬──────────────────────────┘
                           │
                           ▼  (GPU 完成，parent fence signal)
┌─ job_done_cb ───────────────────────────────────────┐
│                                                     │
│  credit_count -= credits     (释放流控)              │
│  signal finished_fence       ← "已完成"             │
│  queue work_free_job         (清理)                  │
│  queue work_run_job          (继续调度下一个)         │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### 2.3 调度策略源码

#### FIFO 策略 — 红黑树按等待时间排序

```c
// sched_main.c
static struct drm_sched_entity *
drm_sched_rq_select_entity_fifo(struct drm_gpu_scheduler *sched,
                                struct drm_sched_rq *rq)
{
    struct rb_node *rb;

    spin_lock(&rq->lock);

    // 遍历红黑树（从最左/最早开始）
    for (rb = rb_first_cached(&rq->rb_tree_root); rb; rb = rb_next(rb)) {
        struct drm_sched_entity *entity;
        entity = rb_entry(rb, struct drm_sched_entity, rb_tree_node);

        if (drm_sched_entity_is_ready(entity)) {
            // 检查 credit 是否足够
            if (!drm_sched_can_queue(sched, entity)) {
                spin_unlock(&rq->lock);
                return ERR_PTR(-ENOSPC);  // 阻止看更低优先级
            }
            break;  // 选中
        }
    }

    spin_unlock(&rq->lock);
    return rb ? rb_entry(rb, ...) : NULL;
}
```

**红黑树结构**：

```
                    [entity C, ts=100ms]
                   /                    \
    [entity A, ts=50ms]            [entity D, ts=200ms]
         /
[entity B, ts=30ms]  ← rb_first_cached（最左，等待最久）
```

#### Round Robin 策略

```c
// sched_main.c
static struct drm_sched_entity *
drm_sched_rq_select_entity_rr(struct drm_gpu_scheduler *sched,
                              struct drm_sched_rq *rq)
{
    struct drm_sched_entity *entity;

    spin_lock(&rq->lock);

    // 从上次选中的 entity 之后开始
    entity = rq->current_entity;
    if (entity) {
        list_for_each_entry_continue(entity, &rq->entities, list) {
            if (drm_sched_entity_is_ready(entity))
                goto found;
        }
    }

    // 环绕到链表头
    list_for_each_entry(entity, &rq->entities, list) {
        if (drm_sched_entity_is_ready(entity))
            goto found;
        if (entity == rq->current_entity)
            break;
    }

    spin_unlock(&rq->lock);
    return NULL;

found:
    if (!drm_sched_can_queue(sched, entity)) {
        entity = ERR_PTR(-ENOSPC);
    } else {
        rq->current_entity = entity;  // 记住位置
    }
    spin_unlock(&rq->lock);
    return entity;
}
```

**RR 遍历示意**：

```
entities 链表: [A] → [B] → [C] → [D] → [A] → ...
                          ↑
                   current_entity = C

下一次选择：从 D 开始找 ready 的
```

### 2.4 依赖解析源码（Pipeline 优化的核心）

```c
// sched_entity.c
struct drm_sched_job *drm_sched_entity_pop_job(struct drm_sched_entity *entity)
{
    sched_job = drm_sched_entity_queue_peek(entity);
    if (!sched_job)
        return NULL;

    // 逐个检查依赖
    while ((entity->dependency = drm_sched_job_dependency(sched_job, entity))) {
        if (drm_sched_entity_add_dependency_cb(entity, sched_job))
            return NULL;  // 依赖未满足，等回调唤醒
    }

    // 所有依赖满足，弹出 job
    ...
}
```

**Pipeline 优化的关键代码**：

```c
// sched_entity.c
static bool drm_sched_entity_add_dependency_cb(struct drm_sched_entity *entity,
                                               struct drm_sched_job *sched_job)
{
    struct dma_fence *fence = entity->dependency;
    struct drm_sched_fence *s_fence;

    // 情况1：依赖自己 entity 的 fence → 跳过（同 entity 内 job 天然有序）
    if (fence->context == entity->fence_context ||
        fence->context == entity->fence_context + 1) {
        dma_fence_put(entity->dependency);
        return false;  // 不需要等
    }

    // 情况2：依赖同一 scheduler 上的 sched_fence → Pipeline！
    s_fence = to_drm_sched_fence(fence);
    if (!fence->error && s_fence && s_fence->sched == sched &&
        !test_bit(DRM_SCHED_FENCE_DONT_PIPELINE, &fence->flags)) {

        // 关键！只等 scheduled fence，不等 finished
        fence = dma_fence_get(&s_fence->scheduled);
        dma_fence_put(entity->dependency);
        entity->dependency = fence;
    }

    // 注册回调，等 fence signal 后唤醒
    if (!dma_fence_add_callback(entity->dependency, &entity->cb,
                                drm_sched_entity_wakeup))
        return true;   // 回调注册成功，等待中

    // fence 已 signal，不需要等
    dma_fence_put(entity->dependency);
    return false;
}
```

**Pipeline 示意图**：

```
同一 Scheduler 上的两个 Entity:

Entity A:  job1 ───────── run_job ────── GPU 执行中 ────── 完成
                              │
                    scheduled ✓ signal
                              │
Entity B:  job2 (依赖 job1)   │
                              ├── 只等 scheduled（不等完成！）
                              ▼
                         job2 可以提交了！
                         两个 job 在 HW ring 上背靠背执行

不同 Scheduler（或设置了 DONT_PIPELINE）:

Entity C:  job3 ──── run_job ──── GPU 执行 ──── finished ✓ signal
                                                      │
Entity D:  job4 (依赖 job3)                            │
                                                      ├── 必须等 finished
                                                      ▼
                                                 job4 才能提交
```

### 2.5 流控机制源码

```c
// sched_main.c
static u32 drm_sched_available_credits(struct drm_gpu_scheduler *sched)
{
    u32 credits;
    // 可用 = 上限 - 已用
    WARN_ON(check_sub_overflow(sched->credit_limit,
                               atomic_read(&sched->credit_count),
                               &credits));
    return credits;
}

static bool drm_sched_can_queue(struct drm_gpu_scheduler *sched,
                                struct drm_sched_entity *entity)
{
    struct drm_sched_job *s_job;
    s_job = drm_sched_entity_queue_peek(entity);
    if (!s_job)
        return false;

    // 如果单个 job 超过上限，截断到上限（保证 forward progress）
    if (s_job->credits > sched->credit_limit) {
        dev_WARN(sched->dev, "Jobs may not exceed the credit limit\n");
        s_job->credits = sched->credit_limit;
    }

    return drm_sched_available_credits(sched) >= s_job->credits;
}
```

**流控状态机**：

```
                    credit_limit = 32
    ┌──────────────────────────────────────┐
    │█████████████████████░░░░░░░░░░░░░░░░│
    │   credit_count = 17    available = 15│
    └──────────────────────────────────────┘

提交 job (credits=10):
    credit_count: 17 → 27, available: 15 → 5

再提交 job (credits=8):
    can_queue? available(5) >= 8 → NO! 暂停，等之前 job 完成

job 完成 (credits=12):
    credit_count: 27 → 15, available: 5 → 17
    触发 work_run_job → 继续调度
```

### 2.6 负载均衡源码

```c
// sched_entity.c
void drm_sched_entity_select_rq(struct drm_sched_entity *entity)
{
    // 只有一个 scheduler → 不需要均衡
    if (!entity->sched_list)
        return;

    // 队列非空 → 不迁移（保证 job 有序性）
    if (spsc_queue_count(&entity->job_queue))
        return;

    // 上一个 job 还没完成 → 不迁移
    fence = rcu_dereference_check(entity->last_scheduled, true);
    if (fence && !dma_fence_is_signaled(fence))
        return;

    // 选最空闲的 scheduler
    sched = drm_sched_pick_best(entity->sched_list, entity->num_sched_list);
    rq = sched->sched_rq[entity->priority];

    if (rq != entity->rq) {
        drm_sched_rq_remove_entity(entity->rq, entity);  // 从旧 rq 移除
        entity->rq = rq;                                   // 迁移到新 rq
    }
}

// sched_main.c
struct drm_gpu_scheduler *
drm_sched_pick_best(struct drm_gpu_scheduler **sched_list,
                     unsigned int num_sched_list)
{
    unsigned int min_score = UINT_MAX;

    for (i = 0; i < num_sched_list; ++i) {
        sched = sched_list[i];
        if (!sched->ready) continue;

        num_score = atomic_read(sched->score);  // score = 活跃 entity 数
        if (num_score < min_score) {
            min_score = num_score;
            picked_sched = sched;
        }
    }
    return picked_sched;
}
```

**负载均衡示意**：

```
Scheduler A (ring 0): score = 5 (有 5 个活跃 entity)
Scheduler B (ring 1): score = 2 (有 2 个活跃 entity)
Scheduler C (ring 2): score = 8

Entity X 新提交 job → select_rq() → pick_best() → 选 B (score 最小)

Entity X 迁移: A.rq → B.rq
```

### 2.7 超时检测与恢复 (TDR)

```c
// sched_main.c
static void drm_sched_job_timedout(struct work_struct *work)
{
    sched = container_of(work, struct drm_gpu_scheduler, work_tdr.work);

    spin_lock(&sched->job_list_lock);
    // 取 pending_list 头部（最老的 job）
    job = list_first_entry_or_null(&sched->pending_list, ...);

    if (job) {
        list_del_init(&job->list);   // 摘出来
        spin_unlock(&sched->job_list_lock);

        // 调用驱动的超时处理（通常做 GPU reset）
        status = job->sched->ops->timedout_job(job);

        // 处理 guilty job
        if (sched->free_guilty) {
            job->sched->ops->free_job(job);
            sched->free_guilty = false;
        }

        // 如果是误报（GPU 没挂），放回去
        if (status == DRM_GPU_SCHED_STAT_NO_HANG)
            drm_sched_job_reinsert_on_false_timeout(sched, job);
    }

    // 重启超时计时器
    if (status != DRM_GPU_SCHED_STAT_ENODEV)
        drm_sched_start_timeout_unlocked(sched);
}
```

**TDR 流程图**：

```
job 提交到 HW
    │
    ├── 启动 delayed_work (timeout 秒后)
    │
    ├── 正常完成 → cancel_delayed_work → 一切正常
    │
    └── 超时触发 → drm_sched_job_timedout()
                       │
                       ▼
              ops->timedout_job(bad_job)
                       │
            ┌──────────┼──────────────┐
            │          │              │
            ▼          ▼              ▼
        RESET      NO_HANG        ENODEV
    (GPU 复位)   (误报，放回)   (设备没了)
            │
            ▼
    drm_sched_stop()     ← 停 scheduler
    kill guilty entity   ← karma > hang_limit 的 entity
    GPU reset            ← 驱动做硬件复位
    drm_sched_start()    ← 重启，重新提交 pending jobs
```

---

## 第三部分：dma_fence 完整源码分析

### 3.1 实际结构（union 分时复用）

```c
// include/linux/dma-fence.h
struct dma_fence {
    union {
        spinlock_t *extern_lock;   // 传统：外部共享锁
        spinlock_t inline_lock;    // 推荐：fence 自带锁
    };

    const struct dma_fence_ops __rcu *ops;  // 操作函数表

    union {
        struct list_head cb_list;   // ①signal 前：回调链表
        ktime_t timestamp;          // ②signal 后：完成时间戳
        struct rcu_head rcu;        // ③release 后：RCU 释放
    };

    u64 context;           // 时间线 ID
    u64 seqno;             // 时间线内序号
    unsigned long flags;   // 状态位
    struct kref refcount;  // 引用计数
    int error;             // 错误码
};
```

**内存布局与生命周期**：

```
┌─────────────────────────────────────────────────────────┐
│ 阶段 1: 初始化后，signal 前                              │
│                                                         │
│  lock | ops | cb_list:[cb1]→[cb2]→... | ctx | seq | flags│
│                  ↑                                       │
│          回调链表活跃                                     │
└─────────────────────────────────────────────────────────┘
                        │ dma_fence_signal()
                        ▼
┌─────────────────────────────────────────────────────────┐
│ 阶段 2: signal 后                                        │
│                                                         │
│  lock | ops | timestamp(ktime_t) | ctx | seq | flags     │
│                  ↑                                       │
│    cb_list 内存被 timestamp 覆写                          │
│    flags |= SIGNALED_BIT | TIMESTAMP_BIT                │
└─────────────────────────────────────────────────────────┘
                        │ dma_fence_put() → refcount=0
                        ▼
┌─────────────────────────────────────────────────────────┐
│ 阶段 3: release 后                                       │
│                                                         │
│  lock | ops | rcu_head | ctx | seq | flags               │
│                  ↑                                       │
│    timestamp 内存被 rcu_head 覆写                         │
│    call_rcu() 延迟释放                                    │
└─────────────────────────────────────────────────────────┘
```

### 3.2 初始化源码

```c
// drivers/dma-buf/dma-fence.c
static void
__dma_fence_init(struct dma_fence *fence, const struct dma_fence_ops *ops,
                 spinlock_t *lock, u64 context, u64 seqno, unsigned long flags)
{
    BUG_ON(!ops || !ops->get_driver_name || !ops->get_timeline_name);

    kref_init(&fence->refcount);              // refcount = 1
    RCU_INIT_POINTER(fence->ops, ops);
    INIT_LIST_HEAD(&fence->cb_list);          // 空回调链表
    fence->context = context;
    fence->seqno = seqno;
    fence->flags = flags | BIT(DMA_FENCE_FLAG_INITIALIZED_BIT);
    fence->error = 0;

    // 锁的选择
    if (lock) {
        fence->extern_lock = lock;             // 使用外部锁
    } else {
        spin_lock_init(&fence->inline_lock);   // 使用内联锁
        fence->flags |= BIT(DMA_FENCE_FLAG_INLINE_LOCK_BIT);
    }
}
```

### 3.3 Signal 源码（状态转换的核心）

```c
// drivers/dma-buf/dma-fence.c
void dma_fence_signal_timestamp_locked(struct dma_fence *fence,
                                       ktime_t timestamp)
{
    struct dma_fence_cb *cur, *tmp;
    struct list_head cb_list;

    dma_fence_assert_held(fence);

    // 原子设置 SIGNALED_BIT（只会成功一次）
    if (unlikely(test_and_set_bit(DMA_FENCE_FLAG_SIGNALED_BIT, &fence->flags)))
        return;  // 已 signal 过，幂等

    // 把 cb_list 摘到临时变量（因为马上要覆写这块内存）
    list_replace(&fence->cb_list, &cb_list);

    // 写入 timestamp（覆写 cb_list 所在的 union 内存）
    fence->timestamp = timestamp;
    set_bit(DMA_FENCE_FLAG_TIMESTAMP_BIT, &fence->flags);

    // 遍历回调链表，逐个调用
    list_for_each_entry_safe(cur, tmp, &cb_list, node) {
        INIT_LIST_HEAD(&cur->node);
        cur->func(fence, cur);  // 调用回调函数
    }
}
```

**signal 时序图**：

```
              持锁
                │
                ▼
    test_and_set_bit(SIGNALED) ──→ 已设置？return（幂等）
                │
                ▼ (首次)
    list_replace(cb_list → tmp_list)
                │
                ▼
    fence->timestamp = now
    set_bit(TIMESTAMP_BIT)
                │
                ▼
    遍历 tmp_list:
        cb1->func(fence, cb1)  ← 如 drm_sched_job_done_cb
        cb2->func(fence, cb2)  ← 如 drm_sched_entity_wakeup
        ...
                │
                ▼
              释放锁
```

### 3.4 add_callback 源码（注册异步通知）

```c
// drivers/dma-buf/dma-fence.c
int dma_fence_add_callback(struct dma_fence *fence, struct dma_fence_cb *cb,
                           dma_fence_func_t func)
{
    unsigned long flags;
    int ret = 0;

    if (WARN_ON(!fence || !func))
        return -EINVAL;

    // 快速路径：已 signal 就不用注册了
    if (test_bit(DMA_FENCE_FLAG_SIGNALED_BIT, &fence->flags)) {
        INIT_LIST_HEAD(&cb->node);
        return -ENOENT;
    }

    dma_fence_lock_irqsave(fence, flags);

    // 双重检查（持锁后再看一次）
    if (__dma_fence_enable_signaling(fence)) {
        cb->func = func;
        list_add_tail(&cb->node, &fence->cb_list);
    } else {
        // 在我们拿锁的过程中已经 signal 了
        INIT_LIST_HEAD(&cb->node);
        ret = -ENOENT;
    }

    dma_fence_unlock_irqrestore(fence, flags);
    return ret;
}
```

**竞态处理示意**：

```
Thread A (add_callback)          Thread B (signal)
─────────────────────           ──────────────────
test_bit(SIGNALED) → false
                                spin_lock()
                                test_and_set(SIGNALED)
                                list_replace → 摘走 cb_list
                                call callbacks
                                spin_unlock()
spin_lock()
__enable_signaling()
  → test_bit(SIGNALED) → true!
  → return false
ret = -ENOENT ← 告诉调用者已完成
spin_unlock()
```

### 3.5 context 和 seqno 的使用

#### 分配 context

```c
// drivers/dma-buf/dma-fence.c
static atomic64_t dma_fence_context_counter = ATOMIC64_INIT(1);

u64 dma_fence_context_alloc(unsigned num)
{
    return atomic64_fetch_add(num, &dma_fence_context_counter);
}
```

全局原子计数器，保证每次分配的 context 都是唯一的。

#### 比较 fence 先后

```c
// include/linux/dma-fence.h
static inline bool dma_fence_is_later(struct dma_fence *f1,
                                      struct dma_fence *f2)
{
    // 必须是同一 context！不同 context 的 fence 无法比较
    if (WARN_ON(f1->context != f2->context))
        return false;

    return f1->seqno > f2->seqno;
}
```

**实际应用——依赖去重**：

```c
// sched_main.c
int drm_sched_job_add_dependency(struct drm_sched_job *job,
                                 struct dma_fence *fence)
{
    // 遍历已有依赖
    xa_for_each(&job->dependencies, index, entry) {
        if (entry->context != fence->context)
            continue;

        // 同一 context：只保留更晚的那个
        if (dma_fence_is_later(fence, entry)) {
            dma_fence_put(entry);
            xa_store(&job->dependencies, index, fence, GFP_KERNEL);
        } else {
            dma_fence_put(fence);  // 新的更早，丢弃
        }
        return 0;  // 已处理
    }

    // 新 context，直接添加
    xa_alloc(&job->dependencies, &id, fence, xa_limit_32b, GFP_KERNEL);
    return 0;
}
```

**去重效果**：

```
Entity A 连续提交 job1(seq=1), job2(seq=2), job3(seq=3)

Entity B 的 jobX 依赖 Entity A 的所有 job:
  add_dependency(job1.finished)  → deps: {ctx=101: fence(seq=1)}
  add_dependency(job2.finished)  → deps: {ctx=101: fence(seq=2)}  ← 替换了 seq=1
  add_dependency(job3.finished)  → deps: {ctx=101: fence(seq=3)}  ← 替换了 seq=2

最终只等 seq=3（最晚的），因为 3 完成了 → 1,2 一定也完成了
```

### 3.6 flags 的完整生命周期

```c
enum {
    DMA_FENCE_FLAG_INITIALIZED_BIT,    // dma_fence_init() 设置
    DMA_FENCE_FLAG_INLINE_LOCK_BIT,    // init(lock=NULL) 设置
    DMA_FENCE_FLAG_SEQNO64_BIT,        // 64-bit seqno 模式
    DMA_FENCE_FLAG_SIGNALED_BIT,       // signal() 设置（核心！）
    DMA_FENCE_FLAG_TIMESTAMP_BIT,      // signal 后 timestamp 有效
    DMA_FENCE_FLAG_ENABLE_SIGNAL_BIT,  // 首次 add_callback 设置
    DMA_FENCE_FLAG_USER_BITS,          // 驱动自定义区域起始
};
```

**Scheduler 自定义 flags**：

```c
// include/drm/gpu_scheduler.h
#define DRM_SCHED_FENCE_DONT_PIPELINE      DMA_FENCE_FLAG_USER_BITS
#define DRM_SCHED_FENCE_FLAG_HAS_DEADLINE_BIT  (DMA_FENCE_FLAG_USER_BITS + 1)
```

### 3.7 error 的传播路径

```c
// 驱动设置错误
dma_fence_set_error(fence, -EIO);      // 必须在 signal 前！
dma_fence_signal(fence);

// Scheduler 中的传播链：
//
// parent fence (HW) 完成，可能带 error
//          │
//          ▼ drm_sched_job_done_cb()
//
static void drm_sched_job_done_cb(struct dma_fence *f, struct dma_fence_cb *cb)
{
    struct drm_sched_job *s_job = container_of(cb, ...);
    drm_sched_job_done(s_job, f->error);  // 传播 error
}

static void drm_sched_job_done(struct drm_sched_job *s_job, int result)
{
    ...
    drm_sched_fence_finished(s_fence, result);  // → finished fence
}

void drm_sched_fence_finished(struct drm_sched_fence *fence, int result)
{
    if (result)
        dma_fence_set_error(&fence->finished, result);  // 设置 error
    dma_fence_signal(&fence->finished);                  // signal
}
```

**error 传播图**：

```
GPU 执行失败
    │
    ▼
parent fence: error = -EIO, signal()
    │
    ▼ (callback)
drm_sched_job_done(job, -EIO)
    │
    ▼
finished fence: error = -EIO, signal()
    │
    ▼ (用户态通过 syncobj/dma_resv 感知)
Vulkan: vkWaitForFences() → VK_ERROR_DEVICE_LOST
```

### 3.8 Scheduler Fence 的引用计数与释放

```c
// sched_fence.c

// finished fence refcount → 0 时
static void drm_sched_fence_release_finished(struct dma_fence *f)
{
    struct drm_sched_fence *fence = to_drm_sched_fence(f);
    // 释放对 scheduled fence 的引用
    dma_fence_put(&fence->scheduled);
}

// scheduled fence refcount → 0 时
static void drm_sched_fence_release_scheduled(struct dma_fence *f)
{
    struct drm_sched_fence *fence = to_drm_sched_fence(f);
    dma_fence_put(fence->parent);  // 释放 parent fence
    // RCU 延迟释放整个 drm_sched_fence 结构
    call_rcu(&fence->finished.rcu, drm_sched_fence_free_rcu);
}
```

**引用关系**：

```
                   ┌─────────────────────┐
                   │ drm_sched_fence     │
                   │                     │
 外部持有引用 ────→ │  finished fence     │ ── release → put(scheduled)
                   │       ↓             │
                   │  scheduled fence    │ ── release → put(parent) + rcu_free
                   │       ↓             │
                   │  parent (hw fence)  │
                   └─────────────────────┘

释放顺序：finished → scheduled → parent → kfree(sched_fence)
```

---

## 第四部分：完整数据流总结

```
┌─────────── 用户态 ───────────────────────────────────────────────────┐
│  app → Mesa/Vulkan → ioctl → 驱动创建 job                             │
└──────────────────────────────────────┬──────────────────────────────┘
                                       │
            ┌──────────────────────────┼──────────────────────────┐
            │              Scheduler    │                          │
            │                          ▼                          │
            │  ┌─── job_init ────────────────────────────────┐    │
            │  │ 分配 s_fence (kmem_cache)                    │    │
            │  │ 初始化 dependencies xarray                   │    │
            │  └──────────────────────────┬─────────────────┘    │
            │                             │                       │
            │  ┌─── job_arm ──────────────┼─────────────────┐    │
            │  │ select_rq (负载均衡)      │                 │    │
            │  │ fence_init:               │                 │    │
            │  │   scheduled.ctx = N       │                 │    │
            │  │   finished.ctx  = N+1     │                 │    │
            │  │   both.seqno = atomic++   │                 │    │
            │  └──────────────────────────┼─────────────────┘    │
            │                             │                       │
            │  ┌─── push_job ─────────────┼─────────────────┐    │
            │  │ spsc_queue_push           │                 │    │
            │  │ if first: add_entity      │                 │    │
            │  │           wakeup sched    │                 │    │
            │  └──────────────────────────┼─────────────────┘    │
            │                             │                       │
            │  ┌─── run_job_work ─────────┼─────────────────┐    │
            │  │                          ▼                  │    │
            │  │ select_entity (优先级 + RR/FIFO)            │    │
            │  │        │                                    │    │
            │  │        ▼                                    │    │
            │  │ pop_job (解析依赖)                           │    │
            │  │   │ 自己 entity 的 fence → 跳过             │    │
            │  │   │ 同 sched fence → 等 scheduled (pipeline)│    │
            │  │   │ 其他 fence → 等 finished               │    │
            │  │   │ 未满足 → 注册回调 return NULL           │    │
            │  │        │                                    │    │
            │  │        ▼ (所有依赖满足)                      │    │
            │  │ credit_count += credits                     │    │
            │  │ pending_list.add + start_timeout            │    │
            │  │        │                                    │    │
            │  │        ▼                                    │    │
            │  │ ┌──────────────────────┐                   │    │
            │  │ │ ops->run_job(job)    │ ← 驱动提交 HW     │    │
            │  │ │ returns hw_fence     │                   │    │
            │  │ └──────────┬───────────┘                   │    │
            │  │            │                                │    │
            │  │            ▼                                │    │
            │  │ s_fence->parent = hw_fence                  │    │
            │  │ signal(scheduled)  ← "已提交到 HW"          │    │
            │  │ add_callback(hw_fence, done_cb)             │    │
            │  │                                             │    │
            │  └─────────────────────────────────────────────┘    │
            │                             │                       │
            │         ┌───────────────────┘                       │
            │         │  GPU 执行中...                             │
            │         │  超时？→ TDR → ops->timedout_job          │
            │         │                                           │
            │         ▼  hw_fence signal (GPU 完成)                │
            │  ┌─── done_cb ─────────────────────────────────┐    │
            │  │ credit_count -= credits                      │    │
            │  │ signal(finished, hw_fence->error)            │    │
            │  │ queue work_free_job                          │    │
            │  │ queue work_run_job (继续调度)                 │    │
            │  └──────────────────────────┬─────────────────┘    │
            │                             │                       │
            │  ┌─── free_job_work ────────┼─────────────────┐    │
            │  │ pending_list.remove       │                 │    │
            │  │ cancel_timeout            │                 │    │
            │  │ ops->free_job(job)        │                 │    │
            │  └──────────────────────────┼─────────────────┘    │
            │                             │                       │
            └─────────────────────────────┼───────────────────────┘
                                          │
                                          ▼
                                  用户态收到 fence signal
                                  (syncobj / dma_resv / poll)
```

---

## 附录：关键源码函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `drm_sched_init()` | sched_main.c | 初始化 scheduler |
| `drm_sched_run_job_work()` | sched_main.c | 调度主循环 |
| `drm_sched_select_entity()` | sched_main.c | 选择下一个 entity |
| `drm_sched_rq_select_entity_fifo()` | sched_main.c | FIFO 策略选择 |
| `drm_sched_rq_select_entity_rr()` | sched_main.c | RR 策略选择 |
| `drm_sched_can_queue()` | sched_main.c | 流控检查 |
| `drm_sched_job_done()` | sched_main.c | job 完成处理 |
| `drm_sched_job_timedout()` | sched_main.c | 超时处理 |
| `drm_sched_pick_best()` | sched_main.c | 负载均衡选择 |
| `drm_sched_entity_init()` | sched_entity.c | 初始化 entity |
| `drm_sched_entity_push_job()` | sched_entity.c | job 入队 |
| `drm_sched_entity_pop_job()` | sched_entity.c | 弹出 job + 依赖解析 |
| `drm_sched_entity_add_dependency_cb()` | sched_entity.c | Pipeline 优化核心 |
| `drm_sched_entity_select_rq()` | sched_entity.c | 负载均衡迁移 |
| `drm_sched_fence_init()` | sched_fence.c | 初始化 scheduled+finished |
| `drm_sched_fence_scheduled()` | sched_fence.c | signal scheduled fence |
| `drm_sched_fence_finished()` | sched_fence.c | signal finished fence |
| `dma_fence_init()` | dma-fence.c | 初始化 fence |
| `dma_fence_signal_timestamp_locked()` | dma-fence.c | signal + 回调 |
| `dma_fence_add_callback()` | dma-fence.c | 注册异步回调 |
| `dma_fence_is_later()` | dma-fence.h | 比较 fence 先后 |
| `dma_fence_context_alloc()` | dma-fence.c | 分配唯一 context |
