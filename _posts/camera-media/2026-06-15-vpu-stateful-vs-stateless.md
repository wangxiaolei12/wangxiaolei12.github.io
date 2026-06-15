---
layout: post
title: "Linux VPU 驱动架构：Stateful vs Stateless 深度对比分析"
date: 2026-06-15 11:00:00 +0800
excerpt: "结合 Linux mainline 中的 CODA (Stateful) 和 Hantro (Stateless) VPU 驱动源码，全面分析两种视频编解码驱动架构的设计差异、数据流、V4L2 M2M 框架使用方式。"
---

# Linux VPU 驱动架构：Stateful vs Stateless 深度对比分析

源码路径：
- Stateful: `drivers/media/platform/chips-media/coda/`
- Stateless: `drivers/media/platform/verisilicon/`

---

## 1. 核心概念：什么是 Stateful 和 Stateless

### 1.1 根本区别

| | Stateful（有状态） | Stateless（无状态） |
|---|---|---|
| **代表硬件** | CODA (Chips&Media), MFC (Samsung) | Hantro/VC8000D (Verisilicon), Cedrus |
| **固件** | VPU 内部有固件运行 | 纯硬件，无固件 |
| **解码状态管理** | 固件管理（参考帧、DPB 等） | 用户空间管理（通过 controls 传入） |
| **驱动复杂度** | 驱动相对简单（固件干活） | 驱动+用户空间复杂（状态在外部） |
| **V4L2 接口** | 标准 M2M（OUTPUT→CAPTURE） | Request API + Stateless Controls |

### 1.2 架构对比图

**Stateful（CODA）**：

```
┌──────────────────────────────────────────────────────────┐
│ 用户空间 (GStreamer/FFmpeg)                                │
│                                                          │
│  输入: H.264 NAL units (压缩数据)                         │
│  输出: YUV 帧 (解码后)                                    │
│                                                          │
│  只需要: QBUF 压缩数据, DQBUF 解码帧                      │
│  不需要关心: 参考帧管理、DPB、帧重排序                      │
└──────────────────────────┬───────────────────────────────┘
                           │ ioctl (QBUF/DQBUF)
                           ▼
┌──────────────────────────────────────────────────────────┐
│ 内核驱动 (coda-common.c)                                  │
│                                                          │
│  V4L2 M2M framework                                     │
│  ├── OUTPUT queue: 压缩码流 (bitstream)                   │
│  └── CAPTURE queue: 解码帧 (YUV)                         │
│                                                          │
│  驱动维护:                                                │
│  - bitstream FIFO (ring buffer)                          │
│  - 序列初始化 (seq_init)                                  │
│  - 内部帧缓冲分配                                         │
└──────────────────────────┬───────────────────────────────┘
                           │ 寄存器/命令
                           ▼
┌──────────────────────────────────────────────────────────┐
│ VPU 硬件 + 固件                                           │
│                                                          │
│  固件自主管理:                                             │
│  - 参考帧列表 (DPB)                                       │
│  - 帧重排序 (B帧)                                         │
│  - 比特流解析                                             │
│  - 运动补偿                                               │
└──────────────────────────────────────────────────────────┘
```

**Stateless（Hantro）**：

```
┌──────────────────────────────────────────────────────────┐
│ 用户空间 (GStreamer/FFmpeg + libva/v4l2-stateless)        │
│                                                          │
│  输入: 一个 slice/frame 的压缩数据                         │
│      + 解码参数 (SPS/PPS/slice header)                    │
│      + 参考帧列表 (时间戳引用)                             │
│  输出: 一帧解码后的 YUV                                   │
│                                                          │
│  用户空间负责:                                             │
│  - 比特流解析 (找到 NAL, 提取 SPS/PPS)                    │
│  - 参考帧管理 (DPB)                                       │
│  - 帧重排序                                               │
└──────────────────────────┬───────────────────────────────┘
                           │ Request API + Controls
                           ▼
┌──────────────────────────────────────────────────────────┐
│ 内核驱动 (hantro_drv.c)                                   │
│                                                          │
│  V4L2 M2M + Request API                                  │
│  ├── OUTPUT queue: 压缩数据 (supports_requests = true)    │
│  ├── CAPTURE queue: 解码帧                                │
│  └── Stateless Controls:                                 │
│       V4L2_CID_STATELESS_H264_SPS                        │
│       V4L2_CID_STATELESS_H264_PPS                        │
│       V4L2_CID_STATELESS_H264_DECODE_PARAMS              │
│                                                          │
│  驱动只做: 配置寄存器 → 启动硬件 → 等中断                  │
└──────────────────────────┬───────────────────────────────┘
                           │ 寄存器写入
                           ▼
┌──────────────────────────────────────────────────────────┐
│ VPU 硬件（纯逻辑，无固件）                                 │
│                                                          │
│  硬件做:                                                  │
│  - 熵解码 (CAVLC/CABAC)                                  │
│  - 逆变换 + 逆量化                                        │
│  - 运动补偿 (根据外部传入的参考帧地址)                      │
│  - 环路滤波                                               │
└──────────────────────────────────────────────────────────┘
```

---

## 2. V4L2 M2M 框架基础

两种驱动都基于 V4L2 Memory-to-Memory (M2M) 框架：

```
┌────────────┐     ┌─────────────────┐     ┌─────────────┐
│ OUTPUT      │     │   M2M Device    │     │ CAPTURE     │
│ (src) queue │────→│   device_run()  │────→│ (dst) queue │
│             │     │   job_ready()   │     │             │
│ 压缩数据    │     │   job_abort()   │     │ 解码后 YUV  │
└────────────┘     └─────────────────┘     └─────────────┘
```

核心回调：

```c
struct v4l2_m2m_ops {
    void (*device_run)(void *priv);    // 启动一次硬件处理
    int  (*job_ready)(void *priv);     // 判断是否满足运行条件
    void (*job_abort)(void *priv);     // 中止当前任务
};
```

---

## 3. CODA 驱动分析（Stateful）

### 3.1 硬件特点

CODA (Chips&Media) 是一个带固件的多标准编解码 IP，用在 NXP i.MX 系列（i.MX6）上：
- 内部有 ARM 核运行固件
- 支持 H.264/MPEG-4/MPEG-2/JPEG 编解码
- 固件管理 DPB、参考帧、bitstream 解析
- 驱动通过命令寄存器与固件交互

### 3.2 M2M Ops

```c
// coda-common.c
static const struct v4l2_m2m_ops coda_m2m_ops = {
    .device_run = coda_device_run,
    .job_ready  = coda_job_ready,
    .job_abort  = coda_job_abort,
};
```

### 3.3 device_run — 启动一帧解码

```c
static void coda_device_run(void *m2m_priv)
{
    struct coda_ctx *ctx = m2m_priv;
    struct coda_dev *dev = ctx->dev;

    // 异步执行：放到工作队列
    queue_work(dev->workqueue, &ctx->pic_run_work);
}

static void coda_pic_run_work(struct work_struct *work)
{
    struct coda_ctx *ctx = container_of(work, ...);

    mutex_lock(&ctx->buffer_mutex);
    mutex_lock(&dev->coda_mutex);    // 硬件互斥（多实例共享）

    // 1. 准备运行（填充码流到 bitstream FIFO，配置参数）
    ctx->ops->prepare_run(ctx);

    // 2. 等待硬件完成（固件处理完会触发中断 → complete）
    if (!wait_for_completion_timeout(&ctx->completion, 1000ms)) {
        // 超时 → 硬件复位
        coda_hw_reset(ctx);
        ctx->ops->run_timeout(ctx);
    } else {
        // 正常完成
        ctx->ops->finish_run(ctx);
    }

    mutex_unlock(&dev->coda_mutex);
    mutex_unlock(&ctx->buffer_mutex);

    // 3. 通知 M2M 框架任务完成
    v4l2_m2m_job_finish(ctx->dev->m2m_dev, ctx->fh.m2m_ctx);
}
```

### 3.4 job_ready — 复杂的就绪判断

Stateful 驱动的 job_ready 很复杂，因为固件有内部状态：

```c
static int coda_job_ready(void *m2m_priv)
{
    struct coda_ctx *ctx = m2m_priv;
    int src_bufs = v4l2_m2m_num_src_bufs_ready(ctx->fh.m2m_ctx);

    // 编码器：需要源帧
    if (!src_bufs && ctx->inst_type != CODA_INST_DECODER)
        return 0;

    // 需要目标缓冲
    if (!v4l2_m2m_num_dst_bufs_ready(ctx->fh.m2m_ctx))
        return 0;

    // 解码器特有逻辑：
    if (ctx->inst_type == CODA_INST_DECODER && ctx->use_bit) {
        // 检查内部帧缓冲是否用完
        count = hweight32(ctx->frm_dis_flg);
        if (count >= ctx->num_internal_frames - 1)
            return 0;  // 所有内部缓冲都在用

        // 检查 bitstream FIFO 是否有足够数据
        if (!stream_end && (num_metas + src_bufs) < 2)
            return 0;  // 需要至少2帧数据

        // 检查是否能读到完整 NAL
        if (!coda_bitstream_can_fetch_past(ctx, meta->end))
            return 0;
    }

    return 1;
}
```

### 3.5 Stateful 解码流程（全生命周期）

```
1. 打开设备 → 分配 context
2. S_FMT(OUTPUT) → 设置输入格式（H.264）
3. S_FMT(CAPTURE) → 设置输出格式（NV12）
4. REQBUFS → 分配缓冲区
5. STREAMON(OUTPUT) → 开始喂数据
6. QBUF(OUTPUT) → 喂压缩帧到 bitstream FIFO
   │
   ├── 固件做 SEQ_INIT（解析 SPS/PPS，确定分辨率）
   │   → 驱动收到事件 V4L2_EVENT_SOURCE_CHANGE
   │   → 用户空间重新协商 CAPTURE 格式/缓冲
   │
7. STREAMON(CAPTURE) → 开始收解码帧
8. 循环：
   │  QBUF(OUTPUT, 压缩数据)
   │  DQBUF(CAPTURE, YUV 帧)  ← 固件内部排序后输出
   │
9. STREAMOFF → 停止
```

**关键特征**：
- 用户空间不需要知道参考帧、DPB 大小
- 分辨率变化由固件检测并通知（SOURCE_CHANGE 事件）
- B 帧重排序在固件内部完成

---

## 4. Hantro 驱动分析（Stateless）

### 4.1 硬件特点

Hantro (Verisilicon) 是一个纯硬件解码 IP，无固件：
- G1: H.264/VP8/MPEG-2/JPEG 解码
- G2: HEVC/VP9 解码
- H1: JPEG/H.264 编码
- 用在 NXP i.MX8M, Rockchip, STM32MP25 等

### 4.2 M2M Ops（极简）

```c
// hantro_drv.c
static const struct v4l2_m2m_ops vpu_m2m_ops = {
    .device_run = device_run,
    // 没有 job_ready！默认检查 src+dst buffer 各至少一个即可
};
```

没有 `job_ready` 回调——因为 stateless 不需要复杂的状态判断，有 buffer 就能跑。

### 4.3 device_run — 直接操作硬件

```c
static void device_run(void *priv)
{
    struct hantro_ctx *ctx = priv;

    src = hantro_get_src_buf(ctx);
    dst = hantro_get_dst_buf(ctx);

    // Runtime PM 唤醒
    pm_runtime_resume_and_get(ctx->dev->dev);
    clk_bulk_enable(ctx->dev->variant->num_clocks, ctx->dev->clocks);

    // 拷贝 buffer 元数据（时间戳等）
    v4l2_m2m_buf_copy_metadata(src, dst);

    // 调用 codec-specific 的运行函数（配置寄存器 → 启动）
    ctx->codec_ops->run(ctx);
    // 例如：hantro_g1_h264_dec_run(ctx)
    //   → 从 controls 读取 SPS/PPS/decode_params
    //   → 配置硬件寄存器（参考帧地址、slice 参数等）
    //   → 写 start 位启动硬件
}
```

### 4.4 Request API — Stateless 的核心

```c
// 队列初始化时启用 Request API
src_vq->supports_requests = true;
```

**用户空间使用方式**：

```c
// 1. 分配 request
int req_fd;
ioctl(media_fd, MEDIA_IOC_REQUEST_ALLOC, &req_fd);

// 2. 关联 control 到 request
struct v4l2_ext_controls ctrls = { .request_fd = req_fd, ... };
// 设置 H264 SPS
ctrls.controls[0].id = V4L2_CID_STATELESS_H264_SPS;
ctrls.controls[0].ptr = &sps;
ioctl(vpu_fd, VIDIOC_S_EXT_CTRLS, &ctrls);
// 设置 H264 PPS
ctrls.controls[1].id = V4L2_CID_STATELESS_H264_PPS;
// 设置 H264 decode params（包含参考帧列表）
ctrls.controls[2].id = V4L2_CID_STATELESS_H264_DECODE_PARAMS;

// 3. QBUF 时关联 request
struct v4l2_buffer buf = { .request_fd = req_fd, ... };
ioctl(vpu_fd, VIDIOC_QBUF, &buf);

// 4. 提交 request（触发 device_run）
ioctl(req_fd, MEDIA_REQUEST_IOC_QUEUE);
```

### 4.5 Stateless Controls

驱动处理 controls 来获取解码参数：

```c
// hantro_drv.c
static int hantro_try_ctrl(struct v4l2_ctrl *ctrl)
{
    if (ctrl->id == V4L2_CID_STATELESS_H264_SPS) {
        const struct v4l2_ctrl_h264_sps *sps = ctrl->p_new.p_h264_sps;
        // 验证硬件支持的参数范围
        if (sps->pic_width_in_mbs_minus1 > 255 ||
            sps->pic_height_in_map_units_minus1 > 255)
            return -EINVAL;
    }
    ...
}
```

在 `run()` 中读取 controls：

```c
// hantro_g1_h264_dec.c (示意)
static int hantro_g1_h264_dec_run(struct hantro_ctx *ctx)
{
    // 从 request 中获取参数
    const struct v4l2_ctrl_h264_sps *sps =
        hantro_get_ctrl(ctx, V4L2_CID_STATELESS_H264_SPS);
    const struct v4l2_ctrl_h264_pps *pps =
        hantro_get_ctrl(ctx, V4L2_CID_STATELESS_H264_PPS);
    const struct v4l2_ctrl_h264_decode_params *dec =
        hantro_get_ctrl(ctx, V4L2_CID_STATELESS_H264_DECODE_PARAMS);

    // 配置寄存器
    hantro_reg_write(vpu, &g1_regs.pic_width, sps->pic_width_in_mbs_minus1 + 1);
    hantro_reg_write(vpu, &g1_regs.pic_height, sps->pic_height_in_map_units_minus1 + 1);

    // 设置参考帧地址（用户空间通过时间戳指定）
    for (i = 0; i < 16; i++) {
        ref_ts = dec->dpb[i].timestamp;
        ref_addr = hantro_get_ref(ctx, ref_ts);  // 时间戳→DMA地址
        hantro_reg_write(vpu, &g1_regs.ref_addr[i], ref_addr);
    }

    // 启动硬件
    hantro_reg_write(vpu, &g1_regs.start, 1);
    return 0;
}
```

### 4.6 参考帧管理（用户空间负责）

```
用户空间维护 DPB (Decoded Picture Buffer):

解码帧 0: ts=1000, CAPTURE buf idx=0 → DPB[0]
解码帧 1: ts=2000, CAPTURE buf idx=1 → DPB[1]
解码帧 2: ts=3000, 参考帧=[ts=1000, ts=2000]
                          │
                          ▼
           V4L2_CID_STATELESS_H264_DECODE_PARAMS {
               .dpb[0] = { .timestamp = 1000 },  ← 引用帧0
               .dpb[1] = { .timestamp = 2000 },  ← 引用帧1
           }

内核驱动:
    ref_addr = hantro_get_ref(ctx, timestamp=1000)
    → vb2_find_buffer(capture_queue, ts=1000)
    → 返回对应 buffer 的 DMA 地址
    → 写入硬件参考帧寄存器
```

---

## 5. 关键差异总结

### 5.1 驱动代码复杂度

| 方面 | CODA (Stateful) | Hantro (Stateless) |
|------|-----------------|-------------------|
| `device_run` | 复杂（bitstream FIFO 管理、序列命令） | 简单（配寄存器、启动） |
| `job_ready` | 非常复杂（内部帧管理、bitstream 检查） | 不需要（默认就行） |
| 固件加载 | 需要（request_firmware） | 不需要 |
| 中断处理 | 复杂（多种命令完成事件） | 简单（解码完成中断） |
| 参考帧管理 | 驱动/固件内部 | 不管（用户空间传入地址） |
| SOURCE_CHANGE | 需要（分辨率可能变化） | 不需要（用户空间已知） |

### 5.2 用户空间复杂度

| 方面 | Stateful | Stateless |
|------|----------|-----------|
| 比特流解析 | 不需要（送原始码流即可） | 需要（提取参数） |
| 参考帧管理 | 不需要 | 需要（维护 DPB） |
| 帧重排序 | 不需要（固件内部） | 需要 |
| 错误恢复 | 简单（重置流） | 复杂（重建状态） |
| 延迟 | 较高（固件缓冲） | 较低（逐帧控制） |

### 5.3 数据流对比

```
Stateful:
    APP → [H.264 NAL stream] → CODA 驱动 → [bitstream FIFO] → 固件 → [YUV] → APP
                                                     ↕
                                              固件内部 DPB

Stateless:
    APP → [解析H.264] → [一帧数据 + SPS/PPS + ref_list] → Hantro 驱动 → HW → [YUV] → APP
             ↕                                                                    ↕
      APP 维护 DPB ←──────────────── 解码完成的帧加入 DPB ────────────────────────┘
```

---

## 6. 中断与完成通知

### CODA（Stateful）

```c
// coda-bit.c 中断处理
irqreturn_t coda_irq_handler(int irq, void *data)
{
    // 读取中断原因
    // 通知 completion → coda_pic_run_work() 中的 wait_for_completion 返回
    complete(&ctx->completion);
    return IRQ_HANDLED;
}

// 完成后在 worker 中：
ctx->ops->finish_run(ctx);  // 处理解码结果、更新 bitstream 指针
v4l2_m2m_job_finish(...);   // 告诉 M2M 框架可以调度下一个 job
```

### Hantro（Stateless）

```c
// hantro_drv.c
void hantro_irq_done(struct hantro_dev *vpu, enum vb2_buffer_state result)
{
    struct hantro_ctx *ctx = v4l2_m2m_get_curr_priv(vpu->m2m_dev);

    // 如果有后处理（如格式转换）
    if (ctx->codec_ops->done)
        ctx->codec_ops->done(ctx);

    // 直接完成：buf_done + job_finish 合一
    hantro_job_finish(vpu, ctx, result);
}

static void hantro_job_finish(...)
{
    pm_runtime_put_autosuspend(vpu->dev);
    clk_bulk_disable(...);
    v4l2_m2m_buf_done_and_job_finish(vpu->m2m_dev, ctx->fh.m2m_ctx, result);
}
```

---

## 7. 适用场景

| 场景 | 推荐 | 原因 |
|------|------|------|
| 简单播放器（VLC 等） | Stateful | 用户空间无需复杂解码逻辑 |
| 浏览器视频（Chromium） | Stateless | Chromium 已有完整解码器，只需硬件加速 |
| 低延迟场景（视频会议） | Stateless | 逐帧控制，无固件缓冲延迟 |
| 嵌入式简单应用 | Stateful | 开发成本低 |
| 安全/DRM 播放 | Stateless | 可在安全域管理密钥和解密 |

---

## 8. 源码文件索引

### CODA (Stateful)

| 文件 | 作用 |
|------|------|
| `coda-common.c` | V4L2 M2M 注册、ioctl、device_run/job_ready |
| `coda-bit.c` | BIT 处理器命令：seq_init/pic_run/seq_end |
| `coda-h264.c` | H.264 特定参数处理 |
| `coda-jpeg.c` | JPEG 编解码 |
| `coda.h` | 核心数据结构（coda_ctx, coda_dev） |
| `imx-vdoa.c` | 视频数据顺序转换（tile→raster） |

### Hantro (Stateless)

| 文件 | 作用 |
|------|------|
| `hantro_drv.c` | 驱动注册、device_run、controls |
| `hantro_v4l2.c` | V4L2 格式协商、queue 初始化 |
| `hantro_g1_h264_dec.c` | G1 H.264 解码寄存器配置 |
| `hantro_g2_hevc_dec.c` | G2 HEVC 解码 |
| `hantro_g2_vp9_dec.c` | G2 VP9 解码 |
| `hantro_h264.c` | H.264 参考帧辅助函数 |
| `hantro_postproc.c` | 后处理（格式转换） |
| `imx8m_vpu_hw.c` | i.MX8M 平台适配 |
| `rockchip_vpu_hw.c` | Rockchip 平台适配 |
