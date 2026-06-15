---
layout: post
title: "Hantro VPU 驱动深度分析（Stateless 解码器）"
date: 2026-06-15 11:30:00 +0800
excerpt: "深入分析 Linux mainline Hantro (Verisilicon) Stateless VPU 驱动：Request API 工作机制、参考帧时间戳引用、codec_ops 硬件抽象、多平台适配。"
---

# Hantro VPU 驱动深度分析（Stateless 解码器）

源码：`drivers/media/platform/verisilicon/`

---

## 1. 硬件概述

Hantro (Verisilicon VC8000D) 是纯硬件解码 IP，无固件：

```
┌─────────────────────────────────────────────────────┐
│                  Hantro VPU                           │
│                                                     │
│  ┌─────────────────┐    ┌─────────────────────────┐ │
│  │ G1 Decoder      │    │ G2 Decoder              │ │
│  │ - H.264         │    │ - HEVC                  │ │
│  │ - VP8           │    │ - VP9                   │ │
│  │ - MPEG-2        │    │ - AV1 (部分平台)        │ │
│  │ - JPEG          │    │                         │ │
│  └─────────────────┘    └─────────────────────────┘ │
│                                                     │
│  ┌─────────────────┐                                │
│  │ H1 Encoder      │                                │
│  │ - JPEG          │                                │
│  │ - H.264 (部分)  │                                │
│  └─────────────────┘                                │
│                                                     │
│  特点：                                              │
│  - 无固件，纯寄存器驱动                               │
│  - 每帧独立处理，无内部状态                           │
│  - 用户空间提供所有解码参数                           │
└─────────────────────────────────────────────────────┘
```

## 2. 驱动架构

### 2.1 核心数据结构

```c
// hantro.h
struct hantro_dev {
    struct v4l2_device    v4l2_dev;
    struct v4l2_m2m_dev   *m2m_dev;
    struct media_device   mdev;         // Media Controller（Request API 需要）
    void __iomem          *regs;        // 寄存器基地址
    struct clk_bulk_data  *clocks;
    struct mutex          vpu_mutex;

    const struct hantro_variant *variant;  // 平台变体（i.MX8M/Rockchip/...）
};

struct hantro_ctx {
    struct v4l2_fh        fh;
    struct hantro_dev     *dev;
    struct v4l2_ctrl_handler ctrl_handler;

    // 当前 codec 操作
    const struct hantro_codec_ops *codec_ops;

    // 编解码配置
    bool                  is_encoder;
    u32                   src_fmt;       // 压缩格式
    u32                   dst_fmt;       // 输出像素格式

    // 序列号（用于帧排序）
    u32                   sequence_cap;
    u32                   sequence_out;
};
```

### 2.2 平台变体抽象

```c
// hantro_hw.h
struct hantro_variant {
    unsigned int          num_dec_fmts;
    const struct hantro_fmt *dec_fmts;     // 支持的解码格式
    unsigned int          num_enc_fmts;
    const struct hantro_fmt *enc_fmts;
    const struct hantro_codec_ops *codec_ops;  // codec 操作表
    unsigned int          num_clocks;
    const char * const    *clk_names;
    irqreturn_t (*irq_handler)(int irq, void *priv);
};

// 例如 i.MX8M 变体
// imx8m_vpu_hw.c
static const struct hantro_variant imx8mq_vpu_variant = {
    .dec_fmts = imx8m_vpu_dec_fmts,
    .num_dec_fmts = ARRAY_SIZE(imx8m_vpu_dec_fmts),
    .codec_ops = imx8mq_vpu_codec_ops,
    .num_clocks = 3,
    .clk_names = {"bus", "core", "bus_per"},
};
```

### 2.3 Codec 操作表

```c
// hantro_hw.h
struct hantro_codec_ops {
    int  (*run)(struct hantro_ctx *ctx);     // 配置寄存器 + 启动
    void (*reset)(struct hantro_ctx *ctx);   // 复位
    void (*done)(struct hantro_ctx *ctx);    // 完成后处理
    void (*init)(struct hantro_ctx *ctx);    // 初始化
    void (*exit)(struct hantro_ctx *ctx);    // 清理
};
```

## 3. Request API 完整工作流程

### 3.1 为什么需要 Request API

Stateless 硬件每帧需要：
1. 一块压缩数据（buffer）
2. 对应的解码参数（controls）

这两者必须**原子绑定**——不能先设 control 再 QBUF，因为多线程下可能错配。Request API 解决这个问题。

### 3.2 Request 提交时序

```
用户空间                              内核
────────                             ────

1. 分配 Request
   ioctl(media_fd, MEDIA_IOC_REQUEST_ALLOC, &req_fd)

2. 设置 Controls（绑定到 Request）
   struct v4l2_ext_controls ctrls = {
       .which = V4L2_CTRL_WHICH_REQUEST_VAL,
       .request_fd = req_fd,
       .controls = {
           { .id = V4L2_CID_STATELESS_H264_SPS, .ptr = &sps },
           { .id = V4L2_CID_STATELESS_H264_PPS, .ptr = &pps },
           { .id = V4L2_CID_STATELESS_H264_DECODE_PARAMS, .ptr = &dec },
       }
   };
   ioctl(vpu_fd, VIDIOC_S_EXT_CTRLS, &ctrls)

3. QBUF（绑定到 Request）
   struct v4l2_buffer buf = {
       .type = OUTPUT,
       .memory = MMAP,
       .index = 0,                // 压缩数据在 buf[0]
       .request_fd = req_fd,      // 绑定到 request！
       .flags = V4L2_BUF_FLAG_REQUEST_FD,
   };
   ioctl(vpu_fd, VIDIOC_QBUF, &buf)

4. 提交 Request
   ioctl(req_fd, MEDIA_REQUEST_IOC_QUEUE)
       │
       ▼                          内核 M2M 框架
                                  检查 src_buf + dst_buf 就绪
                                      │
                                      ▼
                                  device_run(ctx)
                                      │
                                      ├─ hantro_get_ctrl(ctx, H264_SPS)
                                      │   → 从 request 中读取 SPS
                                      ├─ hantro_get_ctrl(ctx, H264_PPS)
                                      ├─ hantro_get_ctrl(ctx, DECODE_PARAMS)
                                      │   → 获取参考帧时间戳列表
                                      │
                                      ├─ 配置硬件寄存器
                                      └─ 启动解码

5. 等待完成
   DQBUF(CAPTURE) → 解码后的 YUV 帧
   close(req_fd)  → 释放 request（可复用）
```

### 3.3 device_run 源码

```c
// hantro_drv.c
static void device_run(void *priv)
{
    struct hantro_ctx *ctx = priv;
    struct vb2_v4l2_buffer *src, *dst;

    src = hantro_get_src_buf(ctx);
    dst = hantro_get_dst_buf(ctx);

    // 唤醒硬件
    ret = pm_runtime_resume_and_get(ctx->dev->dev);
    ret = clk_bulk_enable(ctx->dev->variant->num_clocks, ctx->dev->clocks);

    // 拷贝时间戳等元数据
    v4l2_m2m_buf_copy_metadata(src, dst);

    // 调用 codec-specific 的 run()
    if (ctx->codec_ops->run(ctx))
        goto err_cancel_job;

    return;

err_cancel_job:
    hantro_job_finish_no_pm(ctx->dev, ctx, VB2_BUF_STATE_ERROR);
}
```

## 4. H.264 解码实例（G1 硬件）

### 4.1 run() 函数

```c
// hantro_g1_h264_dec.c（简化示意）
static int hantro_g1_h264_dec_run(struct hantro_ctx *ctx)
{
    // 从 controls 获取参数
    const struct v4l2_ctrl_h264_sps *sps =
        hantro_get_ctrl(ctx, V4L2_CID_STATELESS_H264_SPS);
    const struct v4l2_ctrl_h264_pps *pps =
        hantro_get_ctrl(ctx, V4L2_CID_STATELESS_H264_PPS);
    const struct v4l2_ctrl_h264_decode_params *dec_param =
        hantro_get_ctrl(ctx, V4L2_CID_STATELESS_H264_DECODE_PARAMS);

    // 配置画面尺寸
    reg = G1_REG_DEC_CTRL0;
    reg |= (sps->pic_width_in_mbs_minus1 + 1) << 16;
    reg |= (sps->pic_height_in_map_units_minus1 + 1) << 0;
    hantro_write(vpu, G1_SWREG(4), reg);

    // 配置参考帧地址
    for (i = 0; i < V4L2_H264_NUM_DPB_ENTRIES; i++) {
        u64 ref_ts = dec_param->dpb[i].timestamp;
        dma_addr_t ref_addr = hantro_get_ref(ctx, ref_ts);
        hantro_write(vpu, G1_REG_ADDR_REF(i), ref_addr);
    }

    // 设置输入 bitstream 地址
    src_dma = vb2_dma_contig_plane_dma_addr(&src_buf->vb2_buf, 0);
    hantro_write(vpu, G1_REG_ADDR_STR, src_dma);

    // 设置输出帧地址
    dst_dma = hantro_get_dec_buf_addr(ctx, &dst_buf->vb2_buf);
    hantro_write(vpu, G1_REG_ADDR_DST, dst_dma);

    // 启动！
    hantro_write(vpu, G1_REG_START, 1);
    return 0;
}
```

### 4.2 参考帧时间戳机制

```c
// hantro_drv.c
dma_addr_t hantro_get_ref(struct hantro_ctx *ctx, u64 ts)
{
    struct vb2_queue *q = v4l2_m2m_get_dst_vq(ctx->fh.m2m_ctx);
    struct vb2_buffer *buf;

    // 通过时间戳在 CAPTURE queue 中查找对应 buffer
    buf = vb2_find_buffer(q, ts);
    if (!buf)
        return 0;

    return hantro_get_dec_buf_addr(ctx, buf);
}
```

**时间戳引用流程**：

```
CAPTURE queue:
  buf[0]: ts=1000, dma_addr=0x80000000  ← 已解码的帧 0
  buf[1]: ts=2000, dma_addr=0x80100000  ← 已解码的帧 1
  buf[2]: ts=3000, dma_addr=0x80200000  ← 当前要解码到这里

用户空间传入的 decode_params:
  dpb[0].timestamp = 1000  → 引用帧 0
  dpb[1].timestamp = 2000  → 引用帧 1

驱动:
  hantro_get_ref(ctx, 1000) → 0x80000000 → 写入 REF_ADDR[0] 寄存器
  hantro_get_ref(ctx, 2000) → 0x80100000 → 写入 REF_ADDR[1] 寄存器
```

## 5. 中断处理

```c
// hantro_drv.c
void hantro_irq_done(struct hantro_dev *vpu, enum vb2_buffer_state result)
{
    struct hantro_ctx *ctx = v4l2_m2m_get_curr_priv(vpu->m2m_dev);

    // codec-specific 后处理（如格式转换）
    if (ctx->codec_ops->done)
        ctx->codec_ops->done(ctx);

    hantro_job_finish(vpu, ctx, result);
}

static void hantro_job_finish(struct hantro_dev *vpu,
                              struct hantro_ctx *ctx,
                              enum vb2_buffer_state result)
{
    // 关闭硬件
    pm_runtime_put_autosuspend(vpu->dev);
    clk_bulk_disable(vpu->variant->num_clocks, vpu->clocks);

    // 同时完成 buf_done + job_finish
    v4l2_m2m_buf_done_and_job_finish(vpu->m2m_dev, ctx->fh.m2m_ctx, result);
}
```

**对比 CODA**：Hantro 的中断处理极简——硬件完成就直接返回结果。没有固件状态、没有 bitstream FIFO 更新、没有帧重排序。

## 6. 后处理（Post-processing）

部分硬件支持内置后处理（格式转换）：

```c
// hantro_postproc.c
// G2 解码器输出的是硬件特定的 tile 格式，需要转换为标准 NV12

void hantro_postproc_enable(struct hantro_ctx *ctx)
{
    // 分配中间缓冲
    // 配置后处理寄存器：tile → raster-scan NV12
}
```

## 7. 多平台适配

同一个 Hantro IP 用在不同 SoC 上，通过 variant 抽象差异：

```c
// 各平台适配文件
imx8m_vpu_hw.c      → NXP i.MX8M (G1+G2)
rockchip_vpu_hw.c   → Rockchip (G1+vepu)
sama5d4_vdec_hw.c   → Microchip SAMA5D4 (G1)
stm32mp25_vpu_hw.c  → STM32MP25 (G1+G2)
sunxi_vpu_hw.c      → Allwinner
```

差异点：
- 时钟名称和数量
- 寄存器偏移（少量差异）
- 支持的格式子集
- 中断处理细节

```c
// 设备树匹配
static const struct of_device_id hantro_dt_match[] = {
    { .compatible = "nxp,imx8mq-vpu-g1", .data = &imx8mq_vpu_g1_variant },
    { .compatible = "nxp,imx8mq-vpu-g2", .data = &imx8mq_vpu_g2_variant },
    { .compatible = "rockchip,rk3399-vpu", .data = &rk3399_vpu_variant },
    { .compatible = "rockchip,rk3568-vepu", .data = &rk3568_vepu_variant },
    { }
};
```

---

## 8. 与 Stateful 的关键实现差异总结

| 方面 | Hantro (Stateless) 实现 |
|------|------------------------|
| 数据输入 | 每帧独立的 buffer，无 FIFO |
| 硬件同步 | 直接中断，无 workqueue |
| 多实例 | 每帧独立，无硬件互斥（硬件本身是逐帧处理） |
| 分辨率 | 用户空间已知，不需要 SOURCE_CHANGE |
| DPB | 通过时间戳引用 CAPTURE queue 中的 buffer |
| 帧排序 | 用户空间负责 |
| 固件 | 无 |
| device_run | 同步执行（配寄存器→启动→返回，中断时完成） |
| job_ready | 不需要（默认检查即可） |
