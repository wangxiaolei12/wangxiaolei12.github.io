---
layout: post
title: "Camera Metadata 从硬件到软件完整详解"
date: 2026-05-07 18:00:00 +0800
excerpt: "从 sensor 嵌入式数据到 ISP 3A 统计信息，详解 camera metadata 在硬件、内核驱动和用户空间各层的表现形式和数据结构。"
---

# Camera Metadata 从硬件到软件完整详解

## 一、硬件层面：Metadata 的来源

### 1.1 Sensor 嵌入式数据（Embedded Data Lines）

Sensor 芯片在输出每帧图像时，会在有效像素行的前面或后面附加几行"非图像数据"：

```
一帧 CSI-2 传输的完整内容：

┌─────────────────────────────────────────────────┐
│ Frame Start (FS) 短包                            │  ← CSI-2 协议帧开始标记
├─────────────────────────────────────────────────┤
│ Embedded Data Line 0  (Data Type = 0x12)        │  ← 寄存器镜像：曝光、增益
│ Embedded Data Line 1  (Data Type = 0x12)        │  ← 帧计数、温度、时间戳
├─────────────────────────────────────────────────┤
│ Image Line 0          (Data Type = 0x2B=Raw10)  │  ← 真正的像素数据开始
│ Image Line 1                                     │
│ ...                                              │
│ Image Line 1943                                  │  ← 最后一行像素
├─────────────────────────────────────────────────┤
│ Embedded Data Line N  (Data Type = 0x12)        │  ← (可选) 帧尾统计
├─────────────────────────────────────────────────┤
│ Frame End (FE) 短包                              │  ← CSI-2 协议帧结束标记
└─────────────────────────────────────────────────┘
```

**Embedded data 的物理内容**（以 OV5647/IMX219 为例）：

```
Embedded Line 0 (字节流):
┌────┬────┬────┬────┬────┬────┬────┬────┬────────────────┐
│0x0A│0x0A│0x0A│0x0A│0x3D│0x01│0x00│0x10│ ...            │
└────┴────┴────┴────┴────┴────┴────┴────┴────────────────┘
 │              │         │         │
 │              │         │         └─ 寄存器值 (如 analog gain = 0x10)
 │              │         └─ 寄存器地址 (如 0x0157 = analog gain reg)
 │              └─ Tag byte (0x3D = valid register data)
 └─ Padding / line sync

实际就是 sensor 内部寄存器的镜像，告诉你这一帧
实际用了什么曝光时间、增益、帧号等。
```

**为什么需要 embedded data？**

因为 sensor 的寄存器设置和实际生效之间有延迟（通常 2-3 帧）。你在第 N 帧设置了曝光=10ms，可能第 N+2 帧才生效。Embedded data 告诉你"这一帧实际用的参数是什么"。

### 1.2 CSI-2 Data Type 区分

CSI-2 协议用 Data Type 字段区分不同类型的数据：

```
Data Type    含义                    用途
─────────────────────────────────────────────────
0x00-0x07    短包 (Frame/Line Sync)  帧/行同步
0x12         Embedded 8-bit          Sensor 嵌入式数据
0x2A         Raw 8-bit               8bit 图像
0x2B         Raw 10-bit              10bit 图像 (OV5647)
0x2C         Raw 12-bit              12bit 图像
0x2D         Raw 14-bit              14bit 图像
```

CSI-2 接收器（CSI RX）硬件根据 Data Type 将数据路由到不同的 DMA 通道：

```
CSI-2 总线
    │
    ├─ DT=0x2B → DMA Channel 0 → DDR (图像 buffer)
    │
    └─ DT=0x12 → DMA Channel 1 → DDR (metadata buffer)
```

## 二、CSI 接收器硬件

### 2.1 硬件寄存器配置

```c
/* CSI-2 接收器需要配置哪些 virtual channel / data type 要捕获 */

/* 以 imx8 MIPI CSI-2 为例，寄存器配置: */
/*
 * CH0_CFG: data_type=0x2B, virtual_channel=0  → 图像
 * CH1_CFG: data_type=0x12, virtual_channel=0  → embedded data
 *
 * 每个 channel 有独立的 DMA 目标地址和 buffer 大小
 */

/* 硬件框图:
 *
 * MIPI D-PHY → CSI-2 Controller → VC/DT Demux → CH0 DMA → DDR (image)
 *                                              → CH1 DMA → DDR (metadata)
 */
```

## 三、内核驱动层

### 3.1 CSI 驱动：区分 image 和 metadata

```c
/* CSI 驱动为 image 和 metadata 创建不同的 pad/video node */

struct csi_device {
    struct v4l2_subdev sd;
    struct media_pad pads[3];
    /* pad 0: sink (来自 sensor) */
    /* pad 1: source (image → ISP 或 video node) */
    /* pad 2: source (embedded data → meta video node) */
};
```

### 3.2 Video Device 注册

```c
/* 驱动注册两种 video device */

/* 图像捕获节点: /dev/video0 */
struct video_device vdev_image = {
    .name = "csi-capture",
    .vfl_type = VFL_TYPE_VIDEO,        /* 普通视频设备 */
    .device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING,
};

/* Metadata 捕获节点: /dev/video1 */
struct video_device vdev_meta = {
    .name = "csi-meta",
    .vfl_type = VFL_TYPE_VIDEO,        /* 也是 video 设备 */
    .device_caps = V4L2_CAP_META_CAPTURE | V4L2_CAP_STREAMING,
};
```

### 3.3 Metadata 格式描述

```c
/* 用户空间通过 ioctl 查询 metadata 格式 */
struct v4l2_format {
    __u32 type;                         /* V4L2_BUF_TYPE_META_CAPTURE */
    union {
        struct v4l2_meta_format meta;
        ...
    } fmt;
};

struct v4l2_meta_format {
    __u32 dataformat;    /* 如 V4L2_META_FMT_GENERIC_8
                          *    V4L2_META_FMT_IMX219_EMBEDDED
                          *    V4L2_META_FMT_SENSOR_DATA */
    __u32 buffersize;    /* 一帧 metadata 的字节数
                          * = embedded_lines × line_width
                          * 如 2 lines × 2592 bytes = 5184 bytes */
};
```

### 3.4 DMA Buffer 中 Metadata 的内存布局

```c
/* Embedded data buffer 内容 (mmap 后用户空间看到的) */

/*
 * 以 IMX219 为例, 2 行 embedded data, 每行宽度同图像宽度:
 *
 * Offset 0x0000: Line 0 (3280 bytes)
 *   ┌──────────────────────────────────────────────────────┐
 *   │ Tag │ Reg_H │ Reg_L │ Value │ Tag │ Reg_H │ ...     │
 *   │ 0xAA│ 0x01  │ 0x5A  │ 0x04  │ 0xAA│ 0x01  │ ...     │
 *   └──────────────────────────────────────────────────────┘
 *         │         │         │
 *         │         │         └─ coarse_integration_time[15:8] = 0x04
 *         │         └─ register address 0x015A
 *         └─ tag: valid data
 *
 * Offset 0x0CD0: Line 1 (3280 bytes)
 *   ┌──────────────────────────────────────────────────────┐
 *   │ 更多寄存器镜像数据 ...                                 │
 *   └──────────────────────────────────────────────────────┘
 */

/* 解析 embedded data 得到实际参数: */
struct sensor_embedded_info {
    uint32_t frame_count;           /* 帧计数器 */
    uint32_t coarse_integration;    /* 曝光行数 (曝光时间 = 行数 × 行时间) */
    uint16_t analog_gain;           /* 模拟增益 */
    uint16_t digital_gain;          /* 数字增益 */
    uint16_t frame_length;          /* 帧长度 (用于计算帧率) */
    uint16_t line_length;           /* 行长度 */
    uint8_t  sensor_mode;           /* 当前模式 */
    int8_t   temperature;           /* 芯片温度 */
};
```

## 四、ISP 统计信息（3A Stats）

### 4.1 硬件产生统计数据

```
ISP 硬件内部:

Raw 图像数据 ──→ ┌─────────────────────────────────────────┐
                  │ ISP Pipeline                             │
                  │                                          │
                  │  ┌─────────┐   ┌─────────┐   ┌──────┐  │
                  │  │ BLC     │→  │ LSC     │→  │ AWB  │  │
                  │  │黑电平校正│   │镜头阴影 │   │白平衡│  │
                  │  └─────────┘   └─────────┘   └──┬───┘  │
                  │                                   │      │
                  │  ┌─────────┐   ┌─────────┐       │      │
                  │  │ AE 统计 │   │ AF 统计 │       │      │
                  │  │ 模块    │   │ 模块    │       │      │
                  │  └────┬────┘   └────┬────┘       │      │
                  │       │             │             │      │
                  └───────┼─────────────┼─────────────┼──────┘
                          │             │             │
                          ▼             ▼             ▼
                  ┌─────────────────────────────────────────┐
                  │ Stats DMA → DDR (stats buffer)          │
                  │                                          │
                  │ AE: 每个区域的亮度均值/直方图             │
                  │ AWB: 每个区域的 R/G/B 均值               │
                  │ AF: 每个区域的高频分量(锐度)             │
                  └─────────────────────────────────────────┘
```

### 4.2 Stats 数据结构

```c
/* 以 rkisp1 为例 (各平台结构不同但概念相同) */

/* AE 统计: 将图像分成 5×5=25 个区域 */
struct rkisp1_cif_isp_ae_stat {
    __u8 exp_mean[25];    /* 每个区域的平均亮度 (0-255) */
    /*
     * 图像被分成 5×5 网格:
     * ┌────┬────┬────┬────┬────┐
     * │ 45 │ 50 │ 52 │ 48 │ 44 │  ← 各区域平均亮度
     * ├────┼────┼────┼────┼────┤
     * │ 60 │128 │135 │130 │ 58 │
     * ├────┼────┼────┼────┼────┤
     * │ 65 │140 │180 │138 │ 62 │  ← 中心最亮(主体)
     * ├────┼────┼────┼────┼────┤
     * │ 55 │120 │125 │118 │ 52 │
     * ├────┼────┼────┼────┼────┤
     * │ 40 │ 45 │ 48 │ 44 │ 38 │
     * └────┴────┴────┴────┴────┘
     */
};

/* AWB 统计: 每个区域的颜色信息 */
struct rkisp1_cif_isp_awb_stat {
    struct {
        __u16 mean_r;     /* 区域内红色均值 */
        __u16 mean_g;     /* 区域内绿色均值 */
        __u16 mean_b;     /* 区域内蓝色均值 */
        __u16 pixel_cnt;  /* 有效像素数 */
    } awb_mean[25];
    /*
     * 用户空间 AWB 算法根据这些值计算:
     * R_gain = G_mean / R_mean
     * B_gain = G_mean / B_mean
     * 使得白色物体的 R=G=B
     */
};

/* AF 统计: 对焦锐度 */
struct rkisp1_cif_isp_af_stat {
    struct {
        __u32 sharpness;   /* 高通滤波后的能量值 */
        __u32 luminance;   /* 区域亮度 */
    } af_window[3];        /* 通常 3 个对焦窗口 */
    /*
     * 对焦算法移动镜头，找到 sharpness 最大的位置
     *
     * sharpness
     *    ▲
     *    │      ╱╲
     *    │     ╱  ╲
     *    │    ╱    ╲
     *    │   ╱      ╲
     *    │──╱────────╲──→ 镜头位置
     *              ↑
     *          最佳对焦点
     */
};

/* 直方图 */
struct rkisp1_cif_isp_hist_stat {
    __u32 hist_bins[32];   /* 32 个亮度区间的像素计数 */
    /*
     * hist_bins[0]  = 暗部像素数 (亮度 0-7)
     * hist_bins[1]  = 亮度 8-15 的像素数
     * ...
     * hist_bins[31] = 最亮像素数 (亮度 248-255)
     *
     *  像素数
     *    ▲
     *    │   ██
     *    │   ██ ██
     *    │██ ██ ██ ██
     *    │██ ██ ██ ██    ██
     *    │██ ██ ██ ██ ██ ██
     *    └──────────────────→ 亮度
     *    暗              亮
     */
};
```

## 五、3A 参数的两条控制路径

3A 参数并不是只配置在 ISP 上，实际上分为两条路径：

```
┌────────────────────────────────────────────────────────────────┐
│ 路径 1: 控制 Sensor (通过 V4L2 control / I2C)                   │
│                                                                 │
│ 用户空间 → VIDIOC_S_CTRL → sensor subdev → I2C → sensor 寄存器 │
│                                                                 │
│ 控制内容:                                                       │
│   - 曝光时间 (V4L2_CID_EXPOSURE)                                │
│   - 模拟增益 (V4L2_CID_ANALOGUE_GAIN)                           │
│   - 数字增益 (V4L2_CID_DIGITAL_GAIN)                            │
│   - 翻转 (V4L2_CID_HFLIP / V4L2_CID_VFLIP)                    │
│   - 测试图案 (V4L2_CID_TEST_PATTERN)                            │
│                                                                 │
│ 为什么必须在 sensor 端:                                          │
│   曝光和增益控制的是物理进光量和信号放大，                         │
│   ISP 收到的 Raw 数据亮度已经固定，无法事后改变。                  │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ 路径 2: 控制 ISP (通过 meta output buffer)                      │
│                                                                 │
│ 用户空间 → meta output video node → ISP 硬件寄存器              │
│                                                                 │
│ 控制内容:                                                       │
│   - 白平衡增益 (AWB gain)                                       │
│   - 色彩校正矩阵 (CCM)                                          │
│   - Gamma 曲线                                                  │
│   - 镜头阴影校正 (LSC)                                          │
│   - 坏点校正 (DPCC)                                             │
│   - 降噪参数 (NR)                                               │
│                                                                 │
│ 为什么在 ISP 端:                                                 │
│   这些是对已采集 Raw 数据的数学运算，                              │
│   在 ISP 做更灵活，且不同 sensor 可以共用同一套 ISP 算法。        │
└────────────────────────────────────────────────────────────────┘
```

两者配合才是完整的 3A 控制：

```
AE 算法 → 输出曝光/增益 → 写 Sensor (路径 1)
AWB 算法 → 输出白平衡增益/CCM → 写 ISP (路径 2)
AF 算法 → 输出对焦位置 → 写 Lens Actuator subdev (也是路径 1 的方式)
```

对应的内核接口：

```c
/* 路径 1: V4L2 control 写 sensor */
struct v4l2_control ctrl = {
    .id = V4L2_CID_EXPOSURE,
    .value = 1000,  /* 曝光行数 */
};
ioctl(sensor_fd, VIDIOC_S_CTRL, &ctrl);
/* 驱动内部: i2c_write(client, EXPOSURE_REG, 1000) */

/* 路径 2: meta output buffer 写 ISP */
struct rkisp1_params_cfg *params = mmap(...);
params->awb_gain.gain_red = 307;   /* 1.2x */
params->awb_gain.gain_blue = 384;  /* 1.5x */
ioctl(params_fd, VIDIOC_QBUF, &buf);
/* 驱动内部: writel(307, isp_base + AWB_GAIN_R_REG) */
```

## 六、ISP 参数输入详细数据结构

### 6.1 用户空间算法计算结果写回 ISP

```c
/* 用户空间 3A 算法 (如 libcamera 的 IPA) 计算出参数后，
 * 通过 meta output video node 写入 ISP */

struct rkisp1_params_cfg {
    __u32 module_en_update;    /* 哪些模块需要更新 */
    __u32 module_ens;          /* 模块使能位 */
    __u32 module_cfg_update;   /* 哪些模块配置需要更新 */

    /* 各模块参数: */
    struct rkisp1_cif_isp_awb_gain_config awb_gain;
    struct rkisp1_cif_isp_aec_config aec;
    struct rkisp1_cif_isp_bls_config bls;       /* 黑电平 */
    struct rkisp1_cif_isp_dpcc_config dpcc;     /* 坏点校正 */
    struct rkisp1_cif_isp_lsc_config lsc;       /* 镜头阴影校正 */
    struct rkisp1_cif_isp_ccm_config ccm;       /* 色彩校正矩阵 */
    struct rkisp1_cif_isp_goc_config goc;       /* Gamma */
    ...
};

/* AWB 增益参数 */
struct rkisp1_cif_isp_awb_gain_config {
    __u16 gain_red;        /* 如 1.2x = 307 (256=1.0x) */
    __u16 gain_green_r;    /* 1.0x = 256 */
    __u16 gain_green_b;    /* 1.0x = 256 */
    __u16 gain_blue;       /* 如 1.5x = 384 */
};

/* 色彩校正矩阵 3×3 */
struct rkisp1_cif_isp_ccm_config {
    __s16 matrix[3][3];
    /*  ┌                    ┐   ┌   ┐     ┌   ┐
     *  │ 1.8  -0.5  -0.3   │   │ R │     │ R'│
     *  │-0.2   1.6  -0.4   │ × │ G │  =  │ G'│
     *  │-0.1  -0.6   1.7   │   │ B │     │ B'│
     *  └                    ┘   └   ┘     └   ┘
     */
    __s16 offsets[3];      /* RGB 偏移 */
};
```

## 七、用户空间 3A 控制循环

```
┌─────────────────────────────────────────────────────────┐
│                    用户空间 (libcamera IPA)              │
│                                                          │
│   ┌──────────┐     ┌──────────┐     ┌──────────┐       │
│   │ AE 算法  │     │ AWB 算法 │     │ AF 算法  │       │
│   │          │     │          │     │          │       │
│   │ 输入:    │     │ 输入:    │     │ 输入:    │       │
│   │  ae_stat │     │ awb_stat │     │ af_stat  │       │
│   │  hist    │     │          │     │          │       │
│   │          │     │          │     │          │       │
│   │ 输出:    │     │ 输出:    │     │ 输出:    │       │
│   │ exposure │     │ awb_gain │     │ lens_pos │       │
│   │ gain     │     │ ccm      │     │          │       │
│   └─────┬────┘     └─────┬────┘     └─────┬────┘       │
│         │                 │                 │            │
└─────────┼─────────────────┼─────────────────┼────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
┌─────────────────┐  ┌──────────────┐  ┌──────────────┐
│ V4L2 控制       │  │ Meta output  │  │ V4L2 控制    │
│ VIDIOC_S_CTRL   │  │ params buffer│  │ (lens subdev)│
│ → sensor 寄存器 │  │ → ISP 寄存器 │  │ → 马达驱动   │
│ (曝光/增益)     │  │ (AWB/CCM/γ)  │  │ (对焦位置)   │
└────────┬────────┘  └──────┬───────┘  └──────┬───────┘
         │                   │                  │
         ▼                   ▼                  ▼
┌─────────────────────────────────────────────────────────┐
│                      硬件                                │
│  Sensor          ISP                    Lens Actuator   │
│  (新曝光/增益)   (新白平衡/色彩)        (新焦距)        │
│       │               │                      │          │
│       └───────────────┼──────────────────────┘          │
│                       ▼                                  │
│              下一帧图像 + 新的 stats                      │
│                       │                                  │
└───────────────────────┼──────────────────────────────────┘
                        │
                        ▼
                回到用户空间 3A 算法 (循环)
```

## 八、时间同步：Metadata 与图像帧的对应

```c
/* 关键问题: 如何保证 stats 和 params 与正确的帧对应？ */

/* V4L2 Request API 解决这个问题 */
struct media_request {
    /* 一个 request 绑定了同一帧的所有 buffer 和控制 */
};

/*
 * 时间线:
 *
 * 帧 N:   sensor 曝光 → CSI 传输 → ISP 处理 → image buffer N 完成
 *                                            → stats buffer N 完成
 *                                                    │
 *                                                    ▼
 *         用户空间收到 stats N → 3A 算法计算 → 产生 params
 *                                                    │
 *                                                    ▼
 *         params 写入 → ISP 在帧 N+1 或 N+2 应用
 *         sensor ctrl → sensor 在帧 N+2 或 N+3 生效
 *
 * 延迟 (pipeline delay):
 *   sensor 设置到生效: 通常 2 帧
 *   ISP params 到生效: 通常 1 帧
 *   总 3A 收敛延迟: 3-5 帧
 */

/* 每个 buffer 带时间戳用于匹配 */
struct v4l2_buffer {
    ...
    struct timeval timestamp;    /* 帧捕获时间 */
    __u32 sequence;              /* 帧序号，image/stats/embedded 用同一序号匹配 */
};
```

## 九、libcamera 中的 Metadata

```c
/* libcamera 在用户空间统一管理 metadata */
/* 每帧的 Request 包含: */

/*
 * Request {
 *     ├─ Stream buffer (图像数据)
 *     ├─ ControlList metadata (输出):
 *     │    ExposureTime: 33333 us
 *     │    AnalogueGain: 2.0
 *     │    ColourTemperature: 5500K
 *     │    SensorTimestamp: 123456789 ns
 *     │    Lux: 300
 *     │
 *     └─ ControlList controls (输入):
 *          AeEnable: true
 *          AwbMode: Auto
 *          Brightness: 0.0
 * }
 */
```

## 十、完整 Pipeline（含 Metadata）

```
┌─────────────────────────────────────────────────────────────┐
│ Sensor                                                       │
│  ├─ source pad 0: image data (Raw10 GBRG)                   │
│  └─ source pad 1: embedded metadata (寄存器镜像/统计)        │
└──────────┬────────────────────────┬─────────────────────────┘
           │ CSI-2 (DT=0x2B)       │ CSI-2 (DT=0x12)
           ▼                        ▼
┌──────────────────────┐  ┌────────────────────────┐
│ CSI Receiver         │  │ CSI Receiver           │
│ image path           │  │ embedded data path     │
└──────────┬───────────┘  └────────────┬───────────┘
           │                            │
           ▼                            ▼
┌──────────────────────┐  ┌────────────────────────┐
│ ISP                  │  │ /dev/videoX (meta cap) │
│  ├─ 处理图像         │  │ V4L2_META_FMT_xxx     │
│  ├─ 产生 3A stats ──────→ /dev/videoY (stats)   │
│  └─ 接收 3A params ←────── /dev/videoZ (params) │
└──────────┬───────────┘  └────────────────────────┘
           │
           ▼
┌──────────────────────┐
│ /dev/video0          │
│ 处理后的 YUV/RGB     │
└──────────────────────┘
```

## 十一、总结：Metadata 在各层的表现

```
层次          图像数据                    Metadata
─────────────────────────────────────────────────────────────────
物理层        光子 → 电子 → ADC           sensor 寄存器状态

CSI-2 总线    DT=0x2B (Raw10)            DT=0x12 (Embedded)
              长包, 每行一个包             长包, 1-2 行

CSI RX 硬件   DMA CH0 → DDR              DMA CH1 → DDR

内核驱动      /dev/video0                 /dev/video1
              V4L2_BUF_TYPE_VIDEO_CAPTURE V4L2_BUF_TYPE_META_CAPTURE
              v4l2_pix_format             v4l2_meta_format

ISP 硬件      处理图像                    产生 3A stats
                                          接收 3A params

ISP 驱动      /dev/video0 (输出YUV)       /dev/video1 (stats 输出)
                                          /dev/video2 (params 输入)

用户空间      显示/编码/存储              3A 算法输入/输出
(libcamera)   FrameBuffer                 ControlList / metadata
```
