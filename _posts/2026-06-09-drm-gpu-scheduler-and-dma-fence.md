---
layout: post
title: "Linux DRM GPU 调度器与 dma_fence 机制详解"
date: 2026-06-09 14:00:00 +0800
excerpt: "深入分析 Linux 内核 DRM GPU 通用调度框架（drm_gpu_scheduler）的架构、调度策略、流控机制，以及 dma_fence 同步原语的完整工作原理。"
---

# Linux DRM GPU 调度器与 dma_fence 机制详解

## 第一部分：DRM GPU 调度器

### 1. 整体架构

```
用户空间 (Mesa/Vulkan driver)
    │
    │  ioctl 提交 GPU 命令
    ▼
┌─────────────────────────────────────────────────────────┐
│                DRM GPU Scheduler                         │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │        Scheduler Instance (per HW ring)          │  │
│  │                                                  │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌───────┐ │  │
│  │  │  RQ[0]  │ │  RQ[1]  │ │  RQ[2]  │ │ RQ[3] │ │  │
│  │  │ KERNEL  │ │  HIGH   │ │ NORMAL  │ │  LOW  │ │  │
│  │  │         │ │         │ │         │ │       │ │  │
│  │  │Entity A │ │Entity C │ │Entity E │ │       │ │  │
│  │  │Entity B │ │Entity D │ │Entity F │ │       │ │  │
│  │  └─────────┘ └─────────┘ └─────────┘ └───────┘ │  │
│  │                    │                             │  │
│  │          drm_sched_select_entity()               │  │
│  │                    │                             │  │
│  │                    ▼                             │  │
│  │          ┌──────────────────┐                   │  │
│  │          │  run_job()       │  → 硬件 fence     │  │
│  │          │  (驱动回调)       │                   │  │
│  │          └──────────────────┘                   │  │
│  │                    │                             │  │
│  │                    ▼                             │  │
│  │            pending_list                          │  │
│  │          (等待硬件完成)                            │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
    │
    ▼
  GPU Hardware Ring
```

### 2. 核心数据结构

#### 层次关系

```
drm_gpu_scheduler (每个硬件 ring 一个)
    │
    ├── sched_rq[0] (KERNEL 优先级)
    │       ├── entity A → job_queue: [job1, job2, ...]
    │       └── entity B → job_queue: [job3, ...]
    │
    ├── sched_rq[1] (HIGH 优先级)
    │       └── entity C → job_queue: [job4, ...]
    │
    ├── sched_rq[2] (NORMAL 优先级)
    │       ├── entity D → job_queue: [job5, job6, ...]
    │       └── entity E → job_queue: [job7, ...]
    │
    └── sched_rq[3] (LOW 优先级)
            └── entity F → job_queue: [job8, ...]
```

#### drm_gpu_scheduler — 调度器实例

```c
struct drm_gpu_scheduler {
    const struct drm_sched_backend_ops *ops;  // 驱动回调
    u32                 credit_limit;         // 流控：最大 credit 数
    atomic_t            credit_count;         // 当前已消耗的 credit
    long                timeout;              // job 超时时间
    u32                 num_rqs;              // run queue 数量（≤4）
    struct drm_sched_rq **sched_rq;          // 按优先级排列的 run queue
    struct list_head    pending_list;         // 已提交到 HW 的 job
    struct work_struct  work_run_job;         // 提交 job 的 worker
    struct work_struct  work_free_job;        // 释放 job 的 worker
    struct delayed_work work_tdr;             // 超时检测 (TDR)
    atomic_t            *score;               // 负载分数（负载均衡）
};
```

#### drm_sched_rq — 运行队列

```c
struct drm_sched_rq {
    struct drm_gpu_scheduler *sched;
    spinlock_t              lock;
    struct drm_sched_entity *current_entity;   // RR 策略的当前 entity
    struct list_head        entities;           // entity 链表
    struct rb_root_cached   rb_tree_root;       // FIFO 策略的红黑树
};
```

#### drm_sched_entity — 调度实体

```c
struct drm_sched_entity {
    struct list_head        list;              // 挂在 rq 的 entities 链表
    struct drm_sched_rq    *rq;               // 所属的 run queue
    enum drm_sched_priority priority;          // 优先级
    struct spsc_queue       job_queue;          // 待调度 job 队列 (SPSC)
    struct dma_fence       *dependency;         // 当前 job 的依赖 fence
    struct dma_fence __rcu *last_scheduled;     // 上次调度的 fence
    ktime_t                oldest_job_waiting;  // FIFO 红黑树排序 key
    struct rb_node         rb_tree_node;        // FIFO 红黑树节点

    // 负载均衡：一个 entity 可在多个 scheduler 之间迁移
    struct drm_gpu_scheduler **sched_list;
    unsigned int           num_sched_list;
};
```

#### drm_sched_job — 调度任务

```c
struct drm_sched_job {
    ktime_t                 submit_ts;         // 入队时间
    struct drm_gpu_scheduler *sched;           // 所属调度器
    struct drm_sched_fence *s_fence;           // 调度 fence
    struct drm_sched_entity *entity;           // 所属 entity
    enum drm_sched_priority s_priority;        // 优先级
    u32                     credits;           // 消耗的 credit 数
    atomic_t                karma;             // 超时累计
    struct xarray           dependencies;      // 依赖的 dma_fence 列表
};
```

### 3. 优先级

```c
enum drm_sched_priority {
    DRM_SCHED_PRIORITY_KERNEL,   // 最高
    DRM_SCHED_PRIORITY_HIGH,
    DRM_SCHED_PRIORITY_NORMAL,
    DRM_SCHED_PRIORITY_LOW,      // 最低
};
```

| 优先级 | 用途 | 典型场景 |
|--------|------|----------|
| **KERNEL** | 内核态紧急任务 | 页表更新、GPU context 切换、VRAM↔GTT 内存迁移 |
| **HIGH** | 高优先级用户任务 | VR/AR 合成器、视频解码关键帧、显式提权的 context |
| **NORMAL** | 普通用户任务（默认） | 3D 渲染、OpenCL/Vulkan compute、桌面合成 |
| **LOW** | 后台低优先级任务 | 后台 GPGPU 计算、shader 预编译 |

调度行为——严格优先级：

```
KERNEL 有活？→ 干 KERNEL 的
    没有 → HIGH 有活？→ 干 HIGH 的
              没有 → NORMAL 有活？→ 干 NORMAL 的
                        没有 → LOW 有活？→ 干 LOW 的
```

高优先级持续有 job 时，低优先级会被饿死。通过 credit 流控间接缓解。

### 4. 调度策略

通过模块参数 `drm_sched_policy` 控制（默认 FIFO）：

#### Round Robin (RR)

```c
drm_sched_rq_select_entity_rr(sched, rq) {
    // 从 current_entity 下一个开始遍历
    // 找到第一个 ready 的 entity
    // 更新 current_entity
}
```

- 每个 entity 轮流被选中
- 公平性好

#### FIFO

```c
drm_sched_rq_select_entity_fifo(sched, rq) {
    // 红黑树按 oldest_job_waiting 排序
    // 选等待最久的 entity
}
```

- 先到先服务
- 低延迟

### 5. 流控机制 (Credit-based)

```
                    credit_limit (如 32)
    ┌──────────────────────────────────────┐
    │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░│
    │  credit_count (已用)    (剩余可用)    │
    └──────────────────────────────────────┘
```

- 每个 job 有 `credits` 值（GPU 负载权重）
- 提交时 `credit_count += job->credits`
- 完成时 `credit_count -= job->credits`
- 超 limit 则暂停，等已有 job 完成后再继续

```c
drm_sched_can_queue(sched, entity) {
    job = queue_peek(entity);
    return available_credits(sched) >= job->credits;
}
```

### 6. 负载均衡

```c
drm_sched_pick_best(sched_list, num_sched_list) {
    // 选 score 最小的 scheduler
    for each sched:
        if sched->score < min_score:
            picked = sched;
}
```

- `score` = 活跃 entity 数
- Entity 提交新 job 时可迁移到最空闲的 scheduler
- 在 `drm_sched_entity_select_rq()` 触发

### 7. 超时检测与恢复 (TDR)

```c
drm_sched_job_timedout() {
    job = pending_list 第一个;
    status = ops->timedout_job(job);  // 驱动 GPU reset

    if (status == NO_HANG)
        reinsert_job();  // 误报
}
```

Hardware Scheduler 恢复流程：

```
1. drm_sched_stop()       — 停止所有受影响的调度器
2. kill guilty entity     — 干掉出问题的 entity
3. GPU reset              — 驱动执行硬件复位
4. re-submit jobs         — 重新提交 pending job
5. drm_sched_start()      — 重启调度器
```

Karma 机制：job 每次导致超时 `karma++`，超过 `hang_limit` 标记为 guilty，不再调度。

### 8. 驱动回调接口

```c
struct drm_sched_backend_ops {
    prepare_job();    // 额外依赖检查（可选）
    run_job();        // 提交 job 到 HW，返回硬件 fence
    timedout_job();   // 超时处理，GPU reset
    free_job();       // 释放 job 资源
    cancel_job();     // 调度器销毁时取消未执行 job
};
```

### 9. 完整调度循环

```c
drm_sched_run_job_work() {
    // 1. 选 entity（按优先级+策略）
    entity = drm_sched_select_entity(sched);

    // 2. 弹出 job
    job = drm_sched_entity_pop_job(entity);

    // 3. 计入 credit
    atomic_add(job->credits, &sched->credit_count);

    // 4. 加入 pending list + 启动超时计时
    drm_sched_job_begin(job);

    // 5. 驱动提交到硬件
    fence = sched->ops->run_job(job);

    // 6. signal scheduled fence
    drm_sched_fence_scheduled(s_fence, fence);

    // 7. 注册完成回调
    dma_fence_add_callback(fence, drm_sched_job_done_cb);

    // 8. 继续调度下一个
    drm_sched_run_job_queue(sched);
}
```

### 10. 使用此框架的驱动

| 驱动 | GPU |
|------|-----|
| amdgpu | AMD Radeon/RDNA |
| nouveau | NVIDIA (开源) |
| panfrost | ARM Mali (Midgard/Bifrost) |
| lima | ARM Mali (Utgard) |
| etnaviv | Vivante |
| v3d | Broadcom VideoCore |
| msm | Qualcomm Adreno |
| xe | Intel Xe |

---

## 第二部分：DRM Scheduler Fence 机制

### 1. 为什么需要 Fence

GPU 异步执行——CPU 提交命令后立即返回。Fence 是"事件完成信号"：unsignaled → signaled，单向不可逆。

### 2. Scheduler 中的 Fence 结构

每个 job 有一个 `drm_sched_fence`，包含两个 fence：

```c
struct drm_sched_fence {
    struct dma_fence scheduled;   // "job 已提交到硬件"
    struct dma_fence finished;    // "job 已执行完毕"
    struct dma_fence *parent;     // run_job() 返回的硬件 fence
    ktime_t          deadline;    // deadline hint
};
```

### 3. 三个 Fence 的关系

```
用户提交 job
    │
    ▼
[scheduled fence]  ←── job 被选中提交到 GPU HW ring 时 signal
    │
    │  GPU 正在执行...
    ▼
[parent fence]     ←── GPU 真正完成时 signal（由 run_job() 返回）
    │
    │  parent signal 触发 scheduler 回调
    ▼
[finished fence]   ←── scheduler 收到后 signal（对外暴露的最终 fence）
```

| fence | 用途 |
|-------|------|
| **scheduled** | 让后续 job 可以 pipeline（不必等前一个完全执行完） |
| **parent** | 真实硬件完成信号，driver-specific |
| **finished** | 对外统一完成接口，用于 dma_resv、syncobj、用户态同步 |

### 4. Pipeline 优化

```
Entity A:  job1 → job2
Entity B:  jobX (依赖 job1)
```

- 无 pipeline：jobX 等 job1 的 **finished**（GPU 完全执行完）
- 有 pipeline：jobX 只等 job1 的 **scheduled**（已进 HW 队列即可）

HW ring 保证 FIFO，所以 job1 一定在 jobX 之前执行。大幅减少 CPU 往返延迟。

### 5. 依赖处理

```c
// 添加依赖
drm_sched_job_add_dependency(job, fence);
drm_sched_job_add_implicit_dependencies(job, gem_obj, write);

// 调度时检查
drm_sched_entity_is_ready(entity) {
    if (!queue_count)     return false;  // 没 job
    if (entity->dependency) return false;  // 有未满足依赖
    return true;
}
```

依赖 fence signal 时唤醒 scheduler 重新调度。

### 6. Fence 完整生命周期

```
drm_sched_job_init()     → 分配 s_fence
drm_sched_job_arm()      → 初始化 scheduled/finished fence，分配 seqno
entity_push_job()        → 入队，唤醒 scheduler
    ↓ (scheduler worker)
run_job_work()           → select → pop → run_job() → signal scheduled
                                                        → 注册 parent callback
    ↓ (GPU 完成，parent signal)
job_done_cb()            → credit_count -= credits
                         → signal finished fence
                         → 触发 free_job worker
```

---

## 第三部分：dma_fence 原语详解

### 1. 结构定义（mainline 最新）

```c
struct dma_fence {
    union {
        spinlock_t *extern_lock;   // 外部锁（传统）
        spinlock_t inline_lock;    // 内联锁（推荐）
    };
    const struct dma_fence_ops __rcu *ops;

    union {
        struct list_head cb_list;   // signal 前：回调链表
        ktime_t timestamp;          // signal 后：完成时间戳
        struct rcu_head rcu;        // release 后：RCU 释放
    };
    u64 context;
    u64 seqno;
    unsigned long flags;
    struct kref refcount;
    int error;
};
```

注意 `cb_list` / `timestamp` / `rcu` 是 **union**，三者分时复用同一块内存。

### 2. 各字段详解

#### lock（spinlock）

保护 fence 状态转换和 cb_list 并发访问。

```c
// signal 时持锁
dma_fence_signal_timestamp_locked(fence, timestamp) {
    test_and_set_bit(SIGNALED_BIT, &fence->flags);
    list_replace(&fence->cb_list, &cb_list);  // 摘走回调
    fence->timestamp = timestamp;
    // 调用所有回调
    list_for_each_entry_safe(cur, tmp, &cb_list, node)
        cur->func(fence, cur);
}

// add_callback 时也要持锁
dma_fence_add_callback(fence, cb, func) {
    spin_lock(fence->lock);
    if (已 signal) return -ENOENT;
    list_add_tail(&cb->node, &fence->cb_list);
    spin_unlock(fence->lock);
}
```

两种模式：
- `inline_lock`：`dma_fence_init(fence, ops, NULL, ctx, seq)` → fence 自带锁
- `extern_lock`：`dma_fence_init(fence, ops, &lock, ctx, seq)` → 多 fence 共享锁

#### context

标识 fence 所属的"时间线"（执行序列）。

```c
u64 ctx = dma_fence_context_alloc(1);  // 全局唯一 ID
```

规则：
- 同一 context 内 seqno 必须单调递增
- 只有同一 context 的 fence 才能比较先后
- 典型：一个 GPU ring → 一个 context；一个 entity → 2 个 context

用途——依赖去重：
```c
// 同 context 只保留最新的 fence
xa_for_each(&job->dependencies, index, entry) {
    if (entry->context == fence->context) {
        if (dma_fence_is_later(fence, entry))
            xa_store(..., fence);  // 替换
        return;
    }
}
```

#### seqno

同一 context 时间线上的序号，判断先后顺序。

```c
// 每新建 fence，seqno +1
seqno = atomic_inc_return(&entity->fence_seq);
dma_fence_init(fence, ops, lock, context, seqno);

// 比较
dma_fence_is_later(f1, f2) {
    WARN_ON(f1->context != f2->context);
    return f1->seqno > f2->seqno;
}
```

意义：GPU ring 顺序执行，seqno=5 完成 → seqno≤5 都完成，无需逐个等待。

#### flags

原子位标志：

| Flag | 含义 | 设置时机 |
|------|------|----------|
| `INITIALIZED_BIT` | 已初始化 | `dma_fence_init()` |
| `INLINE_LOCK_BIT` | 使用内联锁 | init 时 lock=NULL |
| `SIGNALED_BIT` | 已完成（核心位）| `dma_fence_signal()` |
| `TIMESTAMP_BIT` | timestamp 已写入 | signal 之后 |
| `ENABLE_SIGNAL_BIT` | 已调用 enable_signaling | 首次 add_callback |
| `USER_BITS` | 驱动自定义起始 | 驱动设置 |

关键使用：
```c
// 检查完成
dma_fence_is_signaled(fence) {
    return test_bit(SIGNALED_BIT, &fence->flags);
}

// signal（只成功一次，幂等）
test_and_set_bit(SIGNALED_BIT, &fence->flags);
```

#### cb_list / timestamp（union 分时复用）

**signal 前** — cb_list 存回调：
```c
dma_fence_add_callback(fence, &cb, func);
// cb 挂到 fence->cb_list 链表
```

**signal 时** — 转换：
```c
list_replace(&fence->cb_list, &tmp_list);  // 摘走
fence->timestamp = ktime_get();            // 覆写同一块内存
set_bit(TIMESTAMP_BIT, &fence->flags);
// 调用 tmp_list 中所有回调
```

**signal 后** — timestamp 可读：
```c
ktime_t ts = dma_fence_timestamp(fence);
```

**release 后** — rcu 用于安全释放。

#### error

记录执行错误（必须在 signal 前设置）：

```c
// GPU hang
dma_fence_set_error(fence, -ECANCELED);
dma_fence_signal(fence);

// 等待者检查
dma_fence_wait(fence, true);
if (fence->error) handle_error();
```

Scheduler 中传播：parent fence 的 error 传给 finished fence。

### 3. dma_fence 完整生命周期

```
dma_fence_init(ctx=X, seq=N)
│  flags = INITIALIZED
│  cb_list = 空
│  error = 0
│
├─ add_callback(cb1)    → cb_list: [cb1]
├─ add_callback(cb2)    → cb_list: [cb1, cb2]
│
├─ set_error(-EIO)      → error = -EIO（可选）
│
├─ dma_fence_signal()
│    flags |= SIGNALED | TIMESTAMP
│    timestamp = now     ← 覆写 cb_list 内存
│    调用 cb1->func(), cb2->func()
│
├─ is_signaled() → true
├─ timestamp()   → signal 时刻
│
└─ dma_fence_put() → refcount=0
     rcu 释放       ← 覆写 timestamp 内存
```

### 4. 与用户态的交互

#### dma_resv (Reservation Object)

每个 GEM BO 绑定一个 dma_resv，存所有使用该 BO 的 fence：

```
GEM Buffer Object
    └── dma_resv
            ├── write fence: job3.finished
            └── read fences: [job1.finished, job2.finished]
```

新 job 用该 BO 时自动添加依赖（隐式同步）。

#### DRM Syncobj

用户态显式同步原语：

```
Vulkan:
    vkQueueSubmit(signal: syncobj_A)   → syncobj_A->fence = job1.finished
    vkQueueSubmit(wait: syncobj_A)     → job2 依赖 syncobj_A->fence
```

### 5. 多 Job 多 Entity Fence 流图

```
Entity A (context=100/101):
  job1: scheduled(ctx=100,seq=1) → finished(ctx=101,seq=1)
  job2: scheduled(ctx=100,seq=2) → finished(ctx=101,seq=2)

Entity B (context=200/201):
  job3: scheduled(ctx=200,seq=1) → finished(ctx=201,seq=1) [依赖 job1.finished]

时间线:
────────────────────────────────────────────────────────►

job1 push → scheduled✓ → finished✓
                │              │
                │              └──→ job3 依赖满足 → scheduled✓ → finished✓
                │
                └──→ job2 pipeline（只等 scheduled）→ scheduled✓ → finished✓
```

---

## 总结

| 概念 | 作用 |
|------|------|
| `drm_gpu_scheduler` | 每个 HW ring 一个，管理 job 调度 |
| `drm_sched_rq` | 按优先级分组的 entity 队列 |
| `drm_sched_entity` | 用户 context 的抽象，维护 job 队列 |
| `drm_sched_job` | 一次 GPU 提交 |
| `scheduled` fence | 标记已进 HW 队列，启用 pipeline |
| `finished` fence | 标记完全完成，对外暴露 |
| `parent` fence | 驱动的硬件完成信号 |
| `dma_fence.context` | 时间线标识，用于排序和去重 |
| `dma_fence.seqno` | 时间线内序号，判断先后 |
| `dma_fence.cb_list` | signal 前的异步回调链表 |
| `dma_fence.timestamp` | signal 后的完成时刻 |
| `dma_fence.error` | 执行错误码 |
| `credit` | 流控，限制同时在 HW 的 job 数 |
| `score` | 负载均衡分数 |
| `karma` | 超时累计，超限判 guilty |
