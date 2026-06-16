---
layout: post
title: "Linux DRM GPU 调度器与 dma_fence 机制深度源码分析"
date: 2026-06-09 14:00:00 +0800
excerpt: "用故事串起 GPU 调度器全流程：job 提交→优先级选择→依赖检查→提交硬件→完成通知→超时恢复。结合 etnaviv/panfrost 源码分析优先级设置。"
---

# Linux DRM GPU 调度器与 dma_fence

源码：`drivers/gpu/drm/scheduler/sched_main.c`

---

## 一、GPU 调度器在干什么？

**多个应用同时想用 GPU，调度器决定谁先上，谁等着。**

```
游戏 A 的 entity (队列):     [渲染帧1] → [渲染帧2] → [渲染帧3]
视频 B 的 entity (队列):     [编码片段1] → [编码片段2]
桌面合成器的 entity:          [合成帧1] → [合成帧2]

调度器从这些队列中，按优先级+轮转，一个一个取 job 交给 GPU 执行
```

---

## 二、完整流程 — 用故事讲

### 第一步：应用提交 job（入队，GPU 还没干活）

```
用户空间: Mesa/Vulkan → ioctl(SUBMIT) → 内核驱动:

drm_sched_job_init(job, entity_A, credits)   // "这个 job 属于应用 A"
drm_sched_job_arm(job)                       // 给 job 编号，创建 scheduled_fence
drm_sched_entity_push_job(job)               // 放入 entity_A 的队列尾部
    → queue_work(sched->work_run_job)        // 唤醒调度器："有新活了"
```

此时 job 只是**排队了**，GPU 还没开始。

### 第二步：调度器选择谁先执行

```c
// sched_main.c: drm_sched_run_job_work() — workqueue 线程中执行
static void drm_sched_run_job_work(struct work_struct *w)
{
    // ★ 选一个 entity
    entity = drm_sched_select_entity(sched);
    ...
}

// drm_sched_select_entity():
static struct drm_sched_entity *drm_sched_select_entity(sched)
{
    // 从最高优先级往下扫
    for (i = DRM_SCHED_PRIORITY_KERNEL; i < sched->num_rqs; i++) {
        entity = (FIFO策略 ? select_entity_fifo : select_entity_rr)
                 (sched, sched->sched_rq[i]);
        if (entity)
            break;  // 高优先级有活就不看低优先级
    }
    return entity;
}
```

**选择逻辑：**
```
优先级从高到低扫描:
  KERNEL (最高) → 有 entity 有 job？→ 选它
  HIGH          → 有 entity 有 job？→ 选它
  NORMAL        → 有 entity 有 job？→ 选它
  LOW (最低)    → 有 entity 有 job？→ 选它

同优先级内: Round-Robin 轮转各 entity（公平）
```

### 第三步：从 entity 取出 job，检查依赖

```c
sched_job = drm_sched_entity_pop_job(entity);
// 内部会检查 job 的 dependency fence:
//   如果有未 signal 的依赖 → 不取出，等下次
//   所有依赖都 signal 了 → 取出，可以提交
```

**依赖是什么？** 比如："渲染帧2 必须等渲染帧1 完成才能开始"——帧1 的 finished_fence 就是帧2 的依赖。

### 第四步：提交到 GPU 硬件

```c
// sched_main.c: drm_sched_run_job_work() 继续:

    // 扣 credit（流控：不能一次塞太多 job 给 GPU）
    atomic_add(sched_job->credits, &sched->credit_count);

    // 加入 pending_list（"已交给 GPU，等它做完"）
    drm_sched_job_begin(sched_job);
    //  → list_add_tail(&job->list, &sched->pending_list);
    //  → 启动超时定时器

    // ★ 调用驱动的 run_job：把命令写入 GPU ring buffer
    fence = sched->ops->run_job(sched_job);
    // → 驱动: 写 GPU 寄存器，启动 DMA
    // → 返回 hw_fence（GPU 完成时会 signal）

    // 在 hw_fence 上注册回调
    dma_fence_add_callback(fence, &sched_job->cb, drm_sched_job_done_cb);
    // → GPU 完成时触发 drm_sched_job_done_cb

    // 通知 scheduled_fence："job 已经被调度执行了"
    drm_sched_fence_scheduled(s_fence, fence);

    // 继续调度下一个 job
    drm_sched_run_job_queue(sched);
```

### 第五步：GPU 执行完成

```
GPU 干完活 → 发中断 → 驱动 ISR:
    dma_fence_signal(hw_fence)
        │
        ▼
    drm_sched_job_done_cb() 被触发:
        → drm_sched_job_done(job)
            ├── 从 pending_list 移除
            ├── 减 credit_count（腾出位置给新 job）
            ├── signal finished_fence（通知用户空间"结果可用了"）
            └── queue work_free_job

    work_free_job:
        → sched->ops->free_job(job)  // 驱动释放资源
        → drm_sched_run_job_queue()  // 继续调度下一个
```

### 第六步：超时处理（GPU 卡死了）

```
pending_list 上的 job 超时（默认几秒）:
    → drm_sched_job_timedout() 触发
        → sched->ops->timedout_job(job)
            驱动: 复位 GPU，标记 job 失败
            返回 RESET 或 NO_RESTART
```

---

## 三、优先级怎么设置 — 各驱动的实现

### 3.1 优先级定义

```c
// include/drm/gpu_scheduler.h
enum drm_sched_priority {
    DRM_SCHED_PRIORITY_KERNEL = 0,  // 最高：内核内部用（如 display flip）
    DRM_SCHED_PRIORITY_HIGH,        // 高：需要特权
    DRM_SCHED_PRIORITY_NORMAL,      // 普通：默认
    DRM_SCHED_PRIORITY_LOW,         // 低：后台任务
    DRM_SCHED_PRIORITY_COUNT
};
```

### 3.2 etnaviv (NXP Vivante GPU) — 写死 NORMAL

```c
// drivers/gpu/drm/etnaviv/etnaviv_drv.c
static int etnaviv_open(struct drm_device *dev, struct drm_file *file)
{
    for (i = 0; i < ETNA_MAX_PIPES; i++) {
        if (gpu) {
            sched = &gpu->sched;
            drm_sched_entity_init(&ctx->sched_entity[i],
                                  DRM_SCHED_PRIORITY_NORMAL,  // ← 写死！
                                  &sched, 1, NULL);
        }
    }
}
// 结果: 所有应用公平轮转，没有优先级区分
// 原因: 嵌入式场景简单，通常只有一两个 GPU 用户
```

### 3.3 panfrost (ARM Mali GPU) — 用户可选，HIGH 需要特权

```c
// drivers/gpu/drm/panfrost/panfrost_job.c

// 用户空间 ioctl 传入优先级:
int panfrost_jm_ctx_create(struct drm_file *file,
                           struct drm_panfrost_jm_ctx_create *args)
{
    // 用户请求的优先级 → 内核调度优先级
    ret = jm_ctx_prio_to_drm_sched_prio(file, args->priority, &sched_prio);

    // 创建 entity 时使用该优先级
    drm_sched_entity_init(&jm_ctx->slot_entity[i], sched_prio, &sched, 1, NULL);
}

// 映射规则:
static int jm_ctx_prio_to_drm_sched_prio(file, in, out)
{
    switch (in) {
    case PANFROST_JM_CTX_PRIORITY_LOW:
        *out = DRM_SCHED_PRIORITY_LOW;     // 任何人都可以
        return 0;
    case PANFROST_JM_CTX_PRIORITY_MEDIUM:
        *out = DRM_SCHED_PRIORITY_NORMAL;  // 任何人都可以（默认）
        return 0;
    case PANFROST_JM_CTX_PRIORITY_HIGH:
        if (!panfrost_high_prio_allowed(file))  // ← 检查权限！
            return -EACCES;                     //    需要 CAP_SYS_NICE
        *out = DRM_SCHED_PRIORITY_HIGH;
        return 0;
    }
}
```

### 3.4 总结对比

| 驱动 | 用户能设优先级？ | 默认 | HIGH 需要什么权限 |
|------|----------------|------|-------------------|
| etnaviv (NXP) | ❌ 不能 | NORMAL | — |
| panfrost (Mali) | ✅ 能 | NORMAL | CAP_SYS_NICE |
| amdgpu (AMD) | ✅ 能 | NORMAL | CAP_SYS_NICE |
| i915 (Intel) | ✅ 能 | NORMAL | 特权 + preemption |

---

## 四、Credit 流控 — 为什么不一次全提交

```c
// 每个 job 有 credits 值（通常=1）
// scheduler 有总 credit 上限 (hw_submission_limit)

提交时:  atomic_add(job->credits, &sched->credit_count);
完成时:  atomic_sub(job->credits, &sched->credit_count);

选 entity 时:
  if (credit_count + next_job->credits > credit_limit)
      → 暂不调度，等 GPU 完成释放 credit
```

**目的：** 防止 ring buffer 溢出，防止一个应用饿死其他应用。

---

## 五、dma_fence — 每个 job 的两个 fence

```
job 的生命周期有两个关键时刻:

  job 在队列等待...
         │
         ▼ 被调度器选中，提交给 GPU
  ★ scheduled_fence signal
     "你的 job 开始执行了"
         │
         ▼ GPU 执行完成
  ★ finished_fence signal
     "GPU 执行完了，结果可以用了"
```

### 用户空间怎么用

```c
// 提交时拿到 fence fd:
ioctl(gpu_fd, SUBMIT, &submit);  // → submit.out_fence_fd

// 等 GPU 完成:
poll(fence_fd, POLLIN, timeout);  // finished_fence signal 后可读

// 或传给 Display 做同步:
drmModeAtomicAddProperty(req, plane, "IN_FENCE_FD", fence_fd);
// → Display 等 GPU 完成后才翻页显示
```

---

## 六、完整时序

```
时间 ─────────────────────────────────────────────────────────────────▶

应用 A               调度器 (workqueue)           GPU 硬件
───────              ──────────────────           ────────

push_job(渲染帧1)
push_job(渲染帧2)
                     select_entity → A
                     pop_job → 渲染帧1
                     run_job(渲染帧1) ───────────→ 开始执行帧1
                     [帧1 进入 pending_list]

                     select_entity → B (轮转)
                     pop_job → 编码片段1
                     run_job(编码片段1) ──────────→ 开始执行片段1

                                                   帧1 完成! → IRQ
                     ←── hw_fence signal ────────
                     job_done(帧1): free, 释放credit

                     select_entity → A
                     pop_job → 渲染帧2
                     run_job(渲染帧2) ───────────→ 开始执行帧2
```

---

## 七、关键概念速查

| 概念 | 是什么 | 比喻 |
|------|--------|------|
| `drm_gpu_scheduler` | 一个 GPU 引擎的调度器 | 排号机 |
| `drm_sched_entity` | 一个应用的提交队列 | 一个顾客的号 |
| `drm_sched_job` | 一次 GPU 任务 | 一个业务单 |
| `sched_rq[priority]` | 优先级队列 | VIP/普通窗口 |
| `ops->run_job()` | 交给 GPU 硬件 | 柜员办理 |
| `hw_fence` | GPU 完成时 signal | 办完叫号 |
| `pending_list` | 已交给 GPU 的 job | 正在办理 |
| `credit_count` | 流控计数 | 窗口同时办理数上限 |

---

## 八、源文件索引

| 文件 | 内容 |
|------|------|
| `drivers/gpu/drm/scheduler/sched_main.c` | 主循环：select_entity, run_job_work, job_done |
| `drivers/gpu/drm/scheduler/sched_entity.c` | entity：push_job, pop_job, 依赖检查 |
| `drivers/gpu/drm/scheduler/sched_fence.c` | scheduled/finished fence |
| `include/drm/gpu_scheduler.h` | 所有结构体 |
| `drivers/gpu/drm/etnaviv/etnaviv_sched.c` | etnaviv run_job/free_job |
| `drivers/gpu/drm/panfrost/panfrost_job.c` | panfrost 优先级 + 调度 |
| `include/linux/dma-fence.h` | dma_fence API |
