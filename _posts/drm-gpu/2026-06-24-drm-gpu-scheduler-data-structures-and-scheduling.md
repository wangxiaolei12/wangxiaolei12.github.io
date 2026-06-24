---
layout: post
title: "DRM GPU Scheduler 数据结构与调度流程源码剖析"
date: 2026-06-24 13:00:00 +0800
excerpt: "从内核源码出发，详细分析 drm_gpu_scheduler 的四层数据结构（scheduler→rq→entity→job）、FIFO/RR 两种调度策略的实现、硬件队列与软件队列的对应关系，以及完整的调度循环流程。"
---

# DRM GPU Scheduler 数据结构与调度流程源码剖析

源码路径：`drivers/gpu/drm/scheduler/`

本文基于 LTS26 内核源码，深入分析 DRM GPU 调度器的数据结构设计和调度算法实现。

---

## 一、整体架构

一个 GPU 有多个硬件 ring（命令执行通道），每个 ring 对应一个 scheduler 实例：

```
GPU 硬件
├── GFX Ring      ←→  Scheduler #0
├── Compute Ring  ←→  Scheduler #1
├── DMA Ring      ←→  Scheduler #2
└── Video Ring    ←→  Scheduler #3
```

**核心设计原则：每个硬件 ring 恰好对应一个 scheduler，scheduler 负责从多个软件实体中选取 job 送入该 ring 执行。**

---

## 二、四层数据结构

### 2.1 第一层：Scheduler（drm_gpu_scheduler）

```c
// include/drm/gpu_scheduler.h
struct drm_gpu_scheduler {
    const struct drm_sched_backend_ops *ops;  // 驱动回调
    u32                 credit_limit;         // 信用额度上限（流控）
    atomic_t            credit_count;         // 当前已使用信用
    u32                 num_rqs;              // run queue 数量
    struct drm_sched_rq **sched_rq;          // run queue 指针数组
    struct list_head    pending_list;         // 已提交硬件的 job
    struct work_struct  work_run_job;         // 调度工作项
    struct work_struct  work_free_job;        // 回收工作项
    struct workqueue_struct *submit_wq;       // ordered workqueue
    ...
};
```

**要点：**
- `sched_rq` 是一个数组，按优先级索引，最多 4 个（KERNEL/HIGH/NORMAL/LOW）
- `pending_list` 保存已经送到硬件但还没执行完的 job（按提交顺序）
- `submit_wq` 是 ordered workqueue，保证调度逻辑串行执行，不会并发
- `credit_limit` / `credit_count` 实现流控，防止塞太多 job 给硬件

### 2.2 第二层：Run Queue（drm_sched_rq）

```c
// include/drm/gpu_scheduler.h
struct drm_sched_rq {
    struct drm_gpu_scheduler  *sched;          // 所属 scheduler
    spinlock_t                lock;
    struct drm_sched_entity   *current_entity; // RR 策略的轮转指针
    struct list_head          entities;        // entity 双向链表（RR 用）
    struct rb_root_cached     rb_tree_root;    // entity 红黑树（FIFO 用）
};
```

**要点：**
- 每个优先级对应一个 rq，rq 中容纳的是 **entity（不是 job）**
- rq 同时维护两种数据结构来组织 entity：
  - `entities` 链表：用于 Round-Robin 策略
  - `rb_tree_root` 红黑树：用于 FIFO 策略
- `current_entity` 指针记录 RR 模式下"上次选到哪了"

### 2.3 第三层：Entity（drm_sched_entity）

```c
// include/drm/gpu_scheduler.h
struct drm_sched_entity {
    struct list_head     list;              // 挂在 rq->entities 链表
    struct drm_sched_rq  *rq;              // 当前所属 rq
    enum drm_sched_priority priority;      // 优先级
    struct spsc_queue    job_queue;         // job 队列（SPSC 无锁链表）
    struct rb_node       rb_tree_node;     // 红黑树节点（FIFO 用）
    ktime_t              oldest_job_waiting;// 最老 job 的时间戳（红黑树排序 key）
    ...
};
```

**要点：**
- 一个 entity 通常代表一个用户进程的 GPU context
- entity 内部的 `job_queue` 是 **SPSC（Single-Producer Single-Consumer）无锁单链表**，严格 FIFO
- entity 同时通过 `list` 挂在 rq 的链表上，通过 `rb_tree_node` 挂在 rq 的红黑树上
- `oldest_job_waiting` 是红黑树的排序依据

### 2.4 第四层：Job（drm_sched_job）

```c
// include/drm/gpu_scheduler.h
struct drm_sched_job {
    ktime_t              submit_ts;     // 提交时间戳
    struct spsc_node     queue_node;    // 在 entity->job_queue 中的节点
    struct list_head     list;          // 在 scheduler->pending_list 中
    u32                  credits;       // 占用的信用额度
    struct xarray        dependencies;  // 依赖的 fence 集合
    struct drm_sched_fence *s_fence;    // scheduled + finished fence
    ...
};
```

**要点：**
- 每个 job 有一个 `submit_ts` 记录入队时间
- `dependencies` 用 xarray 存储依赖的 dma_fence，全部 signal 后才可执行
- `credits` 通常为 1，表示这个 job 占用多少硬件资源额度

### 2.5 数据结构全景图

```
┌─────────────────────────────────────────────────────────────┐
│  Scheduler（1 个硬件 ring 对应 1 个）                         │
│                                                             │
│  ┌───────────────────────────────────────────────────┐      │
│  │  rq[0] KERNEL 优先级                               │      │
│  │  ├── entities 链表: [entity X]         ← RR 用    │      │
│  │  └── rb_tree: {entity X}               ← FIFO 用 │      │
│  └───────────────────────────────────────────────────┘      │
│                                                             │
│  ┌───────────────────────────────────────────────────┐      │
│  │  rq[1] HIGH 优先级                                 │      │
│  │  ├── entities 链表: [entity A]                     │      │
│  │  └── rb_tree: {entity A}                          │      │
│  └───────────────────────────────────────────────────┘      │
│                                                             │
│  ┌───────────────────────────────────────────────────┐      │
│  │  rq[2] NORMAL 优先级                               │      │
│  │  ├── entities 链表: [entity B ↔ entity C]          │      │
│  │  └── rb_tree: {B(100ns), C(200ns)}                │      │
│  └───────────────────────────────────────────────────┘      │
│                                                             │
│  ┌───────────────────────────────────────────────────┐      │
│  │  rq[3] LOW 优先级                                  │      │
│  │  ├── entities 链表: []                             │      │
│  │  └── rb_tree: {}                                  │      │
│  └───────────────────────────────────────────────────┘      │
│                                                             │
│  pending_list: [已提交硬件未完成的 job]                       │
│  credit_limit: 32    credit_count: 当前已占用                │
└─────────────────────────────────────────────────────────────┘

Entity 内部：
┌─────────────────────────────────────┐
│  Entity B                           │
│  job_queue (SPSC FIFO 单链表):      │
│  head → [job4] → [job5] → NULL      │
└─────────────────────────────────────┘
```

---

## 三、Entity 的组织方式 — 链表 + 红黑树

这是理解调度策略的关键：**rq 中的 entity 同时被两种数据结构索引**。

### 3.1 双向链表（用于 Round-Robin）

```c
// sched_main.c
void drm_sched_rq_add_entity(struct drm_sched_rq *rq,
                             struct drm_sched_entity *entity)
{
    list_add_tail(&entity->list, &rq->entities);
}
```

entity 加入链表尾部，RR 调度时从 `current_entity` 之后开始遍历。

### 3.2 红黑树（用于 FIFO）

```c
// sched_main.c
void drm_sched_rq_update_fifo_locked(struct drm_sched_entity *entity,
                                     struct drm_sched_rq *rq, ktime_t ts)
{
    drm_sched_rq_remove_fifo_locked(entity, rq);
    entity->oldest_job_waiting = ts;
    rb_add_cached(&entity->rb_tree_node, &rq->rb_tree_root,
                  drm_sched_entity_compare_before);
}
```

红黑树按 `oldest_job_waiting`（entity 中最老 job 的提交时间）排序，FIFO 调度时直接取最左节点（等待最久的 entity）。

### 3.3 什么时候加入/离开 rq

```c
// sched_entity.c: drm_sched_entity_push_job()
first = spsc_queue_push(&entity->job_queue, &sched_job->queue_node);

if (first) {
    // entity 队列从空变非空 → 加入 rq
    drm_sched_rq_add_entity(rq, entity);
    if (drm_sched_policy == DRM_SCHED_POLICY_FIFO)
        drm_sched_rq_update_fifo_locked(entity, rq, submit_ts);
}
```

- **加入**：entity 的第一个 job 入队时
- **不再被选中**：entity 队列为空或有未满足的依赖时，`drm_sched_entity_is_ready()` 返回 false

---

## 四、两种调度策略

由模块参数控制，**默认 FIFO**：

```c
// sched_main.c
int drm_sched_policy = DRM_SCHED_POLICY_FIFO;  // 默认

MODULE_PARM_DESC(sched_policy,
    "Specify the scheduling policy for entities on a run-queue, "
    "0 = Round Robin, 1 = FIFO (default).");
module_param_named(sched_policy, drm_sched_policy, int, 0444);
```

### 4.1 FIFO 策略（默认）

```c
static struct drm_sched_entity *
drm_sched_rq_select_entity_fifo(struct drm_gpu_scheduler *sched,
                                struct drm_sched_rq *rq)
{
    spin_lock(&rq->lock);
    for (rb = rb_first_cached(&rq->rb_tree_root); rb; rb = rb_next(rb)) {
        entity = rb_entry(rb, struct drm_sched_entity, rb_tree_node);
        if (drm_sched_entity_is_ready(entity)) {
            if (!drm_sched_can_queue(sched, entity))
                return ERR_PTR(-ENOSPC);
            reinit_completion(&entity->entity_idle);
            break;
        }
    }
    spin_unlock(&rq->lock);
    return rb ? entity : NULL;
}
```

**逻辑：** 从红黑树最左节点开始（`oldest_job_waiting` 最小），找到第一个 ready 的 entity。这保证了**全局按提交时间先到先服务**。

### 4.2 Round-Robin 策略

```c
static struct drm_sched_entity *
drm_sched_rq_select_entity_rr(struct drm_gpu_scheduler *sched,
                              struct drm_sched_rq *rq)
{
    spin_lock(&rq->lock);
    entity = rq->current_entity;

    // 从 current_entity 之后开始找
    if (entity) {
        list_for_each_entry_continue(entity, &rq->entities, list) {
            if (drm_sched_entity_is_ready(entity))
                goto found;
        }
    }
    // 绕回链表头继续找
    list_for_each_entry(entity, &rq->entities, list) {
        if (drm_sched_entity_is_ready(entity))
            goto found;
        if (entity == rq->current_entity)
            break;
    }
    return NULL;

found:
    rq->current_entity = entity;  // 记住位置，下次从这往后
    reinit_completion(&entity->entity_idle);
    return entity;
}
```

**逻辑：** 从上次选中的位置继续往后遍历链表，找到下一个 ready 的 entity。各 entity 轮流获得机会。

### 4.3 两种策略的对比

假设 rq 中有 entity A（job 提交时间 t=10）、entity B（t=5）、entity C（t=20）：

| 策略 | 选择依据 | 本例选中 | 特点 |
|------|----------|---------|------|
| FIFO | 谁的最老 job 等得最久 | B（t=5 最小） | 全局时间公平 |
| RR | current_entity 之后的下一个 | 取决于上次选了谁 | 机会均等 |

**注意：无论哪种策略，选中 entity 后只取其队头的 1 个 job。不会一次取完一个 entity 的所有 job。**

---

## 五、完整调度循环

调度在 ordered workqueue 上串行执行 `drm_sched_run_job_work()`：

```c
static void drm_sched_run_job_work(struct work_struct *w)
{
    struct drm_gpu_scheduler *sched = ...;

    // 第1步：选 entity（先按优先级，再按 FIFO/RR）
    entity = drm_sched_select_entity(sched);
    if (!entity)
        return;  // 没有活干

    // 第2步：从 entity 队头取 1 个 job
    sched_job = drm_sched_entity_pop_job(entity);
    if (!sched_job) {
        drm_sched_run_job_queue(sched);  // entity 有依赖未满足，重试
        return;
    }

    // 第3步：扣 credit
    atomic_add(sched_job->credits, &sched->credit_count);

    // 第4步：加入 pending_list，启动超时定时器
    drm_sched_job_begin(sched_job);

    // 第5步：调用驱动回调，提交给硬件
    fence = sched->ops->run_job(sched_job);

    // 第6步：注册完成回调
    dma_fence_add_callback(fence, &sched_job->cb, drm_sched_job_done_cb);

    // 第7步：继续调度下一个
    drm_sched_run_job_queue(sched);
}
```

`drm_sched_select_entity()` 的优先级扫描：

```c
static struct drm_sched_entity *
drm_sched_select_entity(struct drm_gpu_scheduler *sched)
{
    for (i = DRM_SCHED_PRIORITY_KERNEL; i < sched->num_rqs; i++) {
        entity = drm_sched_policy == DRM_SCHED_POLICY_FIFO ?
            drm_sched_rq_select_entity_fifo(sched, sched->sched_rq[i]) :
            drm_sched_rq_select_entity_rr(sched, sched->sched_rq[i]);
        if (entity)
            break;  // 高优先级有活，不看低优先级
    }
    return IS_ERR(entity) ? NULL : entity;
}
```

---

## 六、Job 的生命周期

```
用户提交
  │
  ▼
drm_sched_job_init()          创建 job，分配 fence
  │
  ▼
drm_sched_job_arm()           编号，绑定 scheduler
  │
  ▼
drm_sched_entity_push_job()   入队到 entity->job_queue（SPSC FIFO）
  │                           如果是 entity 第一个 job，加入 rq 并唤醒调度器
  │
  ▼ ─── 调度器调度循环 ───
  │
drm_sched_entity_pop_job()    从队头取出（检查依赖，全部满足才取）
  │
  ▼
sched->ops->run_job()         驱动写入硬件 ring buffer
  │                           job 进入 pending_list
  │
  ▼ ─── GPU 硬件执行 ───
  │
hw_fence signal               GPU 完成，中断触发
  │
  ▼
drm_sched_job_done()          从 pending_list 移除
  │                           释放 credit
  │                           signal finished_fence
  ▼
sched->ops->free_job()        驱动释放资源
```

---

## 七、硬件队列与软件队列的对应关系

### 7.1 对应关系

```
1 个 Scheduler ←→ 1 个硬件 Ring（一对一）
N 个 Entity    ──→ 1 个 Scheduler（多对一）
```

多个用户进程（entity）共享一个硬件 ring，由 scheduler 仲裁。

### 7.2 为什么不直接多对多？

硬件 ring buffer 是有限资源，不能让所有进程直接写入。Scheduler 的作用：
1. **排序**：按优先级和 FIFO/RR 策略决定顺序
2. **流控**：credit 机制限制同时在硬件中的 job 数量
3. **依赖管理**：只有依赖满足的 job 才提交
4. **超时恢复**：检测 GPU hang 并 reset

### 7.3 Entity 可以跨 Scheduler 迁移

如果一个 entity 绑定了多个 scheduler（即多个硬件 ring 都能执行它的 job），entity 会在队列空时选择负载最轻的 scheduler：

```c
// sched_entity.c
void drm_sched_entity_select_rq(struct drm_sched_entity *entity)
{
    if (!entity->sched_list)  // 只有一个 scheduler
        return;
    if (spsc_queue_count(&entity->job_queue))  // 队列非空，不迁移
        return;

    sched = drm_sched_pick_best(entity->sched_list, entity->num_sched_list);
    rq = sched->sched_rq[entity->priority];
    if (rq != entity->rq) {
        drm_sched_rq_remove_entity(entity->rq, entity);
        entity->rq = rq;
    }
}
```

`drm_sched_pick_best()` 选择 `score` 最低的 scheduler（score 代表负载）。

---

## 八、SPSC Queue — Entity 内部的 Job 队列

```c
// include/drm/spsc_queue.h
struct spsc_queue {
    struct spsc_node *head;        // 消费者从这取
    atomic_long_t    tail;         // 生产者往这加
    atomic_t         job_count;    // 计数
};
```

这是一个无锁的单生产者单消费者 FIFO 队列：
- **生产者**（用户提交路径）：`spsc_queue_push()` 在 tail 追加
- **消费者**（调度器工作线程）：`spsc_queue_pop()` 从 head 取出

保证 **entity 内部的 job 严格按提交顺序执行**。

---

## 九、打个比方

| 概念 | 比喻 |
|------|------|
| 硬件 Ring | 银行柜台窗口 |
| Scheduler | 这个窗口的叫号系统 |
| rq（按优先级） | VIP 区、普通区、低优先区 |
| Entity | 一个客户 |
| Job | 客户手里要办的一件业务 |
| credit | 柜台同时能处理的业务数上限 |

**叫号规则：**
1. 先看 VIP 区有没有人等，有就从 VIP 区叫
2. 同区多人时：FIFO 模式按"谁先到谁先办"，RR 模式轮流叫
3. 叫到一个客户，只办 **1 件业务**，办完重新排队
4. 柜台满了（credit 用完）→ 暂停叫号，等有人办完腾位置

---

## 十、总结

DRM GPU Scheduler 的核心设计：

1. **分层结构**：Scheduler → RQ（按优先级） → Entity（按进程） → Job（按提交顺序）
2. **两种 entity 间调度策略**：
   - FIFO（默认）：红黑树按时间排序，全局先到先服务
   - RR：链表轮转，机会均等
3. **entity 内部 job 始终 FIFO**：SPSC 无锁队列保证顺序
4. **硬件队列 1:1 对应 scheduler**：多 entity 复用一个硬件 ring
5. **credit 流控**：限制同时提交给硬件的 job 数量
6. **优先级抢占**：高优先级 rq 有活时，低优先级完全不被调度

---

*发布于 {{ page.date | date: "%Y年%m月%d日" }}*
