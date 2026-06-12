---
layout: post
title: "Linux Media Controller 实战指南：拓扑查看、Link 配置与问题排查"
date: 2026-04-28 16:00:00 +0800
excerpt: "详解 Linux Media Controller 框架原理，如何用 media-ctl 查看拓扑、诊断未启用的 link、配置 pipeline 格式，以 i.MX8MP + OV5640 为实例。"
---

# Linux Media Controller 实战指南

## 1. 为什么需要 Media Controller

在 SoC 平台（如 NXP i.MX8MP）上，图像采集不是单一设备完成的，而是由多个硬件模块组成一条流水线：

```
Camera Sensor (ov5640)
       ↓  MIPI CSI-2 总线
MIPI CSI Receiver (CSIS)
       ↓
Crossbar Switch（路由交换）
       ↓
ISI（Image Sensing Interface，缩放/颜色转换）
       ↓
DMA → 内存 → /dev/videoX
```

传统 V4L2 的"一个 `/dev/videoX` 管一切"无法描述这种复杂拓扑，因此 Linux 引入了 **Media Controller** 框架，通过 `/dev/mediaX` 节点来管理整条流水线的连接关系和格式配置。

简单说：
- **`/dev/mediaX`**：管"怎么连、什么格式"（用 `media-ctl` 操作）
- **`/dev/videoX`**：管"读写数据"（用 `v4l2-ctl` 或 gstreamer 操作）

## 2. 核心概念

### Entity（实体）

每个硬件模块是一个 entity，有两种类型：

| 类型 | 说明 | 设备节点 | 能否读写数据 |
|------|------|----------|-------------|
| V4L2 subdev | 中间处理节点（sensor、CSI、crossbar、ISI） | `/dev/v4l-subdevX` | 否，只能配置 |
| Node | 端点节点（capture、output） | `/dev/videoX` | 是 |

### Pad（端口）

每个 entity 有一个或多个 pad：

- **SINK**：输入端，接收数据
- **SOURCE**：输出端，发送数据

每个 pad 上有独立的格式配置（像素格式、分辨率等）。

### Link（连接）

pad 之间的连接，有以下状态标志：

| Flag | 含义 |
|------|------|
| `[]`（空） | link 存在但**未启用**，数据不流通 |
| `[ENABLED]` | 已激活，数据可以流过，可以禁用 |
| `[ENABLED,IMMUTABLE]` | 已激活且硬件固定，软件不能修改 |
| `[DYNAMIC]` | 可以在 streaming 过程中动态改变 |

### Format（格式）

每个 pad 上都有格式配置，包括 media bus format（如 `UYVY8_1X16`）、分辨率、帧率、颜色空间等。

**核心原则：相邻 pad 的格式必须匹配。** SOURCE pad 输出什么格式，下一个 SINK pad 就必须配成相同格式。

## 3. 查看拓扑：`media-ctl -p`

### 找到目标 media device

```bash
# 列出所有 media 设备
ls /dev/media*

# 快速识别每个 media device
for m in /dev/media*; do
    echo "$m:"
    media-ctl -d $m -p | grep -E "driver|model"
    echo
done
```

### 打印完整拓扑

```bash
media-ctl -d /dev/media2 -p
```

### 怎么读输出

**头部信息** — 标识这个 media device 是什么：

```
Media device information
------------------------
driver          mxc-isi
model           FSL Capture Media Device
bus info        platform:32e00000.isi
```

**Entity 段** — 每个硬件模块的描述：

```
- entity 41: ov5640 1-003c (1 pad, 1 link, 0 routes)
             type V4L2 subdev subtype Sensor flags 0
             device node name /dev/v4l-subdev4
```

- `ov5640 1-003c`：entity 名字，`1-003c` = I2C bus 1, 地址 0x3c
- `type V4L2 subdev subtype Sensor`：这是一个 sensor 子设备
- `/dev/v4l-subdev4`：可通过此节点单独配置

**Pad 段** — 端口及其格式和连接：

```
pad0: SOURCE
    [stream:0 fmt:UYVY8_1X16/640x480@1/30 field:none colorspace:srgb]
    -> "csis-32e40000.csi":0 []
```

- `pad0: SOURCE`：第 0 个 pad，类型为输出
- `fmt:UYVY8_1X16/640x480@1/30`：当前配置的格式和帧率
- `-> "csis-32e40000.csi":0 []`：连接到 CSIS 的 pad0，**`[]` 表示 link 未启用**

### 串联完整数据通路

从 sensor 开始，沿 link 追踪到 capture 节点：

```
ov5640:pad0 ──[]──→ csis:pad0          ← 第1段，未启用！
                     csis:pad1 ──[E,I]──→ crossbar:pad0
                                           crossbar:pad3 ──[E,I]──→ isi.0:pad0
                                                                      isi.0:pad1 ──[E,I]──→ capture:pad0
                                                                                              = /dev/video2
```

一眼就能看出：第 1 段 link 是断的（`[]`），后面全是 `ENABLED,IMMUTABLE`。

## 4. 检查 link 是否正确配置

### 快速检查

```bash
# 过滤出未启用的 link
media-ctl -d /dev/media2 -p | grep "\->" | grep -v ENABLED
```

如果输出中有 `[]`（空 flags），说明该 link 未启用，数据无法流通。

### 判断标准

一条完整的数据通路上，**从 sensor 到 capture 节点的每一段 link 都必须是 ENABLED**：

```
-> "csis-32e40000.csi":0 [ENABLED]              ✅
-> "crossbar":0 [ENABLED,IMMUTABLE]             ✅
-> "mxc_isi.0":0 [ENABLED,IMMUTABLE]            ✅
-> "mxc_isi.0.capture":0 [ENABLED,IMMUTABLE]    ✅
```

异常状态：

```
-> "csis-32e40000.csi":0 []                     ❌ 未启用，数据断路
```

### 检查格式是否匹配

```bash
media-ctl -d /dev/media2 -p | grep "fmt:"
```

如果 sensor 输出 640x480，但 crossbar 上还是默认的 1920x1080，就会导致 buffer 分配异常。

## 5. 配置命令

### 启用/禁用 link（`-l`）

语法：`"<source_entity>":pad -> "<sink_entity>":pad [flags]`

```bash
# 启用 link（flags=1）
media-ctl -d /dev/media2 -l '"ov5640 1-003c":0 -> "csis-32e40000.csi":0 [1]'

# 禁用 link（flags=0）
media-ctl -d /dev/media2 -l '"ov5640 1-003c":0 -> "csis-32e40000.csi":0 [0]'
```

注意：`IMMUTABLE` 的 link 不能修改。

### 设置 pad 格式（`-V`）

语法：`"<entity>":pad [fmt:MBUS_CODE/WxH]`

**从 sensor 开始，沿数据流方向逐级配置：**

```bash
# Step 1: sensor 输出
media-ctl -d /dev/media2 -V '"ov5640 1-003c":0 [fmt:UYVY8_1X16/640x480]'

# Step 2: CSIS 输入和输出
media-ctl -d /dev/media2 -V '"csis-32e40000.csi":0 [fmt:UYVY8_1X16/640x480]'
media-ctl -d /dev/media2 -V '"csis-32e40000.csi":1 [fmt:UYVY8_1X16/640x480]'

# Step 3: crossbar 输入和输出
media-ctl -d /dev/media2 -V '"crossbar":0 [fmt:UYVY8_1X16/640x480]'
media-ctl -d /dev/media2 -V '"crossbar":3 [fmt:UYVY8_1X16/640x480]'

# Step 4: ISI（输出格式可能不同，因为 ISI 做了颜色转换）
media-ctl -d /dev/media2 -V '"mxc_isi.0":0 [fmt:UYVY8_1X16/640x480]'
media-ctl -d /dev/media2 -V '"mxc_isi.0":1 [fmt:YUV8_1X24/640x480]'
```

### 查看支持的格式

```bash
# 查看某个 subdev 支持的 media bus format
v4l2-ctl -d /dev/v4l-subdev4 --list-subdev-mbus-codes

# 查看所有已知的 media bus format
media-ctl -d /dev/media2 --known-mbus-fmts
```

### 重置所有 link

```bash
media-ctl -d /dev/media2 -r
```

## 6. 实战案例：i.MX8MP + OV5640 抓图

### 问题现象

```
mxc-isi 32e00000.isi: dma alloc of size 16588800 failed
ERROR: Failed to allocate required memory.
streaming stopped, reason not-negotiated (-4)
```

### 根因分析

1. `ov5640 → csis` 的 link 未启用（`[]`）
2. pipeline 断开，ISI 无法获取 sensor 实际能力
3. crossbar/ISI 残留默认格式 1920x1080
4. gstreamer 按 1920x1080 协商，buffer 过大（~16MB），分配失败
5. 即使内存充足，pipeline 不通也会报 `not-negotiated`

### 修复步骤

```bash
# 1. 查看拓扑，定位问题
media-ctl -d /dev/media2 -p
media-ctl -d /dev/media2 -p | grep "\->" | grep -v ENABLED

# 2. 启用 sensor → CSIS 的 link
media-ctl -d /dev/media2 -l '"ov5640 1-003c":0 -> "csis-32e40000.csi":0 [1]'

# 3. 逐级配置格式（640x480，匹配 sensor 默认输出）
media-ctl -d /dev/media2 -V '"ov5640 1-003c":0 [fmt:UYVY8_1X16/640x480]'
media-ctl -d /dev/media2 -V '"csis-32e40000.csi":1 [fmt:UYVY8_1X16/640x480]'
media-ctl -d /dev/media2 -V '"crossbar":3 [fmt:UYVY8_1X16/640x480]'
media-ctl -d /dev/media2 -V '"mxc_isi.0":1 [fmt:YUV8_1X24/640x480]'

# 4. 验证配置
media-ctl -d /dev/media2 -p

# 5. 抓图
gst-launch-1.0 v4l2src device=/dev/video2 num-buffers=1 \
    ! "video/x-raw,width=640,height=480" \
    ! jpegenc ! filesink location=/tmp/capture.jpg
```

## 7. 常见问题排查

| 现象 | 可能原因 | 排查方法 |
|------|---------|---------|
| `Failed to allocate required memory` | 格式不匹配导致 buffer 过大，或 CMA 不足 | 检查各级 pad 格式是否一致；`cat /proc/meminfo \| grep Cma` |
| `not-negotiated` | pipeline 链路未连通 | `media-ctl -p` 检查 link 是否全部 ENABLED |
| `VIDIOC_STREAMON failed` | 格式配置错误 | 检查相邻 pad 格式是否匹配 |
| link 设置报错 `EBUSY` | 有程序正在使用该设备 | 停止所有使用该设备的程序后重试 |
| link 设置报错 `EINVAL` | 尝试修改 IMMUTABLE link | 该 link 是硬件固定的，无法修改 |

## 8. 命令速查表

| 操作 | 命令 |
|------|------|
| 查看拓扑 | `media-ctl -d /dev/mediaX -p` |
| 启用 link | `media-ctl -d /dev/mediaX -l '"A":0 -> "B":0 [1]'` |
| 禁用 link | `media-ctl -d /dev/mediaX -l '"A":0 -> "B":0 [0]'` |
| 设置格式 | `media-ctl -d /dev/mediaX -V '"A":0 [fmt:UYVY8_1X16/640x480]'` |
| 查看支持的格式 | `v4l2-ctl -d /dev/v4l-subdevX --list-subdev-mbus-codes` |
| 重置所有 link | `media-ctl -d /dev/mediaX -r` |
| 检查未启用的 link | `media-ctl -d /dev/mediaX -p \| grep "\->" \| grep -v ENABLED` |
