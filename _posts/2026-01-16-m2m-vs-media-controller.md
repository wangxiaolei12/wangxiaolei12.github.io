---
layout: post
title: "Linux M2M vs Media Controller 架构对比"
date: 2026-01-16
categories: [Linux, V4L2, Media]
tags: [M2M, Media-Controller, V4L2, ISP]
---

## M2M vs Media Controller 核心区别

### 架构对比

**M2M (Memory-to-Memory):**
```
┌─────────┐      ┌─────────┐      ┌─────────┐
│ Input   │─────>│  Device │─────>│ Output  │
│ Buffer  │      │ (单功能) │      │ Buffer  │
└─────────┘      └─────────┘      └─────────┘
   1个输入          1个处理          1个输出
```

**Media Controller:**
```
                  ┌──────────┐
         ┌───────>│ Output 0 │
         │        └──────────┘
┌──────┐ │        ┌──────────┐
│Input │─┼───────>│ Output 1 │
└──────┘ │        └──────────┘
         │        ┌──────────┐
         └───────>│ Output 2 │
                  └──────────┘
  1个输入    灵活路由    多个输出
```

### 关键区别

| 特性 | M2M | Media Controller |
|------|-----|------------------|
| **拓扑** | 固定 1:1 | 灵活 N:M |
| **设备节点** | 1个 /dev/videoX | 多个节点 + subdev |
| **用途** | 简单转换 | 复杂管道 |
| **配置** | 自动 | 需要用户配置 |
| **典型应用** | 编解码、缩放 | ISP、摄像头管道 |

---

## M2M (Memory-to-Memory)

### 特点
- **1个输入 → 1个输出**
- 单个 `/dev/videoX` 节点
- 自动配置，即插即用
- 适合简单的数据转换

### 典型应用
```c
// JPEG 编码器
Input: YUV buffer → M2M Device → Output: JPEG buffer

// 视频缩放器
Input: 1920x1080 → M2M Device → Output: 640x480

// H.264 编解码
Input: YUV → M2M Device → Output: H.264
```

### 使用示例
```bash
# 单个设备节点
/dev/video0  # M2M 设备

# V4L2 API 使用
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=YU12 \
  --set-fmt-video-out=width=640,height=480,pixelformat=YU12
```

### 代码结构
```c
static const struct v4l2_ioctl_ops m2m_ioctl_ops = {
    .vidioc_querycap      = m2m_querycap,
    .vidioc_enum_fmt_vid_cap = m2m_enum_fmt_cap,
    .vidioc_enum_fmt_vid_out = m2m_enum_fmt_out,
    .vidioc_s_fmt_vid_cap = m2m_s_fmt_cap,
    .vidioc_s_fmt_vid_out = m2m_s_fmt_out,
    .vidioc_streamon      = v4l2_m2m_ioctl_streamon,
    .vidioc_streamoff     = v4l2_m2m_ioctl_streamoff,
};
```

---

## Media Controller

### 特点
- **N个输入 → M个输出**
- 多个设备节点 + subdevice
- 需要手动配置管道
- 适合复杂的处理流程

### 典型应用
```c
// ISP 管道
Input (RAW) → ISP → Output 0 (YUV)
                 → Output 1 (缩略图)
                 → Stats (统计数据)

// 摄像头子系统
Sensor → CSI-2 → ISP → Scaler → Output
                    → Stats
```

### 设备拓扑
```bash
# 多个设备节点
/dev/video0   # Input
/dev/video1   # Output 0
/dev/video2   # Output 1
/dev/video3   # Stats
/dev/v4l-subdev0  # ISP subdevice

# Media device
/dev/media0
```

### 配置示例
```bash
# 1. 查看拓扑
media-ctl -d /dev/media0 -p

# 2. 配置链路
media-ctl -d /dev/media0 -l '"isp":1->"output0":0[1]'

# 3. 配置格式
media-ctl -d /dev/media0 --set-v4l2 '"isp":0[fmt:SRGGB10/3280x2464]'
media-ctl -d /dev/media0 --set-v4l2 '"isp":1[fmt:YUYV/1920x1080]'

# 4. 使用视频节点
v4l2-ctl -d /dev/video1 --stream-mmap
```

### 代码结构
```c
// Media device
static const struct media_device_ops media_ops = {
    .link_notify = isp_link_notify,
};

// Subdevice
static const struct v4l2_subdev_ops isp_subdev_ops = {
    .video = &isp_video_ops,
    .pad   = &isp_pad_ops,
};

// Video nodes
static const struct v4l2_ioctl_ops isp_video_ioctl_ops = {
    .vidioc_querycap = isp_querycap,
    // ...
};
```

---

## 实际例子对比

### M2M: JPEG 编码器
```
用户视角:
1. 打开 /dev/video0
2. 设置输入格式 (YUV)
3. 设置输出格式 (JPEG)
4. 送入 YUV buffer
5. 获取 JPEG buffer

简单直接！
```

### Media Controller: 树莓派 ISP
```
用户视角:
1. 配置 media graph (链路、格式)
2. 打开 /dev/video10 (input)
3. 打开 /dev/video11 (output0)
4. 打开 /dev/video12 (output1)
5. 送入 RAW buffer 到 video10
6. 从 video11 获取 YUV
7. 从 video12 获取缩略图

复杂但灵活！
```

---

## 何时使用哪个？

### 使用 M2M
- ✅ 简单的 1:1 转换
- ✅ 编解码器
- ✅ 格式转换
- ✅ 缩放/旋转
- ✅ 用户无需了解硬件细节

### 使用 Media Controller
- ✅ 多输入/多输出
- ✅ 复杂的处理管道
- ✅ ISP、摄像头子系统
- ✅ 需要精细控制每个环节
- ✅ 硬件拓扑需要暴露给用户

---

## 总结

| 方面 | M2M | Media Controller |
|------|-----|------------------|
| 复杂度 | 简单 | 复杂 |
| 灵活性 | 低 | 高 |
| 配置 | 自动 | 手动 |
| 适用场景 | 单功能转换 | 多功能管道 |
| 用户友好 | ✅ | ❌ |
| 功能强大 | ❌ | ✅ |

**简单记忆:**
- **M2M** = 单个黑盒子（输入→输出）
- **Media Controller** = 可见的管道系统（可配置路由）

---

## 参考资料
- [Linux Media Subsystem Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/index.html)
- [V4L2 M2M Framework](https://www.kernel.org/doc/html/latest/driver-api/media/v4l2-mem2mem.html)
- [Media Controller API](https://www.kernel.org/doc/html/latest/userspace-api/media/mediactl/media-controller.html)
