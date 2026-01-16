---
layout: post
title: "Linux M2M vs Media Controller 架构对比与驱动实现"
date: 2026-01-16
categories: [Linux, V4L2, Media]
tags: [M2M, Media-Controller, V4L2, ISP, Driver]
---

## 核心区别

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

---

## Linux 内核驱动实现

### M2M 驱动实现示例

```c
// m2m_driver.c - 图像缩放器驱动
#include <media/v4l2-mem2mem.h>
#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>

struct m2m_dev {
    struct v4l2_device v4l2_dev;
    struct video_device vfd;
    struct v4l2_m2m_dev *m2m_dev;
};

struct m2m_ctx {
    struct v4l2_fh fh;
    struct v4l2_m2m_ctx *m2m_ctx;
    struct v4l2_pix_format src_fmt;
    struct v4l2_pix_format dst_fmt;
};

// 硬件处理函数
static void device_run(void *priv)
{
    struct m2m_ctx *ctx = priv;
    struct vb2_v4l2_buffer *src = v4l2_m2m_next_src_buf(ctx->m2m_ctx);
    struct vb2_v4l2_buffer *dst = v4l2_m2m_next_dst_buf(ctx->m2m_ctx);
    
    // 触发硬件处理 src -> dst
    // hardware_process(src, dst);
    
    v4l2_m2m_buf_done(src, VB2_BUF_STATE_DONE);
    v4l2_m2m_buf_done(dst, VB2_BUF_STATE_DONE);
    v4l2_m2m_job_finish(ctx->m2m_ctx);
}

static struct v4l2_m2m_ops m2m_ops = {
    .device_run = device_run,
};

// 队列操作
static int queue_setup(struct vb2_queue *vq, unsigned int *nbuffers,
                       unsigned int *nplanes, unsigned int sizes[],
                       struct device *alloc_devs[])
{
    struct m2m_ctx *ctx = vb2_get_drv_priv(vq);
    struct v4l2_pix_format *fmt = V4L2_TYPE_IS_OUTPUT(vq->type) ?
                                   &ctx->src_fmt : &ctx->dst_fmt;
    *nplanes = 1;
    sizes[0] = fmt->sizeimage;
    return 0;
}

static struct vb2_ops m2m_qops = {
    .queue_setup = queue_setup,
    .buf_queue = v4l2_m2m_buf_queue,
    .start_streaming = vb2_m2m_start_streaming,
    .stop_streaming = vb2_m2m_stop_streaming,
};

// 文件操作
static int m2m_open(struct file *file)
{
    struct m2m_dev *dev = video_drvdata(file);
    struct m2m_ctx *ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
    
    v4l2_fh_init(&ctx->fh, video_devdata(file));
    file->private_data = &ctx->fh;
    
    ctx->m2m_ctx = v4l2_m2m_ctx_init(dev->m2m_dev, ctx, NULL);
    v4l2_fh_add(&ctx->fh);
    return 0;
}

static struct v4l2_file_operations m2m_fops = {
    .owner = THIS_MODULE,
    .open = m2m_open,
    .release = vb2_fop_release,
    .poll = v4l2_m2m_fop_poll,
    .unlocked_ioctl = video_ioctl2,
    .mmap = v4l2_m2m_fop_mmap,
};

// IOCTL 操作
static struct v4l2_ioctl_ops m2m_ioctl_ops = {
    .vidioc_querycap = vidioc_querycap,
    .vidioc_enum_fmt_vid_cap = vidioc_enum_fmt,
    .vidioc_g_fmt_vid_cap_mplane = vidioc_g_fmt,
    .vidioc_s_fmt_vid_cap_mplane = vidioc_s_fmt,
    .vidioc_reqbufs = v4l2_m2m_ioctl_reqbufs,
    .vidioc_qbuf = v4l2_m2m_ioctl_qbuf,
    .vidioc_dqbuf = v4l2_m2m_ioctl_dqbuf,
    .vidioc_streamon = v4l2_m2m_ioctl_streamon,
    .vidioc_streamoff = v4l2_m2m_ioctl_streamoff,
};

// 驱动初始化
static int m2m_probe(struct platform_device *pdev)
{
    struct m2m_dev *dev = devm_kzalloc(&pdev->dev, sizeof(*dev), GFP_KERNEL);
    
    v4l2_device_register(&pdev->dev, &dev->v4l2_dev);
    
    dev->m2m_dev = v4l2_m2m_init(&m2m_ops);
    
    dev->vfd = (struct video_device) {
        .fops = &m2m_fops,
        .ioctl_ops = &m2m_ioctl_ops,
        .vfl_dir = VFL_DIR_M2M,
        .v4l2_dev = &dev->v4l2_dev,
    };
    
    return video_register_device(&dev->vfd, VFL_TYPE_VIDEO, -1);
}
```

### Media Controller 驱动实现示例

```c
// mc_driver.c - ISP 管道驱动
#include <media/v4l2-device.h>
#include <media/v4l2-subdev.h>
#include <media/media-device.h>
#include <media/videobuf2-v4l2.h>

struct mc_dev {
    struct media_device mdev;
    struct v4l2_device v4l2_dev;
    struct v4l2_subdev sensor_sd;
    struct v4l2_subdev isp_sd;
    struct video_device vdev;
    struct media_pad sensor_pad;
    struct media_pad isp_pads[2];
    struct media_pad video_pad;
};

// Sensor 子设备操作
static int sensor_s_stream(struct v4l2_subdev *sd, int enable)
{
    // 启动/停止 sensor
    return 0;
}

static int sensor_set_fmt(struct v4l2_subdev *sd,
                          struct v4l2_subdev_state *state,
                          struct v4l2_subdev_format *fmt)
{
    if (fmt->pad != 0)
        return -EINVAL;
    
    // 验证并保存格式
    return 0;
}

static struct v4l2_subdev_video_ops sensor_video_ops = {
    .s_stream = sensor_s_stream,
};

static struct v4l2_subdev_pad_ops sensor_pad_ops = {
    .set_fmt = sensor_set_fmt,
    .get_fmt = sensor_get_fmt,
};

static struct v4l2_subdev_ops sensor_ops = {
    .video = &sensor_video_ops,
    .pad = &sensor_pad_ops,
};

// ISP 子设备操作
static int isp_s_stream(struct v4l2_subdev *sd, int enable)
{
    // 启动/停止 ISP 处理
    return 0;
}

static int isp_set_fmt(struct v4l2_subdev *sd,
                       struct v4l2_subdev_state *state,
                       struct v4l2_subdev_format *fmt)
{
    // pad 0: sink (输入), pad 1: source (输出)
    if (fmt->pad > 1)
        return -EINVAL;
    
    // 设置格式，可能需要格式转换
    return 0;
}

static struct v4l2_subdev_ops isp_ops = {
    .video = &(struct v4l2_subdev_video_ops){
        .s_stream = isp_s_stream,
    },
    .pad = &(struct v4l2_subdev_pad_ops){
        .set_fmt = isp_set_fmt,
        .get_fmt = isp_get_fmt,
    },
};

// Video 节点操作（capture）
static int video_querycap(struct file *file, void *fh,
                          struct v4l2_capability *cap)
{
    strscpy(cap->driver, "mc-isp", sizeof(cap->driver));
    cap->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
    cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
    return 0;
}

static struct v4l2_ioctl_ops video_ioctl_ops = {
    .vidioc_querycap = video_querycap,
    .vidioc_enum_fmt_vid_cap = vidioc_enum_fmt,
    .vidioc_g_fmt_vid_cap = vidioc_g_fmt,
    .vidioc_s_fmt_vid_cap = vidioc_s_fmt,
    .vidioc_reqbufs = vb2_ioctl_reqbufs,
    .vidioc_qbuf = vb2_ioctl_qbuf,
    .vidioc_dqbuf = vb2_ioctl_dqbuf,
    .vidioc_streamon = vb2_ioctl_streamon,
    .vidioc_streamoff = vb2_ioctl_streamoff,
};

static struct v4l2_file_operations video_fops = {
    .owner = THIS_MODULE,
    .open = v4l2_fh_open,
    .release = vb2_fop_release,
    .poll = vb2_fop_poll,
    .unlocked_ioctl = video_ioctl2,
    .mmap = vb2_fop_mmap,
};

// 驱动初始化
static int mc_probe(struct platform_device *pdev)
{
    struct mc_dev *dev = devm_kzalloc(&pdev->dev, sizeof(*dev), GFP_KERNEL);
    int ret;
    
    // 1. 注册 media device
    dev->mdev.dev = &pdev->dev;
    strscpy(dev->mdev.model, "ISP Pipeline", sizeof(dev->mdev.model));
    media_device_init(&dev->mdev);
    
    // 2. 注册 v4l2 device
    dev->v4l2_dev.mdev = &dev->mdev;
    ret = v4l2_device_register(&pdev->dev, &dev->v4l2_dev);
    
    // 3. 注册 sensor 子设备
    v4l2_subdev_init(&dev->sensor_sd, &sensor_ops);
    strscpy(dev->sensor_sd.name, "sensor", sizeof(dev->sensor_sd.name));
    dev->sensor_pad.flags = MEDIA_PAD_FL_SOURCE;
    media_entity_pads_init(&dev->sensor_sd.entity, 1, &dev->sensor_pad);
    v4l2_device_register_subdev(&dev->v4l2_dev, &dev->sensor_sd);
    
    // 4. 注册 ISP 子设备
    v4l2_subdev_init(&dev->isp_sd, &isp_ops);
    strscpy(dev->isp_sd.name, "isp", sizeof(dev->isp_sd.name));
    dev->isp_pads[0].flags = MEDIA_PAD_FL_SINK;
    dev->isp_pads[1].flags = MEDIA_PAD_FL_SOURCE;
    media_entity_pads_init(&dev->isp_sd.entity, 2, dev->isp_pads);
    v4l2_device_register_subdev(&dev->v4l2_dev, &dev->isp_sd);
    
    // 5. 注册 video 设备
    dev->vdev.fops = &video_fops;
    dev->vdev.ioctl_ops = &video_ioctl_ops;
    dev->vdev.v4l2_dev = &dev->v4l2_dev;
    dev->vdev.device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
    dev->video_pad.flags = MEDIA_PAD_FL_SINK;
    media_entity_pads_init(&dev->vdev.entity, 1, &dev->video_pad);
    video_register_device(&dev->vdev, VFL_TYPE_VIDEO, -1);
    
    // 6. 创建链接: sensor -> isp -> video
    media_create_pad_link(&dev->sensor_sd.entity, 0,
                          &dev->isp_sd.entity, 0,
                          MEDIA_LNK_FL_IMMUTABLE | MEDIA_LNK_FL_ENABLED);
    
    media_create_pad_link(&dev->isp_sd.entity, 1,
                          &dev->vdev.entity, 0,
                          MEDIA_LNK_FL_IMMUTABLE | MEDIA_LNK_FL_ENABLED);
    
    // 7. 注册 media device
    return media_device_register(&dev->mdev);
}
```

---

## 用户空间使用对比

### M2M 使用（单设备）

```c
// m2m_user.c
int fd = open("/dev/video0", O_RDWR);

// 直接设置输入输出格式
struct v4l2_format fmt_out = {
    .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
    .fmt.pix = {.pixelformat = V4L2_PIX_FMT_NV12, .width = 640, .height = 480}
};
ioctl(fd, VIDIOC_S_FMT, &fmt_out);

struct v4l2_format fmt_in = {
    .type = V4L2_BUF_TYPE_VIDEO_OUTPUT,
    .fmt.pix = {.pixelformat = V4L2_PIX_FMT_YUYV, .width = 1920, .height = 1080}
};
ioctl(fd, VIDIOC_S_FMT, &fmt_in);

// 分配缓冲区并处理
// REQBUFS, QBUF, STREAMON...
```

### Media Controller 使用（多设备）

```c
// mc_user.c
int media_fd = open("/dev/media0", O_RDWR);

// 1. 配置 sensor 格式
int sensor_fd = open("/dev/v4l-subdev0", O_RDWR);
struct v4l2_subdev_format sensor_fmt = {
    .which = V4L2_SUBDEV_FORMAT_ACTIVE,
    .pad = 0,
    .format = {.width = 1920, .height = 1080, .code = MEDIA_BUS_FMT_SBGGR10_1X10}
};
ioctl(sensor_fd, VIDIOC_SUBDEV_S_FMT, &sensor_fmt);

// 2. 配置 ISP 输入格式
int isp_fd = open("/dev/v4l-subdev1", O_RDWR);
struct v4l2_subdev_format isp_fmt = {
    .which = V4L2_SUBDEV_FORMAT_ACTIVE,
    .pad = 0,  // sink pad
    .format = {.width = 1920, .height = 1080, .code = MEDIA_BUS_FMT_SBGGR10_1X10}
};
ioctl(isp_fd, VIDIOC_SUBDEV_S_FMT, &isp_fmt);

// 3. 配置 ISP 输出格式
isp_fmt.pad = 1;  // source pad
isp_fmt.format.code = MEDIA_BUS_FMT_YUYV8_2X8;
ioctl(isp_fd, VIDIOC_SUBDEV_S_FMT, &isp_fmt);

// 4. 最后配置 video 节点
int video_fd = open("/dev/video0", O_RDWR);
struct v4l2_format fmt = {
    .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
    .fmt.pix = {.pixelformat = V4L2_PIX_FMT_YUYV, .width = 1920, .height = 1080}
};
ioctl(video_fd, VIDIOC_S_FMT, &fmt);
```

---

## 关键区别总结

| 特性 | M2M | Media Controller |
|------|-----|------------------|
| 设备节点 | 1 个 video 设备 | 多个 subdev + video 设备 |
| 拓扑配置 | 驱动内部固定 | 用户空间可配置 |
| 格式设置 | 单设备两个队列 | 每个 pad 独立设置 |
| 适用场景 | 编解码、缩放 | ISP、摄像头管道 |
| 复杂度 | 低 | 高 |
| 灵活性 | 低 | 高 |

**选择建议:**
- **M2M**: 功能单一的转换设备（编解码器、缩放器）
- **Media Controller**: 需要灵活配置的复杂管道（ISP、摄像头子系统）

---

## 参考资料
- [Linux Media Subsystem Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/index.html)
- [V4L2 M2M Framework](https://www.kernel.org/doc/html/latest/driver-api/media/v4l2-mem2mem.html)
- [Media Controller API](https://www.kernel.org/doc/html/latest/userspace-api/media/mediactl/media-controller.html)
