---
layout: post
title: "VPU Usage on the Mainline"
date: 2026-01-07 13:35:00 +0800
excerpt: "Hardware video acceleration with Hantro and Amphion VPUs on mainline Linux kernel."
---

# VPU Usage on the Mainline

Video Processing Units (VPU) have become essential for hardware-accelerated video encoding and decoding in embedded systems. The mainline Linux kernel now provides robust support for VPU implementations, particularly Hantro and Amphion VPUs found in modern SoCs.

## Hantro VPU Integration

The Hantro VPU requires GStreamer's v4l2codecs plugin for optimal performance. Enable it in your Yocto build:

```diff
# meta/recipes-multimedia/gstreamer/gstreamer1.0-plugins-bad_1.22.12.bb
@@ -27,7 +27,7 @@ PACKAGECONFIG ??= " 
${@bb.utils.filter('DISTRO_FEATURES', 'directfb vulkan x11', d)} 
${@bb.utils.contains('DISTRO_FEATURES', 'wayland', 'wayland', '', d)} 
${@bb.utils.contains('DISTRO_FEATURES', 'opengl', 'gl', '', d)} \
-bz2 closedcaption curl dash dtls hls openssl sbc smoothstreaming \
+bz2 closedcaption curl dash dtls hls openssl sbc smoothstreaming v4l2codecs \
sndfile ttml uvch264 webp 
${@bb.utils.contains('TUNE_FEATURES', 'mx32', '', 'rsvg', d)} 
"
```

This enables hardware-accelerated H.264/H.265 decoding, VP8/VP9 codec support, and efficient memory management through DMA-BUF.

## Amphion VPU Configuration

The Amphion VPU has excellent mainline support and integrates with GStreamer's good plugins without additional configuration.

For optimal performance on NXP i.MX8 platforms:

```bash
# Essential build configuration
BB_NO_NETWORK = '0'
ACCEPT_FSL_EULA = "1"
LICENSE_FLAGS_ACCEPTED:append = " commercial"

# NXP-specific BSP configuration
BSP_NXP_DERIVED:append:nxp-imx8 = " nxp-imx8"
DISTROOVERRIDES:nxp-imx8 = "fsl fslc"
CUSTOMER_RECIPES:fsl-bsp-release += 'imx-m7-demos'
CUSTOMER_RECIPES:freescale-layer += 'mesa'
CUSTOMER_RECIPES:freescale-layer += 'wayland'
CUSTOMER_RECIPES:freescale-layer += 'mesa-etnaviv-env'

# Enable mainline BSP usage
MACHINEOVERRIDES:prepend:nxp-imx8 = "use-mainline-bsp:"
```

Install the complete multimedia stack:

```bash
IMAGE_INSTALL:append = " \
    mesa-demos \
    xserver-xorg \
    gstreamer1.0 \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-base \
    gstreamer1.0-rtsp-server \
    gstreamer1.0-plugins-ugly \
    ffmpeg \
"
```

## Usage Examples

Hardware-accelerated H.264 decoding:

```bash
gst-launch-1.0 filesrc location=video.mp4 ! \
    qtdemux ! h264parse ! \
    v4l2h264dec ! videoconvert ! \
    waylandsink
```

Camera capture with hardware encoding:

```bash
gst-launch-1.0 v4l2src device=/dev/video0 ! \
    video/x-raw,width=1920,height=1080 ! \
    v4l2h264enc ! h264parse ! \
    mp4mux ! filesink location=output.mp4
```

RTSP streaming:

```bash
gst-launch-1.0 v4l2src ! \
    video/x-raw,width=1280,height=720,framerate=30/1 ! \
    v4l2h264enc extra-controls="controls,video_bitrate=2000000" ! \
    h264parse config-interval=1 ! \
    rtspclientsink location=rtsp://server:8554/stream
```

## Debugging

Check VPU device availability:

```bash
ls -la /dev/video*
```

Monitor VPU usage:

```bash
cat /sys/kernel/debug/vpu/status
```

GStreamer debug for VPU issues:

```bash
GST_DEBUG=v4l2*:5 gst-launch-1.0 [pipeline]
```

## Conclusion

VPU support on mainline Linux provides standardized APIs for hardware video acceleration. The combination of V4L2 framework and GStreamer integration offers a solid foundation for multimedia applications with long-term support and community maintenance.

---

*Date: <time datetime="2026-01-07T13:35:00+08:00">7th January 2026</time>*
