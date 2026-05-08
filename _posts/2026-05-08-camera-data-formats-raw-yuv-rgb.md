---
layout: post
title: "Camera 数据格式全解：Raw、YUV、RGB 与色彩空间转换"
date: 2026-05-08 16:00:00 +0800
excerpt: "从 sensor Raw Bayer 到 ISP 输出的 YUV/RGB，详解各种像素格式的内存布局、采样方式，以及色彩空间转换在硬件流水线中的位置。"
---

# Camera 数据格式全解：Raw、YUV、RGB 与色彩空间转换

## 一、数据流水线总览

```
传感器 → Raw Bayer → ISP 处理 → RGB → 色彩空间转换 → YUV
                                  ↓                      ↓
                              直接输出               编码/显示
```

Camera 系统中的图像数据经历三个阶段：

1. **Sensor 输出 Raw Bayer** — 每像素单通道原始数据
2. **ISP 处理得到 RGB** — demosaic + 图像增强
3. **色彩空间转换得到 YUV** — 为编码和显示优化

---

## 二、Raw 数据格式

Raw 是图像传感器直接输出的未经处理的原始数据。每个像素只记录一个颜色通道的值（通过 Bayer 滤镜阵列）。

### 2.1 Bayer 排列模式

传感器上的 Bayer 滤镜有 4 种排列方式（指 2x2 单元的起始顺序）：

```
RGGB:          BGGR:          GRBG:          GBRG:
┌───┬───┐      ┌───┬───┐      ┌───┬───┐      ┌───┬───┐
│ R │ G │      │ B │ G │      │ G │ R │      │ G │ B │
├───┼───┤      ├───┼───┤      ├───┼───┤      ├───┼───┤
│ G │ B │      │ G │ R │      │ B │ G │      │ R │ G │
└───┴───┘      └───┴───┘      └───┴───┘      └───┴───┘
```

| 模式 | V4L2 格式前缀 | 典型 Sensor |
|------|---------------|-------------|
| RGGB | `SRGGB` | IMX477 |
| BGGR | `SBGGR` | IMX219 |
| GRBG | `SGRBG` | AR0234 |
| GBRG | `SGBRG` | OV5647 |

### 2.2 位深度变体

| 位深 | 值范围 | V4L2 示例 | 存储方式 |
|------|--------|-----------|----------|
| 8-bit | 0-255 | `V4L2_PIX_FMT_SRGGB8` | 每像素 1 字节，紧凑排列 |
| 10-bit | 0-1023 | `V4L2_PIX_FMT_SRGGB10` | 16-bit 容器，高位或低位对齐 |
| 10-bit packed | 0-1023 | `V4L2_PIX_FMT_SRGGB10P` | 每 4 像素占 5 字节 |
| 12-bit | 0-4095 | `V4L2_PIX_FMT_SRGGB12` | 16-bit 容器 |
| 12-bit packed | 0-4095 | `V4L2_PIX_FMT_SRGGB12P` | 每 2 像素占 3 字节 |
| 14-bit | 0-16383 | `V4L2_PIX_FMT_SRGGB14` | 16-bit 容器 |
| 16-bit | 0-65535 | `V4L2_PIX_FMT_SRGGB16` | 原生 16-bit |

### 2.3 Packed vs Unpacked 存储

**10-bit Packed（每 4 像素 = 5 字节）：**

```
字节0: [P0 高8位]
字节1: [P1 高8位]
字节2: [P2 高8位]
字节3: [P3 高8位]
字节4: [P0低2 | P1低2 | P2低2 | P3低2]

文件大小 = width × height × 10 / 8
```

**10-bit Unpacked（每像素 = 2 字节）：**

```
字节0-1: P0 (uint16, 高6位补零或左移)
字节2-3: P1 (uint16)
...

文件大小 = width × height × 2
```

Packed 省空间（节省 25%），Unpacked 方便处理（直接当 uint16 数组读取）。

---

## 三、YUV 数据格式

YUV 将亮度（Y）和色度（U/V，也称 Cb/Cr）分离。人眼对亮度更敏感，因此色度可以降采样以节省带宽。

### 3.1 色度采样方式

```
4:4:4  — 每个像素都有完整的 Y、U、V（无压缩）
4:2:2  — 水平方向每 2 个像素共享一组 UV（色度水平减半）
4:2:0  — 每 2x2 像素块共享一组 UV（色度水平和垂直都减半）
4:1:1  — 水平方向每 4 个像素共享一组 UV（较少使用）
```

视觉对比：

```
原始像素:    ● ● ● ●
             ● ● ● ●

4:4:4 色度:  ◆ ◆ ◆ ◆    每个像素都有独立 UV
             ◆ ◆ ◆ ◆

4:2:2 色度:  ◆   ◆       水平每 2 像素共享
             ◆   ◆

4:2:0 色度:  ◆   ◆       2x2 块共享一个 UV
```

### 3.2 Packed 格式（交织存储）

Y 和 UV 数据交织在同一平面中，每 2 个像素为一组：

| 格式 | 字节排列（每 2 像素） | 采样 | 每像素字节 |
|------|----------------------|------|-----------|
| YUYV (YUY2) | Y0 U0 Y1 V0 | 4:2:2 | 2 |
| UYVY | U0 Y0 V0 Y1 | 4:2:2 | 2 |
| YVYU | Y0 V0 Y1 U0 | 4:2:2 | 2 |
| VYUY | V0 Y0 U0 Y1 | 4:2:2 | 2 |

**YUYV 是 USB 摄像头（UVC）最常见的输出格式。**

### 3.3 Semi-Planar 格式（半平面）

Y 单独一个平面，UV 交织在第二个平面：

| 格式 | 平面结构 | 采样 | 每像素字节 |
|------|----------|------|-----------|
| NV12 | Plane0: YYYY... Plane1: UVUV... | 4:2:0 | 1.5 |
| NV21 | Plane0: YYYY... Plane1: VUVU... | 4:2:0 | 1.5 |
| NV16 | Plane0: YYYY... Plane1: UVUV... | 4:2:2 | 2 |
| NV61 | Plane0: YYYY... Plane1: VUVU... | 4:2:2 | 2 |

**NV12 是硬件编解码器（H.264/H.265）的首选输入格式。**

### 3.4 Planar 格式（全平面）

Y、U、V 各自独立存储在不同平面：

| 格式 | 平面结构 | 采样 | 每像素字节 |
|------|----------|------|-----------|
| YU12 (I420) | Y / U / V | 4:2:0 | 1.5 |
| YV12 | Y / V / U | 4:2:0 | 1.5 |
| YUV422P | Y / U / V | 4:2:2 | 2 |
| YUV444P | Y / U / V | 4:4:4 | 3 |

**I420 是软件编解码（FFmpeg/x264）常用格式。**

### 3.5 内存布局示例（4x2 图像）

**YUYV (4:2:2 packed)：**

```
字节流: Y00 U00 Y01 V00 | Y02 U02 Y03 V02
        Y10 U10 Y11 V10 | Y12 U12 Y13 V12
总大小: 4 × 2 × 2 = 16 字节
```

**NV12 (4:2:0 semi-planar)：**

```
Y 平面:  Y00 Y01 Y02 Y03
          Y10 Y11 Y12 Y13

UV 平面: U00 V00 U02 V02   ← 2x2 像素块共享一组 UV

总大小: (4×2) + (4×1) = 12 字节 = 4×2×1.5
```

**I420 (4:2:0 planar)：**

```
Y 平面:  Y00 Y01 Y02 Y03
          Y10 Y11 Y12 Y13

U 平面:  U00 U02            ← 宽高各减半

V 平面:  V00 V02

总大小: 8 + 2 + 2 = 12 字节
```

---

## 四、RGB 数据格式

RGB 是 ISP demosaic 后的直接产物，每个像素包含完整的红、绿、蓝三通道值。

### 4.1 常见 RGB 格式

| 格式 | 每像素字节 | 位分配 | 典型用途 |
|------|-----------|--------|---------|
| RGB24 (RGB888) | 3 | R:8 G:8 B:8 | 通用图像处理 |
| BGR24 | 3 | B:8 G:8 R:8 | OpenCV 默认 |
| ARGB32 (RGB8888) | 4 | A:8 R:8 G:8 B:8 | 带透明度合成 |
| RGB565 | 2 | R:5 G:6 B:5 | 嵌入式 LCD 显示 |
| RGB444 | 2 | R:4 G:4 B:4 | 低端显示 |

### 4.2 为什么大多数 camera 输出 YUV 而不是 RGB

| 原因 | 说明 |
|------|------|
| 带宽小 | YUV 4:2:0 比 RGB24 节省 50% 数据量 |
| 编码友好 | H.264/H.265 编码器直接接受 YUV 输入 |
| 符合人眼特性 | 人眼对亮度敏感、对色度不敏感 |
| 视频标准 | 电视、监控历史上就是 YUV 体系 |

---

## 五、色彩空间转换（CSC）

### 5.1 转换公式

RGB → YUV（BT.601 标准）：

```
Y  =  0.299R + 0.587G + 0.114B
U  = -0.169R - 0.331G + 0.500B + 128
V  =  0.500R - 0.419G - 0.081B + 128
```

YUV → RGB（反向）：

```
R = Y + 1.402(V - 128)
G = Y - 0.344(U - 128) - 0.714(V - 128)
B = Y + 1.772(U - 128)
```

硬件实现时用定点数矩阵运算，一个时钟周期完成。

### 5.2 谁来完成色彩空间转换

色彩空间转换可以在多个环节完成：

**1. ISP 硬件（最常见）**

大多数 SoC 的 ISP 内部集成了 CSC 模块，demosaic 得到 RGB 后直接在硬件流水线内转成 YUV 输出。零 CPU 开销，实时处理。

**2. 专用硬件转换模块**

有些 SoC 有独立于 ISP 的 CSC 硬件：

| 平台 | CSC 硬件模块 | 功能 |
|------|-------------|------|
| NXP i.MX | PXP (Pixel Pipeline) / GPU 2D | CSC + 缩放 + 旋转 |
| Rockchip (RK3588等) | RGA (Raster Graphic Acceleration) | CSC + 缩放 + 旋转 + 合成 |
| TI (AM62x/AM68x) | VPAC ISP + DSS | ISP 处理 + 显示 CSC |
| Allwinner (H616等) | G2D + DE (Display Engine) | 2D 加速 + 显示 CSC |
| Samsung (Exynos) | FIMC / M2M Scaler | CSC + 缩放 |
| MediaTek | MDP (Media Data Path) | CSC + 缩放 + 旋转 |
| Intel (x86) | GPU EU + 显示引擎 | 通用计算 + 显示 CSC |

**3. 显示控制器内部 CSC**

显示时需要将 YUV 转回 RGB 送屏幕，由显示控制器硬件完成：

```
ISP 输出 NV12 → 显示控制器(CSC) → RGB → LCD/HDMI
```

**4. GPU（shader）**

通过 OpenGL ES shader 做矩阵运算，适合相机预览渲染。

**5. CPU 软件**

用库函数做转换（FFmpeg libswscale、OpenCV cvtColor、libyuv）。灵活但吃 CPU，仅用于调试或低帧率场景。

### 5.3 典型数据流

```
摄像头 Sensor → Raw Bayer
       ↓
ISP (demosaic → RGB → CSC) → NV12
       ↓                        ↓
  H.264 编码器            显示控制器 (CSC: YUV→RGB) → HDMI/LCD
```

---

## 六、树莓派的 CSC 硬件

树莓派 (Broadcom BCM2835/2837/2711/2712) 有多个硬件模块可以做色彩空间转换：

### 6.1 VideoCore ISP

VideoCore GPU 内置 ISP，通过 V4L2 M2M 设备节点暴露（`/dev/video12`、`/dev/video13` 等）：

- Demosaic（Raw → RGB）
- RGB ↔ YUV 转换
- 缩放、裁剪、降噪

在 libcamera 框架下，应用把 Raw Bayer 送进去，拿到 YUV/RGB 输出。

### 6.2 HVS（Hardware Video Scaler）

显示流水线中的硬件模块：

- YUV → RGB 转换（送显示器前）
- 缩放、合成多个图层

### 6.3 H.264/H.265 编解码器

编码器前端自带格式转换，接受特定 YUV 格式输入。

### 6.4 树莓派实际数据流

```
摄像头 Sensor → Raw Bayer
       ↓
VideoCore ISP (M2M) → NV12
       ↓                  ↓
H.264 编码器         HVS (YUV→RGB) → HDMI/DSI 显示
```

整条流水线都是硬件完成，CPU 基本不参与像素处理。

---

## 七、数据量对比（1920x1080）

| 格式 | 计算 | 大小 |
|------|------|------|
| Raw 8-bit | 1920×1080×1 | 2.0 MB |
| Raw 10-bit packed | 1920×1080×10/8 | 2.5 MB |
| Raw 10-bit unpacked | 1920×1080×2 | 4.1 MB |
| YUV 4:2:0 (NV12) | 1920×1080×1.5 | 3.1 MB |
| YUV 4:2:2 (YUYV) | 1920×1080×2 | 4.1 MB |
| YUV 4:4:4 | 1920×1080×3 | 6.2 MB |
| RGB24 | 1920×1080×3 | 6.2 MB |
| ARGB32 | 1920×1080×4 | 8.3 MB |

---

## 八、实际使用场景总结

| 格式 | 典型场景 |
|------|---------|
| Raw Bayer | ISP 输入、专业摄影后期、需要最大灵活性 |
| NV12/NV21 | 硬件编解码器输入、Android Camera HAL 默认输出 |
| YUYV | USB 摄像头（UVC）最常见输出 |
| I420 | 软件编解码（FFmpeg/x264） |
| RGB24/BGR24 | 图像处理、OpenCV、神经网络推理输入 |
| RGB565 | 嵌入式 LCD 直接显示 |

---

## 九、V4L2 中查看和设置格式

```bash
# 查看设备支持的格式
v4l2-ctl -d /dev/video0 --list-formats-ext

# 设置捕获格式为 NV12
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=NV12

# 设置捕获格式为 YUYV
v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480,pixelformat=YUYV

# Media Controller 中设置 media bus format
media-ctl -d /dev/media0 -V '"sensor":0 [fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 -V '"isp":1 [fmt:UYVY8_1X16/1920x1080]'
```

---

*Date: <time datetime="2026-05-08T16:00:00+08:00">8th May 2026</time>*
