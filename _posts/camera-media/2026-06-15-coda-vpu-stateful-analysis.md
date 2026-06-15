---
layout: post
title: "CODA VPU 驱动深度分析（Stateful 编解码器）"
date: 2026-06-15 12:00:00 +0800
excerpt: "深入分析 Linux mainline CODA (Chips&Media) VPU 驱动的完整工作流程：固件交互、bitstream FIFO 管理、序列初始化、多实例调度、SOURCE_CHANGE 事件处理。"
---

# CODA VPU 驱动深度分析（Stateful 编解码器）

源码：`drivers/media/platform/chips-media/coda/`

---

## 1. 硬件概述

CODA 是 Chips&Media 的多标准编解码 IP，用于 NXP i.MX6 系列：

```
┌─────────────────────────────────────────────────┐
│                CODA VPU                           │
│                                                 │
│  ┌──────────┐   ┌──────────────────────────┐   │
│  │ BIT      │   │ 内部 SRAM (IRAM)          │   │
│  │ Processor│   │ - bitstream FIFO          │   │
│  │ (固件核) │   │ - 工作缓冲               │   │
│  └────┬─────┘   └──────────────────────────┘   │
│       │                                         │
│  ┌────┴─────────────────────────────────────┐   │
│  │ 硬件加速引擎                              │   │
│  │ - 运动估计/补偿                           │   │
│  │ - 变换/逆变换                             │   │
│  │ - 熵编解码                                │   │
│  │ - 环路滤波                                │   │
│  └──────────────────────────────────────────┘   │
│                                                 │
│  支持格式：H.264, MPEG-4, MPEG-2, JPEG         │
│  最大分辨率：1920x1088 (i.MX6Q)                 │
│  多实例：最多4个同时编解码                       │
└─────────────────────────────────────────────────┘
```

## 2. 驱动架构

### 2.1 核心数据结构

```c
// coda.h
struct coda_dev {
    struct v4l2_device   v4l2_dev;
    struct v4l2_m2m_dev  *m2m_dev;
    void __iomem         *regs_base;      // 寄存器基地址
    struct clk           *clk_per;        // 外设时钟
    struct clk           *clk_ahb;        // AHB 时钟
    struct mutex         coda_mutex;      // 硬件互斥（多实例共享）
    struct workqueue_struct *workqueue;   // 异步工作队列
    struct vdoa_data     *vdoa;           // VDOA（tile→raster 转换）

    struct coda_aux_buf  codebuf;         // 固件代码缓冲
    struct coda_aux_buf  tempbuf;         // 临时工作缓冲
    struct coda_aux_buf  workbuf;         // 工作缓冲
    int                  firmware_vernum; // 固件版本
};

struct coda_ctx {
    struct v4l2_fh       fh;              // V4L2 file handle（内含 m2m_ctx）
    struct coda_dev      *dev;
    struct mutex         buffer_mutex;

    // 编解码器操作
    const struct coda_context_ops *ops;   // prepare_run/finish_run/...

    // bitstream FIFO
    struct kfifo         bitstream_fifo;  // 环形缓冲
    struct list_head     buffer_meta_list;// 元数据列表
    int                  num_metas;

    // 内部帧缓冲
    struct coda_aux_buf  internal_frames[CODA_MAX_FRAMEBUFFERS];
    int                  num_internal_frames;
    u32                  frm_dis_flg;     // 帧显示标志位图

    // 状态
    int                  inst_type;       // ENCODER 或 DECODER
    bool                 use_bit;         // 使用 BIT 处理器
    bool                 hold;            // 暂停（等更多数据）
    u32                  bit_stream_param;// 流参数（含 END_FLAG）

    struct completion    completion;      // 硬件完成通知
    struct work_struct   pic_run_work;    // 异步执行 work
    struct work_struct   seq_end_work;    // 序列结束 work
};
```

### 2.2 操作函数表（codec-specific）

```c
struct coda_context_ops {
    int  (*queue_init)(void *priv, struct vb2_queue *src, struct vb2_queue *dst);
    int  (*reqbufs)(struct coda_ctx *ctx, struct v4l2_requestbuffers *rb);
    int  (*start_streaming)(struct coda_ctx *ctx);
    int  (*prepare_run)(struct coda_ctx *ctx);   // 配置寄存器，启动一帧
    void (*finish_run)(struct coda_ctx *ctx);    // 处理完成结果
    void (*run_timeout)(struct coda_ctx *ctx);   // 超时处理
    void (*seq_end_work)(struct work_struct *work);
    void (*release)(struct coda_ctx *ctx);
};
```

## 3. Bitstream FIFO 机制

Stateful 驱动的核心特点——驱动维护一个**环形 bitstream 缓冲区**：

```
用户空间 QBUF 的压缩数据          CODA 固件从这里读取
        │                              │
        ▼                              ▼
┌───────────────────────────────────────────────┐
│ ████████████████░░░░░░░░░░████████████████████│
│ ↑wr_ptr                  ↑rd_ptr             │
│                                               │
│ Bitstream Ring Buffer (在 DMA 可访问内存中)     │
└───────────────────────────────────────────────┘

█ = 有数据等待解码
░ = 空闲空间
```

**数据流**：

```
1. 用户 QBUF(OUTPUT, H.264 data)
2. 驱动把数据拷贝到 bitstream FIFO (kfifo)
3. device_run() 时：
   - 检查 FIFO 中有足够数据
   - 告诉固件 wr_ptr 位置
   - 固件从 rd_ptr 开始读取解码
4. 固件解码完一帧后中断
5. 驱动更新 rd_ptr
6. DQBUF(CAPTURE) 返回解码帧
```

## 4. 解码全流程

### 4.1 序列初始化（SEQ_INIT）

第一次喂入数据时，固件需要解析 SPS/PPS 确定视频参数：

```
用户空间                    驱动                      固件
────────                   ────                     ────
QBUF(OUTPUT, SPS+PPS+IDR)
  →                    写入 bitstream FIFO
                       发送 SEQ_INIT 命令 →
                                                解析 SPS/PPS
                                                确定：
                                                - 分辨率
                                                - DPB 大小
                                                - profile/level
                                              ← SEQ_INIT 完成中断

                       读取结果寄存器：
                       - pic_width/height
                       - min_frame_buffer_count
                       
                       发送 SOURCE_CHANGE 事件 →
←  V4L2_EVENT_SOURCE_CHANGE
   
   G_FMT(CAPTURE) → 获取实际分辨率
   REQBUFS(CAPTURE) → 分配解码帧缓冲
   
                       SET_FRAME_BUF 命令 →
                                                注册帧缓冲地址
                                              ← 完成
   STREAMON(CAPTURE)
```

### 4.2 图像解码（PIC_RUN）

```c
// coda-bit.c（简化）
static int coda_start_decoding(struct coda_ctx *ctx)
{
    // 把用户 QBUF 的数据写入 bitstream FIFO
    coda_fill_bitstream(ctx, ...);

    // 更新 bitstream 写指针告诉固件
    coda_write(dev, ctx->bitstream.paddr + wr_ptr, CODA_REG_BIT_WR_PTR);

    // 设置输出帧缓冲地址（CAPTURE buffer 的 DMA 地址）
    dst_buf = v4l2_m2m_next_dst_buf(ctx->fh.m2m_ctx);
    coda_write(dev, vb2_dma_contig_plane_dma_addr(&dst_buf->vb2_buf, 0),
               CODA_REG_BIT_FRM_DIS_FLG_SET);

    // 发送 PIC_RUN 命令
    coda_command_sync(ctx, CODA_COMMAND_PIC_RUN);
    // → 固件解码一帧
    // → 中断触发 completion
}
```

### 4.3 device_run 与 job_finish

```
M2M 框架调度
    │
    ▼
coda_device_run()
    │
    └─ queue_work(pic_run_work)  ← 异步！不阻塞 M2M 调度线程
           │
           ▼
    coda_pic_run_work()
        │
        ├─ mutex_lock(coda_mutex)     ← 硬件互斥
        ├─ prepare_run()              ← 配置、启动硬件
        ├─ wait_for_completion(1s)    ← 等中断
        │      │
        │      ├─ 成功 → finish_run() ← 取结果、buf_done
        │      └─ 超时 → hw_reset()   ← 硬件复位
        │
        ├─ mutex_unlock(coda_mutex)
        └─ v4l2_m2m_job_finish()      ← 告诉 M2M 可调度下一个
```

**为什么用 workqueue 而不是直接在 device_run 里等？**

因为 M2M 框架的 `device_run()` 是在调度上下文中调用的，不能阻塞。CODA 的固件处理需要几十毫秒，所以放到 workqueue 异步执行。

## 5. 多实例共享

i.MX6 上只有一个 CODA VPU，但支持最多 4 个实例（如同时解码 4 路视频）：

```
Instance 0 (H.264 decode) ──┐
Instance 1 (MPEG-4 decode) ─┤── coda_mutex ──→ 一次只有一个实例用硬件
Instance 2 (H.264 encode) ──┤
Instance 3 (JPEG encode) ───┘

时分复用：
[Inst0 PIC_RUN] → [Inst2 PIC_RUN] → [Inst1 PIC_RUN] → [Inst0 PIC_RUN] → ...
```

每次切换实例时，固件会保存/恢复上下文（参考帧状态、bitstream 位置等）。

## 6. SOURCE_CHANGE 事件

Stateful 驱动独有的机制——固件检测到视频参数变化时通知用户空间：

```c
// 触发条件：
// - 首次 SEQ_INIT 完成
// - 码流中分辨率改变（adaptive streaming）

v4l2_event_queue_fh(&ctx->fh, &coda_source_change_event);
// 用户空间收到后：
// 1. STREAMOFF(CAPTURE)
// 2. G_FMT 获取新分辨率
// 3. REQBUFS 重新分配缓冲
// 4. STREAMON(CAPTURE) 继续
```

---

## 7. 与 Stateless 的关键实现差异

| 方面 | CODA 实现 |
|------|-----------|
| 数据输入 | kfifo bitstream 环形缓冲，持续喂流 |
| 硬件同步 | completion + workqueue（异步等待） |
| 多实例 | coda_mutex 硬件互斥，时分复用 |
| 分辨率检测 | 固件解析 → SOURCE_CHANGE 事件 |
| DPB | 固件内部管理 internal_frames[] |
| 帧排序 | 固件输出已重排序的帧 |
