---
layout: post
title: "IMX500 Metadata 获取机制深度分析"
date: 2026-05-28
categories: [linux, media, camera]
tags: [imx500, metadata, csi2, v4l2, raspberry-pi]
---

# IMX500 Metadata 获取机制深度分析

## 一、背景

IMX500 是 Sony 的智能视觉传感器，片内集成 AI 加速器。与普通 sensor 不同，它不仅输出图像数据，还输出 AI 推理结果和传感器 metadata。本文以 Raspberry Pi 5 + IMX500 为平台，深入分析 metadata 从 sensor 硬件到用户空间的完整数据通路。

平台信息：
- SoC: BCM2712 (Raspberry Pi 5)
- Sensor: Sony IMX500 (CSI-2 接口)
- ISP: PiSP (Pi Image Signal Processor)
- CSI Frontend: RP1 CFE (CSI-2 Frontend Engine)
- 用户空间: libcamera + rpicam-apps

---

## 二、IMX500 输出的数据类型

IMX500 在一条 MIPI CSI-2 物理链路上输出两种数据：

| 数据类型 | 内容 | CSI-2 Data Type |
|----------|------|-----------------|
| 图像 | RAW Bayer 像素数据 | 0x2B (RAW10) |
| Metadata | KPI + Input Tensor + Output Tensor + PQ | 0x12 (User Defined 8-bit) |

Sensor 内部通道配置（`metadata_output[]` 寄存器）：

```c
static const struct cci_reg_sequence metadata_output[] = {
    { CCI_REG8(0x3050), 1 }, /* MIPI Output enabled */
    { CCI_REG8(0x3051), 1 }, /* MIPI output frame includes pixels data */
    { CCI_REG8(0x3052), 1 }, /* MIPI output frame includes meta data */
    { IMX500_REG_DD_CH06_VCID, 0 },  /* KPI: VC=0 */
    { IMX500_REG_DD_CH07_VCID, 0 },  /* Input Tensor: VC=0 */
    { IMX500_REG_DD_CH08_VCID, 0 },  /* Output Tensor: VC=0 */
    { IMX500_REG_DD_CH09_VCID, 0 },  /* PQ: VC=0 */
    { IMX500_REG_DD_CH06_DT, 0x12 }, /* KPI - User Defined 8-bit */
    { IMX500_REG_DD_CH07_DT, 0x12 }, /* Input Tensor */
    { IMX500_REG_DD_CH08_DT, 0x12 }, /* Output Tensor */
    { IMX500_REG_DD_CH09_DT, 0x12 }, /* PQ */
    { IMX500_REG_DD_CH06_PACKING, IMX500_DD_PACKING_8BPP },
    { IMX500_REG_DD_CH07_PACKING, IMX500_DD_PACKING_8BPP },
    { IMX500_REG_DD_CH08_PACKING, IMX500_DD_PACKING_8BPP },
    { IMX500_REG_DD_CH09_PACKING, IMX500_DD_PACKING_8BPP },
};
```

CH06~CH09 是 IMX500 芯片内部的数据输出通道，所有通道配置为 VC=0、DT=0x12，sensor 将这些数据合并为 embedded lines 在图像帧之后输出。

---

## 三、软件架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                        用户空间                                   │
│  rpicam-still --metadata meta.json                              │
│       ↕                                                          │
│  libcamera (pipeline handler: rpi/pisp)                         │
│       ↕                                                          │
│  IPA (Image Processing Algorithm) ← 解析 embedded data          │
└─────────────────────────────────────────────────────────────────┘
        ↕ VIDIOC_DQBUF (/dev/video0 图像, /dev/video1 metadata)
┌─────────────────────────────────────────────────────────────────┐
│                        内核空间                                   │
│                                                                  │
│  ┌──────────┐    ┌───────────────┐    ┌──────────────────┐      │
│  │ imx500.c │    │   csi2.c      │    │     cfe.c        │      │
│  │ (sensor  │───▶│ (CSI2 subdev  │───▶│ (video nodes     │      │
│  │  driver) │    │  + routing)   │    │  + DMA)          │      │
│  └──────────┘    └───────────────┘    └──────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
        ↕ MIPI CSI-2 (物理链路, 4 lanes)
┌─────────────────────────────────────────────────────────────────┐
│                    IMX500 Sensor 硬件                             │
│  [图像数据 VC=0,DT=0x2B] [Metadata VC=0,DT=0x12]               │
└─────────────────────────────────────────────────────────────────┘
```

---

## 四、Sensor 驱动层：Pad 与格式

### 4.1 双 Pad 设计

IMX500 驱动定义了两个 source pad：

```c
enum pad_types { IMAGE_PAD, METADATA_PAD, NUM_PADS };
// IMAGE_PAD = 0: 图像输出
// METADATA_PAD = 1: metadata 输出
```

注册时：
```c
imx500->pad[IMAGE_PAD].flags = MEDIA_PAD_FL_SOURCE;
imx500->pad[METADATA_PAD].flags = MEDIA_PAD_FL_SOURCE;
media_entity_pads_init(&imx500->sd.entity, NUM_PADS, imx500->pad);
```

### 4.2 get_fmt — 告诉下游每个 pad 输出什么格式

```c
static int imx500_get_pad_format(struct v4l2_subdev *sd,
                                 struct v4l2_subdev_state *sd_state,
                                 struct v4l2_subdev_format *fmt)
{
    if (fmt->pad == IMAGE_PAD) {
        // 返回图像格式: 4056x3040, SRGGB10
        imx500_update_image_pad_format(imx500, imx500->mode, fmt);
        fmt->format.code = imx500_get_format_code(imx500);
    } else {
        // 返回 metadata 格式
        imx500_update_metadata_pad_format(imx500, fmt);
    }
}
```

Metadata pad 格式：
```c
static void imx500_update_metadata_pad_format(const struct imx500 *imx500,
                                              struct v4l2_subdev_format *fmt)
{
    fmt->format.width = IMX500_MAX_EMBEDDED_SIZE +
        imx500->num_inference_lines * IMX500_INFERENCE_LINE_WIDTH;
    fmt->format.height = 1;
    fmt->format.code = MEDIA_BUS_FMT_SENSOR_DATA;  // 关键：标识为 sensor data
}
```

**为什么需要两个 pad？**

虽然物理上只有一条 CSI-2 链路，但 pad 是逻辑抽象。两个 pad 让 V4L2 框架知道：
1. 这个设备输出两种不同类型的数据
2. 每种数据有独立的格式描述（分辨率、pixel code）
3. 下游可以独立协商每种数据的格式

### 4.3 为什么没有 get_frame_desc

IMX500 的 pad_ops 中没有实现 `get_frame_desc`：

```c
static const struct v4l2_subdev_pad_ops imx500_pad_ops = {
    .enum_mbus_code = imx500_enum_mbus_code,
    .get_fmt = imx500_get_pad_format,
    .set_fmt = imx500_set_pad_format,
    .get_selection = imx500_get_selection,
    .enum_frame_size = imx500_enum_frame_size,
    // 没有 .get_frame_desc
};
```

`get_frame_desc` 的作用是显式告诉 CSI 接收端"每个 stream 在 CSI-2 线上用什么 VC/DT 发送"。IMX500 没实现它，CFE 通过 fallback 机制从 format code 推导 DT 值，效果相同。

---

## 五、CSI2 Subdev 层：路由分发

### 5.1 物理链路 vs 逻辑流

```
物理现实：一条 CSI-2 链路，图像和 metadata 数据包交替传输

时间轴 →
[VC=0,DT=0x2B][图像行1][VC=0,DT=0x2B][图像行2]...[VC=0,DT=0x12][metadata]
```

CSI2 subdev 的作用是将一条物理链路上的多条逻辑流路由到不同的 DMA channel。

### 5.2 CSI2 Subdev 的 Pad 结构

```c
// csi2.h
#define CSI2_NUM_CHANNELS 4
#define CSI2_PAD_SINK 0
#define CSI2_PAD_FIRST_SOURCE 1
#define CSI2_PAD_NUM_SOURCES 4
#define CSI2_NUM_PADS 5  // 1 sink + 4 source

// 结构:
//   pad 0 (sink) ← 接收 sensor 所有数据
//   pad 1 (source) → CSI2_CH0
//   pad 2 (source) → CSI2_CH1
//   pad 3 (source) → CSI2_CH2
//   pad 4 (source) → CSI2_CH3
```

### 5.3 路由表配置

libcamera 通过 `VIDIOC_SUBDEV_S_ROUTING` 配置路由：

```c
static int csi2_set_routing(struct v4l2_subdev *sd,
                            struct v4l2_subdev_state *state,
                            enum v4l2_subdev_format_whence which,
                            struct v4l2_subdev_krouting *routing)
{
    // 校验: 只允许 1:1 路由，source pad 不能复用
    ret = v4l2_subdev_routing_validate(sd, routing,
        V4L2_SUBDEV_ROUTING_ONLY_1_TO_1 |
        V4L2_SUBDEV_ROUTING_NO_SOURCE_MULTIPLEXING);

    // 每个 source pad 上只允许 stream ID = 0
    for (i = 0; i < routing->num_routes; ++i) {
        if (routing->routes[i].source_stream != 0)
            return -EINVAL;
    }

    // 保存路由表到 subdev state
    v4l2_subdev_set_routing_with_fmt(sd, state, routing, &cfe_default_format);
}
```

实际路由表内容：
```
route[0]: sink_pad=0, sink_stream=0 → source_pad=1, source_stream=0  (图像→CH0)
route[1]: sink_pad=0, sink_stream=1 → source_pad=2, source_stream=0  (metadata→CH1)
```

---

## 六、CFE 层：硬件分流

### 6.1 DMA Channel 定义

```c
static const struct node_description node_desc[NUM_NODES] = {
    [CSI2_CH0] = {
        .name = "csi2-ch0",
        .caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_META_CAPTURE,
        .link_pad = CSI2_PAD_FIRST_SOURCE + 0
    },
    [CSI2_CH1] = {
        .name = "csi2-ch1",
        .caps = V4L2_CAP_META_CAPTURE,  // 专门用于 metadata
        .link_pad = CSI2_PAD_FIRST_SOURCE + 1
    },
    [CSI2_CH2] = { ... },
    [CSI2_CH3] = { ... },
    [FE_STATS] = { .caps = V4L2_CAP_META_CAPTURE },  // ISP 统计
    [FE_CONFIG] = { .caps = V4L2_CAP_META_OUTPUT },   // ISP 配置
};
```

CSI2_CH1 被限制为只支持 `V4L2_CAP_META_CAPTURE`，这是软件约束（硬件上 4 个 channel 等价）。

### 6.2 启动 Channel — 查询 VC/DT

```c
static int cfe_start_channel(struct cfe_node *node)
{
    // 获取该 channel 对应的 VC 和 DT
    ret = cfe_get_vc_dt(cfe, node->id, &vc, &dt);

    // 配置硬件并启动 DMA
    csi2_start_channel(&cfe->csi2, node->id, mode, auto_arm,
                       pack_bytes, width, height, vc, dt);
}
```

### 6.3 cfe_get_vc_dt — 路由表反查

```c
static int cfe_get_vc_dt(struct cfe_device *cfe, unsigned int channel,
                         u8 *vc, u8 *dt)
{
    state = v4l2_subdev_get_locked_active_state(&cfe->csi2.sd);

    // 步骤1: 从路由表中反查
    // "source_pad=N, source_stream=0 对应的 sink_stream 是什么？"
    v4l2_subdev_routing_find_opposite_end(&state->routing,
        CSI2_PAD_FIRST_SOURCE + channel, 0, NULL, &sink_stream);

    // 步骤2: 问 sensor "sink_stream=X 在 CSI-2 线上用什么 VC/DT？"
    ret = v4l2_subdev_call(cfe->source_sd, pad, get_frame_desc,
                           cfe->source_pad, &remote_desc);

    if (ret == -ENOIOCTLCMD) {
        // IMX500 没实现 get_frame_desc，走 fallback
        return cfe_get_vc_dt_fallback(cfe, vc, dt);
    }

    // 如果 sensor 实现了，从 frame_desc 中找到对应 stream 的 VC/DT
    *vc = remote_desc.entry[i].bus.csi2.vc;
    *dt = remote_desc.entry[i].bus.csi2.dt;
}
```

### 6.4 Fallback — 从 format code 推导 DT

```c
static int cfe_get_vc_dt_fallback(struct cfe_device *cfe, u8 *vc, u8 *dt)
{
    // 获取 sink pad 的 format
    fmt = v4l2_subdev_state_get_format(state, CSI2_PAD_SINK, 0);

    // 从 format code 查表得到 CSI-2 DT
    cfe_fmt = find_format_by_code(fmt->code);

    *vc = 0;
    *dt = cfe_fmt->csi_dt;
    // SRGGB10 → dt=0x2B
    // MEDIA_BUS_FMT_SENSOR_DATA → dt=0x12
}
```

### 6.5 csi2_start_channel — 写硬件寄存器

```c
void csi2_start_channel(struct csi2_device *csi2, unsigned int channel,
                        enum csi2_mode mode, bool auto_arm, bool pack_bytes,
                        unsigned int width, unsigned int height,
                        u8 vc, u8 dt)
{
    u32 ctrl;

    // 使能 DMA 和中断
    ctrl = CSI2_CH_CTRL_DMA_EN | CSI2_CH_CTRL_IRQ_EN_FS |
           CSI2_CH_CTRL_IRQ_EN_FE_ACK | CSI2_CH_CTRL_PACK_LINE;

    // 配置帧尺寸
    csi2_reg_write(csi2, CSI2_CH_FRAME_SIZE(channel),
                   (height << 16) | width);

    // 关键：配置 VC/DT 硬件过滤器
    set_field(&ctrl, vc, CSI2_CH_CTRL_VC_MASK);   // 只接收 VC=0 的包
    set_field(&ctrl, dt, CSI2_CH_CTRL_DT_MASK);   // 只接收指定 DT 的包
    csi2_reg_write(csi2, CSI2_CH_CTRL(channel), ctrl);
}
```

**这就是硬件分流的核心：** 每个 DMA channel 有独立的 VC/DT 过滤寄存器，只有匹配的 CSI-2 数据包才会被 DMA 到对应的 buffer。

---

## 七、数据流动（每帧）

```
┌─────────────────────────────────────────────────────────────────────┐
│ IMX500 Sensor                                                        │
│                                                                      │
│ CSI-2 物理链路输出（时间顺序）:                                        │
│ [VC=0,DT=0x2B] 图像行1                                              │
│ [VC=0,DT=0x2B] 图像行2                                              │
│ ...                                                                  │
│ [VC=0,DT=0x2B] 图像行N                                              │
│ [VC=0,DT=0x12] embedded metadata (KPI+Tensor+PQ)                    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ MIPI CSI-2 (4 lanes)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ CFE 硬件 (RP1 CSI-2 Frontend)                                        │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ CSI-2 Receiver: 解析数据包，提取 VC/DT                           │ │
│ └───────────────────────┬─────────────────────┬───────────────────┘ │
│                         │                     │                      │
│              VC=0,DT=0x2B 匹配        VC=0,DT=0x12 匹配             │
│                         │                     │                      │
│                         ▼                     ▼                      │
│              ┌──────────────────┐  ┌──────────────────┐             │
│              │ CH0 DMA Engine   │  │ CH1 DMA Engine   │             │
│              │ → image buffer   │  │ → meta buffer    │             │
│              └────────┬─────────┘  └────────┬─────────┘             │
│                       │                     │                        │
│                  EOF 中断               EOF 中断                     │
└───────────────────────┼─────────────────────┼────────────────────────┘
                        │                     │
                        ▼                     ▼
              ┌──────────────────┐  ┌──────────────────┐
              │ /dev/video0      │  │ /dev/video1      │
              │ (图像 buffer)    │  │ (metadata buffer)│
              └────────┬─────────┘  └────────┬─────────┘
                       │                     │
                       ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ libcamera IPA                                                        │
│                                                                      │
│ 解析 metadata buffer:                                                │
│   - Embedded registers → ExposureTime, AnalogueGain                 │
│   - AI tensor output → 推理结果                                      │
│   - PQ data → 画质参数                                               │
│                                                                      │
│ 输出 Request::metadata:                                              │
│   ExposureTime: 29977 us                                             │
│   AnalogueGain: 1.95                                                 │
│   ColourTemperature: 4464 K                                          │
│   Lux: 341                                                           │
│   ...                                                                │
└─────────────────────────────────────────────────────────────────────┘
                       │
                       ▼
              rpicam-still --metadata meta.json
              → 写入 JSON 文件
```

---

## 八、中断处理与 Buffer 完成

```c
// cfe.c: DMA 完成后的处理
static void cfe_process_buffer_complete(struct cfe_node *node,
                                        enum vb2_buffer_state state)
{
    node->cur_frm->vb.sequence = node->fs_count - 1;
    vb2_buffer_done(&node->cur_frm->vb.vb2_buf, state);
    // 通知用户空间: buffer 就绪，可以 DQBUF 了
}
```

---

## 九、Metadata 实际输出示例

使用 `rpicam-still --metadata` 获取的 JSON：

```json
{
    "ExposureTime": 29977,
    "AnalogueGain": 1.946768,
    "DigitalGain": 1.001686,
    "ColourTemperature": 4464,
    "ColourGains": [2.152472, 1.733022],
    "ColourCorrectionMatrix": [1.591, -0.354, -0.237, -0.387, 1.968, -0.581, -0.055, -0.503, 1.558],
    "Lux": 340.998,
    "SensorTemperature": 33.0,
    "SensorBlackLevels": [4096, 4096, 4096, 4096],
    "FocusFoM": 393,
    "FrameDuration": 100013,
    "AeState": 2
}
```

### 与 Tuning 配置对比

| 模块 | 配置值 (imx500.json) | 实际输出 | 说明 |
|------|---------------------|----------|------|
| Black Level | 4096 | [4096,4096,4096,4096] | 完全匹配 |
| CCM (ct=4500) | [1.587,-0.348,-0.240,...] | [1.591,-0.354,-0.237,...] | IPA 在色温点间插值 |
| AGC shutter 范围 | 100~66666 us | 29977 us | 在配置范围内 |
| AGC gain 范围 | 1.0~8.0 | 1.95 | 在配置范围内 |
| Lux 参考 | ref_lux=950 | 实际=341 | 根据参考条件反算 |
| DPC strength | 1 | (不在metadata中) | 配置生效但不反馈 |

---

## 十、调试方法

### 10.1 动态开启内核 debug 日志（不改代码）

```bash
# 开启 CFE 调试
echo "file cfe.c +p" > /sys/kernel/debug/dynamic_debug/control
# 开启 CSI2 调试
echo "file csi2.c +p" > /sys/kernel/debug/dynamic_debug/control
# 开启 IMX500 驱动调试
echo "file imx500.c +p" > /sys/kernel/debug/dynamic_debug/control
# 查看日志
dmesg -w
```

### 10.2 在 sensor 端确认 metadata 配置写入

```c
// imx500.c 约 2791 行
ret = cci_multi_reg_write(imx500->regmap, metadata_output,
                          ARRAY_SIZE(metadata_output), NULL);
// 加调试:
dev_dbg(&client->dev, "metadata output configured, ret=%d\n", ret);
```

### 10.3 在 CFE 端确认 metadata buffer 到达

```c
// cfe.c: cfe_process_buffer_complete() 中
if (is_meta_node(node))
    cfe_dbg(cfe, "meta buffer done: node=%s seq=%u\n",
            node_desc[node->id].name, node->cur_frm->vb.sequence);
```

### 10.4 确认路由和 VC/DT 配置

```c
// cfe.c: cfe_start_channel() 中
cfe_dbg(cfe, "start channel %d: vc=%u dt=0x%02x\n", node->id, vc, dt);
```

---

## 十一、关键函数速查表

| 函数 | 文件 | 作用 |
|------|------|------|
| `imx500_get_pad_format()` | imx500.c | 返回指定 pad 的数据格式 |
| `imx500_update_metadata_pad_format()` | imx500.c | 填充 metadata pad 格式（宽度、SENSOR_DATA code） |
| `imx500_start_streaming()` | imx500.c | 写 sensor 寄存器，开启 metadata 输出 |
| `csi2_set_routing()` | csi2.c | 保存用户空间配置的路由表 |
| `csi2_init_state()` | csi2.c | 初始化默认路由（单路由） |
| `cfe_start_channel()` | cfe.c | 启动 DMA channel |
| `cfe_get_vc_dt()` | cfe.c | 根据路由表查找 channel 对应的 VC/DT |
| `cfe_get_vc_dt_fallback()` | cfe.c | 从 format code 推导 DT（无 get_frame_desc 时） |
| `csi2_start_channel()` | csi2.c | 写硬件 VC/DT 过滤寄存器，开启 DMA |
| `cfe_process_buffer_complete()` | cfe.c | DMA 完成，通知用户空间 buffer 就绪 |
| `cfe_link_node_pads()` | cfe.c | 创建 media controller pad links |

---

## 十二、总结

1. **IMX500 通过两个 pad 抽象两种数据**（图像 + metadata），但物理上共用一条 CSI-2 链路
2. **CSI2 subdev 的路由表**将逻辑 stream 映射到不同的 source pad / DMA channel
3. **CFE 硬件通过 VC/DT 过滤寄存器**实现物理层面的数据包分拣
4. **VC/DT 值的获取**优先通过 `get_frame_desc`，IMX500 未实现则通过 format code 查表推导
5. **用户空间 libcamera IPA** 从 metadata buffer 中解析出曝光参数等信息，`--metadata` 参数只是控制是否导出为文件
6. **metadata 始终在流动**，不受用户是否请求 metadata 输出的影响，因为 IPA 的 3A 算法依赖它
