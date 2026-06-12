---
layout: post
title: "Linux DRM 子系统全景：从 CRTC 到 GPU 调度，以 NXP i.MX8 为例"
date: 2026-06-12 12:20:00 +0800
excerpt: "完整分析 Linux DRM/KMS 框架：CRTC、Plane、Encoder、Connector、Bridge 的流水线模型，GEM 内存管理与 dumb buffer，DMA-fence 同步机制，GPU Scheduler 渲染调度。以 NXP i.MX8MQ DCSS 驱动为实例。"
---

# Linux DRM 子系统全景：从 CRTC 到 GPU 调度

---

## 一、DRM 整体架构 — GPU 与 Display 的关系

DRM 子系统管理两类**独立的硬件**：

- **Display Controller**（显示控制器）：从内存读取像素，按时序扫描输出到屏幕
- **GPU**（渲染引擎）：执行 3D/2D 渲染命令，将结果写入内存

它们通过**共享的 buffer（GEM 对象）**和**同步原语（dma_fence）**协作：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户空间                                         │
│                                                                             │
│   Wayland/Weston    Xorg/modesetting    libdrm    Mesa (OpenGL/Vulkan)     │
│        │                  │                │              │                 │
│        │ 显示（KMS ioctl）│                │              │ 渲染 (GPU ioctl)│
│        └──────────────────┴───────┬────────┴──────────────┘                 │
│                                   │                                         │
├───────────────────────────────────┼─────────────────────────────────────────┤
│                              内核空间                                         │
│                                   │                                         │
│  ┌────────────────────────────────┼───────────────────────────────────┐     │
│  │                     DRM Core (/dev/dri/card0)                      │     │
│  │                                                                    │     │
│  │  ┌─────────────────────────────┐  ┌────────────────────────────┐  │     │
│  │  │    KMS (显示)               │  │   Render (渲染)             │  │     │
│  │  │                             │  │                            │  │     │
│  │  │  Plane → CRTC → Encoder    │  │  GPU Scheduler             │  │     │
│  │  │       → Bridge → Connector │  │  drm_sched_job             │  │     │
│  │  │                             │  │  run_job → dma_fence       │  │     │
│  │  │  从 buffer 读取 → 扫描输出  │  │  执行命令 → 写入 buffer     │  │     │
│  │  └──────────────┬──────────────┘  └─────────────┬──────────────┘  │     │
│  │                 │                               │                 │     │
│  │                 └────────── GEM Buffer ──────────┘                 │     │
│  │                         (同一块物理内存)                            │     │
│  │                                                                    │     │
│  │                      dma_fence (同步)                              │     │
│  │                  GPU signal → Display 才翻页                       │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  ┌──────────────────────────┐  ┌──────────────────────────────────────┐    │
│  │  Display 驱动 (imx-dcss) │  │  GPU 驱动 (etnaviv/amdgpu/i915)     │    │
│  │  读 buffer → 扫描到屏幕  │  │  收命令 → GPU执行 → 写 buffer        │    │
│  └──────────────────────────┘  └──────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

**一帧的完整流程：先渲染，后显示**

```
① App 通过 Mesa 提交 GPU 渲染命令 → GPU 把像素写入 buffer
② GPU 完成 → dma_fence signal
③ Compositor 发起 atomic commit → Display 等 fence → 确认 GPU 画完
④ VSync 到来 → Display 硬件从 buffer 读像素 → 扫描输出到屏幕
⑤ VBlank IRQ → 通知用户空间翻页完成 → 释放旧 buffer → 循环
```

---

## 二、KMS 显示流水线 — Probe 只注册，Helper 才配硬件

### 核心对象

```
                   ┌─────────┐
                   │ Plane 0 │ (Primary - 主图层)
                   │ Plane 1 │ (Overlay - 叠加)
                   │ Plane 2 │ (Cursor)
                   └────┬────┘
                        │ framebuffer 中的像素 → 混合
                        ▼
                   ┌─────────┐
                   │  CRTC   │  扫描控制器：生成时序，驱动像素流
                   └────┬────┘
                        │
                        ▼
                   ┌─────────┐
                   │ Encoder │  将像素编码为接口信号 (RGB→HDMI/DSI/LVDS)
                   └────┬────┘
                        │
                        ▼
                   ┌─────────┐
                   │ Bridge  │  外部转换芯片 (DSI-to-HDMI, DP PHY)
                   └────┬────┘
                        │
                        ▼
                   ┌──────────┐
                   │Connector │  物理端口 (HDMI口, DP口)，检测热插拔/读EDID
                   └──────────┘
```

### Probe 时 — 只注册，不操作硬件

驱动 probe 时**只向 DRM 核心注册对象**，硬件保持关闭状态：

```c
// probe → 只填结构体，不碰硬件寄存器
my_drm_probe() {
    devm_drm_dev_alloc();                // 分配 drm_device
    drm_mode_config_init();              // 初始化配置框架

    drm_universal_plane_init(plane, &my_plane_funcs, formats, ...);
    //   ↑ 只是告诉 DRM "我有一个 plane，支持这些格式"

    drm_crtc_init_with_planes(crtc, primary, cursor, &my_crtc_funcs);
    //   ↑ 只是告诉 DRM "我有一个 CRTC，关联这些 plane"

    drm_encoder_init(encoder, &my_encoder_funcs, type);
    drm_bridge_attach(encoder, bridge, NULL);
    drm_bridge_connector_init(ddev, encoder);

    drm_dev_register();                  // 创建 /dev/dri/card0
    // ← 到此为止，屏幕是黑的，硬件没有任何配置
}
```

### 第一次 Atomic Commit 时 — Helper 回调配置硬件

用户空间第一次设置模式时，DRM 核心按顺序调用驱动的 **helper 函数**，这才是**真正写寄存器的地方**：

```c
// ★ 这些才是干活的：
static const struct drm_crtc_helper_funcs my_crtc_helpers = {
    .atomic_check   = my_crtc_check,    // 验证参数（不碰硬件）
    .atomic_enable  = my_crtc_enable,   // ★ 配置时序寄存器，使能时钟，开始扫描
    .atomic_disable = my_crtc_disable,  // ★ 停止扫描，关闭时钟
    .atomic_flush   = my_crtc_flush,    // ★ 触发 double-buffer 切换
};

static const struct drm_plane_helper_funcs my_plane_helpers = {
    .atomic_check   = my_plane_check,   // 验证格式/尺寸
    .atomic_update  = my_plane_update,  // ★ 写 DMA 地址、格式、pitch 到硬件
    .atomic_disable = my_plane_disable, // ★ 关闭图层
};
```

**调用顺序**（DRM core `drm_atomic_helper_commit_tail` 驱动）：

```
用户 atomic commit
    → drm_atomic_helper_commit_modeset_disables()
        → encoder.atomic_disable() → crtc.atomic_disable()
    → drm_atomic_helper_commit_planes()
        → plane.atomic_update()     // ★ 写 buffer 地址到硬件
    → drm_atomic_helper_commit_modeset_enables()
        → crtc.atomic_enable()      // ★ 配时序，开始扫描
        → encoder.atomic_enable()
    → crtc.atomic_flush()           // ★ 触发生效
```

### 各对象 funcs vs helper_funcs 区分

| | `drm_xxx_funcs` | `drm_xxx_helper_funcs` |
|---|---|---|
| 用途 | ioctl 入口、引用计数 | 真正的硬件操作 |
| 何时调用 | 用户空间直接 ioctl | atomic commit 流程中 |
| 典型实现 | 大多用 `drm_atomic_helper_xxx` | 驱动自己实现，写寄存器 |
| 举例 | `.page_flip = drm_atomic_helper_page_flip` | `.atomic_enable = dcss_crtc_enable` |

---

## 三、Atomic Modesetting — 原子提交

### 为什么要 Atomic？

旧 API 逐个设置 CRTC/Plane/Connector，中间状态可能导致闪烁。Atomic 将所有更改打包为**一次事务**，要么全部成功，要么回滚。

### 完整流程

```
用户空间:
  drmModeAtomicAddProperty(req, plane_id, "FB_ID", fb_id);
  drmModeAtomicAddProperty(req, crtc_id, "ACTIVE", 1);
  drmModeAtomicAddProperty(req, crtc_id, "MODE_ID", blob);
  drmModeAtomicCommit(fd, req, flags);
    │
    ▼ ioctl(DRM_IOCTL_MODE_ATOMIC)

内核:
drm_mode_atomic_ioctl()
    │
    ├── drm_atomic_state_alloc()           // 创建"proposed state"
    ├── 解析用户属性 → 填充 state
    │
    ├── drm_atomic_helper_check()          // 全面验证
    │       ├── check_modeset()            // CRTC/encoder 约束
    │       └── check_planes()             // 对每个 plane 调 .atomic_check()
    │                                      // (不碰硬件，纯逻辑验证)
    │
    ├── 如果是 TEST_ONLY → 返回成功/失败
    │
    └── drm_atomic_helper_commit()         // 真正提交
            │
            ├── prepare_planes()           // pin buffer, 确保 DMA 地址有效
            ├── swap_state()               // 新 state 变为 current
            │
            └── commit_tail() [可异步]
                    ├── wait_for_fences()   // ★ 等 GPU fence（确保渲染完）
                    ├── commit_modeset_disables()
                    ├── commit_planes()     // ★ helper: .atomic_update()
                    ├── commit_modeset_enables() // ★ helper: .atomic_enable()
                    └── commit_hw_done()    // signal completion
```

---

## 四、GEM 内存管理 — Buffer 如何分配

### GEM 的角色

GEM (Graphics Execution Manager) 管理**显存/系统内存中的 buffer**，是 GPU 和 Display 共享数据的基础：

```
用户空间:  "我要一块 1920×1080×4 的内存"
    │
    ▼ ioctl
GEM:  分配物理内存 → 返回 handle (用户空间标识)
    │
    ├── GPU 用 handle 提交渲染 → 写入像素
    └── Display 用 handle 创建 framebuffer → 读取显示
```

### 层次结构

```c
struct drm_gem_object {           // DRM 通用基类
    size_t size;
    struct drm_device *dev;
    const struct drm_gem_object_funcs *funcs;
};

struct drm_gem_dma_object {       // DMA/CMA helper (NXP 等嵌入式用)
    struct drm_gem_object base;
    dma_addr_t dma_addr;          // ★ 物理 DMA 地址，硬件直接用
    void *vaddr;                  // 内核虚拟地址
};

// 对比 TTM (amdgpu/nouveau 等独显)：支持 VRAM/GTT 迁移，更复杂
```

### Dumb Buffer — 最简单的分配方式

Dumb buffer 是给**纯 CPU 渲染**（如 Wayland 软件合成、fbcon）用的简单接口：

```c
// 用户空间:
struct drm_mode_create_dumb arg = { .width=1920, .height=1080, .bpp=32 };
ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &arg);
// → arg.handle, arg.pitch, arg.size

// 内核 (DRM_GEM_DMA_DRIVER_OPS 自动提供):
drm_gem_dma_dumb_create()
    → dma_alloc_attrs()      // 从 CMA 分配物理连续内存
    → 返回 dma_addr + vaddr

// 用户 mmap:
ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map);    // 获取 mmap offset
void *ptr = mmap(0, size, ..., fd, map.offset); // 直接 CPU 写像素
```

### drm_framebuffer — Buffer 的"视图"

**注意：这不是旧的 fbdev！** `drm_framebuffer` 是 DRM 自己的核心对象，描述如何解释一块 GEM 内存：

```c
struct drm_framebuffer {
    u32 width, height;
    u32 format;                    // DRM_FORMAT_ARGB8888, NV12...
    u32 pitches[4];                // 每个 color plane 的 stride
    u32 offsets[4];                // 每个 color plane 在 buffer 中的偏移
    u64 modifier;                  // tiling 布局 (linear, tiled, compressed)
    struct drm_gem_object *obj[4]; // 底层 GEM buffer
};
```

一个 GEM buffer 可以有多个 framebuffer "视图"：

```
GEM Object (8MB 物理内存)
    ├── fb_a: 解释为 1920×1080 ARGB8888 linear
    └── fb_b: 解释为 1920×1080 NV12 (Y + UV 两个 plane)
```

**创建 framebuffer：**
```c
// 用户空间：
drmModeAddFB2(fd, width, height, DRM_FORMAT_ARGB8888,
              handles, pitches, offsets, &fb_id, 0);

// 内核：
drm_mode_config_funcs.fb_create = drm_gem_fb_create;
// → 查找 GEM handle → 创建 drm_framebuffer → 关联 GEM obj
```

### fbdev 兼容 — 旧的 /dev/fb0 怎么办？

```
旧程序 → /dev/fb0 → fbdev 兼容层 → 底层实际走 DRM
                     (drm_fbdev_dma_setup)

// NXP DCSS 驱动中一行开启兼容：
static const struct drm_driver dcss_kms_driver = {
    DRM_FBDEV_DMA_DRIVER_OPS,    // 提供 /dev/fb0 兼容
};
```

| | 旧 fbdev | DRM framebuffer |
|---|---|---|
| 用户接口 | `/dev/fb0` | `/dev/dri/card0` ioctl |
| 状态 | 🔴 淘汰，不接受新驱动 | 🟢 活跃，现代标准 |
| 功能 | 单 buffer，无 atomic | 多 plane，atomic，fence |
| 新驱动怎么做 | 通过兼容层桥接 | 原生 DRM |

---

## 五、DMA-BUF / PRIME — 跨设备 Buffer 共享

GPU 渲染完的 buffer 要给 Display 用，或者跨进程共享：

```
进程 A (GPU 渲染):                      进程 B (Wayland compositor 显示):
  render to handle_a                    
  fd = drmPrimeHandleToFD(handle_a) ─────→ handle_b = drmPrimeFDToHandle(fd)
                                              drmModeAddFB2(handle_b, ...)
                                              atomic commit → 显示

内核内部:
  两个 handle 指向同一个 dma_buf → 同一块物理内存
  GPU 驱动 = exporter (get_sg_table)
  Display 驱动 = importer (map_attachment)
```

---

## 六、DMA-Fence — GPU 与 Display 的同步

fence 解决一个核心问题：**Display 怎么知道 GPU 画完了？**

```c
struct dma_fence {
    u64 context, seqno;     // 唯一标识
    // signaled = 0: GPU 还在画
    // signaled = 1: GPU 画完了
};
```

### 工作流程

```
GPU 提交 job:
    ├── 创建 fence (unsignaled)
    ├── 将 fence 附加到 buffer
    ├── GPU 硬件开始渲染
    │
    ├── ... GPU 执行中 ...
    │
    └── GPU 完成 → IRQ → dma_fence_signal()

Display atomic commit:
    ├── drm_atomic_helper_wait_for_fences()
    │       └── dma_fence_wait()  等 GPU fence signal
    │           (如果 GPU 还没画完，阻塞等待)
    │
    └── fence signaled → plane.atomic_update() → 翻页显示
```

### 用户空间 explicit fence (Vulkan/Android):

```c
// GPU 渲染完返回 fence fd:
submit.out_fence_fd = &gpu_fence_fd;
ioctl(gpu_fd, DRM_IOCTL_SUBMIT, &submit);

// 把 fence 交给 Display:
drmModeAtomicAddProperty(req, plane, "IN_FENCE_FD", gpu_fence_fd);
drmModeAtomicCommit(fd, req, ...);
// → 内核自动等 fence signal 后才执行翻页
```

---

## 七、GPU Scheduler — 渲染任务调度

GPU Scheduler 是 DRM 提供的通用框架，管理多个应用的渲染请求排队和依赖：

```
┌─────────────────────────────────────────────────────────────────────┐
│                      DRM GPU Scheduler                               │
│                                                                     │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐                        │
│  │ Entity 0 │   │ Entity 1 │   │ Entity 2 │  (每个 GPU 上下文)     │
│  │ (App A)  │   │ (App B)  │   │ (App C)  │                        │
│  └─────┬────┘   └─────┬────┘   └─────┬────┘                        │
│        │               │               │                            │
│        └───────────────┼───────────────┘                            │
│                        ▼                                            │
│              ┌──────────────────┐                                   │
│              │ Scheduler Thread │ (kthread)                         │
│              │ drm_sched_main() │                                   │
│              └────────┬─────────┘                                   │
│                       │ 取出 job，检查依赖 fence                     │
│                       ▼                                             │
│              .run_job(sched_job)     ← 驱动实现，提交到 GPU 硬件     │
│                       │                                             │
│                       ▼                                             │
│              返回 hw_fence → scheduler 等待 signal                  │
│              signal 后 → .free_job() 释放资源                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 驱动实现的 backend ops

```c
struct drm_sched_backend_ops {
    // 检查 job 的依赖 fence 是否满足
    struct dma_fence *(*dependency)(struct drm_sched_job *job);

    // ★ 提交到 GPU 硬件执行，返回 hw fence
    struct dma_fence *(*run_job)(struct drm_sched_job *sched_job);

    // GPU 超时未完成
    enum drm_gpu_sched_stat (*timedout_job)(struct drm_sched_job *sched_job);

    // job 完成后释放
    void (*free_job)(struct drm_sched_job *sched_job);
};
```

---

## 八、NXP i.MX8MQ DCSS 驱动实例

### 硬件结构

```
i.MX8MQ DCSS (Display Controller Subsystem):
                                                         
  Plane 0 → DPR (Prefetch) → Scaler ─┐                  
  Plane 1 → DPR (Prefetch) → Scaler ─┤→ DTG → SS → HDMI PHY → 屏幕
                                      │  (时序)  (子采样)
                                      │
                                   VBlank IRQ
```

### 驱动注册 (dcss-kms.c) — probe 阶段

```c
struct dcss_kms_dev *dcss_kms_attach(struct dcss_dev *dcss)
{
    // ① 分配 DRM device
    kms = devm_drm_dev_alloc(dev, &dcss_kms_driver, ...);
    // driver_features = DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC
    // DRM_GEM_DMA_DRIVER_OPS → 自动提供 dumb_create/prime/mmap

    // ② 初始化 mode config
    drm_mode_config_init(&kms->base);
    config->funcs = &dcss_drm_mode_config_funcs;  // fb_create, atomic_check/commit
    config->max_width = 4096;

    // ③ 初始化 VBlank
    drm_vblank_init(drm, 1);  // 1个CRTC

    // ④ 从 DT 找到 HDMI bridge，建立 pipeline
    drm_of_find_panel_or_bridge(dev->of_node, ...);
    drm_encoder_init(encoder, &simple_funcs, DRM_MODE_ENCODER_NONE);
    drm_bridge_attach(encoder, bridge, NULL, DRM_BRIDGE_ATTACH_NO_CONNECTOR);
    kms->connector = drm_bridge_connector_init(ddev, encoder);
    drm_connector_attach_encoder(connector, encoder);

    // ⑤ 创建 CRTC + Planes
    dcss_crtc_init(crtc, drm);
    //   → dcss_plane_init() × 2 (primary + overlay)
    //   → drm_crtc_init_with_planes()

    // ⑥ 注册
    drm_dev_register(drm, 0);  // /dev/dri/card0 可用
    // ← 到此屏幕是黑的，硬件未配置
}
```

### Plane 更新 — helper 里写硬件 (atomic_update)

当用户空间 atomic commit 时，DRM 核心调用此函数：

```c
static void dcss_plane_atomic_update(struct drm_plane *plane,
                                     struct drm_atomic_state *state)
{
    struct drm_framebuffer *fb = new_state->fb;
    struct drm_gem_dma_object *dma_obj = drm_fb_dma_get_gem_obj(fb, 0);

    // ★ 从 framebuffer 获取 DMA 物理地址
    dma_addr_t paddr = dma_obj->dma_addr + fb->offsets[0];

    // ★ 写硬件寄存器：配置 DPR (预取 DMA 引擎)
    dcss_dpr_addr_set(dcss->dpr, ch, paddr, fb->pitches[0]);
    dcss_dpr_format_set(dcss->dpr, ch, fb->format, fb->modifier);
    dcss_dpr_set_res(dcss->dpr, ch, src_w, src_h);

    // ★ 配置 Scaler
    dcss_scaler_setup(dcss->scaler, ch, ...);
}
```

### CRTC 使能 — helper 里配时序 (atomic_enable)

```c
static void dcss_crtc_atomic_enable(struct drm_crtc *crtc, ...)
{
    struct drm_display_mode *mode = &crtc->state->adjusted_mode;
    struct videomode vm;

    drm_display_mode_to_videomode(mode, &vm);

    // ★ 配置 DTG 时序寄存器（hsync, vsync, active, blanking）
    dcss_dtg_sync_set(dcss->dtg, &vm);
    dcss_ss_sync_set(dcss->ss, &vm, hsync_pol, vsync_pol);

    // ★ 使能硬件开始扫描
    dcss_enable_dtg_and_ss(dcss);
    dcss_ctxld_enable(dcss->ctxld);  // context load：配置在下一VSync生效
}
```

### CRTC Flush — 触发硬件翻页

```c
static void dcss_crtc_atomic_flush(struct drm_crtc *crtc, ...)
{
    // 注册 VBlank 事件（翻页完成后通知用户空间）
    if (crtc->state->event) {
        drm_crtc_vblank_get(crtc);
        drm_crtc_arm_vblank_event(crtc, crtc->state->event);
        crtc->state->event = NULL;
    }

    // ★ 触发 context load — 硬件在下一个 VSync 加载新寄存器值
    dcss_ctxld_enable(dcss->ctxld);
}
```

### VBlank 中断 — 完成通知

```c
static irqreturn_t dcss_crtc_irq_handler(int irq, void *dev_id)
{
    // 检查 context load 是否已刷新（新配置已生效）
    if (dcss_ctxld_is_flushed(dcss->ctxld))
        drm_crtc_handle_vblank(&dcss_crtc->base);
        // → 发送 page_flip_complete 事件给用户空间

    dcss_dtg_vblank_irq_clear(dcss->dtg);
}
```

---

## 九、Bridge 链式架构

Bridge 用于 SoC 外部的信号转换芯片（如 HDMI TX、DSI-to-HDMI）：

```
SoC 内部                    │  SoC 外部
                           │
┌────────┐  ┌──────────┐   │  ┌──────────────┐   ┌──────────┐
│ CRTC   │→│ Encoder  │→──┼→│ HDMI Bridge  │→ │ Connector│→ 屏幕
│ (DCSS) │  │ (dummy)  │   │  │ (Cadence TX) │   │ (auto)   │
└────────┘  └──────────┘   │  └──────────────┘   └──────────┘
```

现代做法：encoder 是空壳，实际工作由 bridge 的 helper 完成：

```c
static const struct drm_bridge_funcs my_bridge_funcs = {
    .attach       = ...,           // 连接到 pipeline
    .mode_valid   = ...,           // 验证分辨率
    .atomic_enable  = ...,         // ★ 使能 HDMI TX 芯片
    .atomic_disable = ...,         // ★ 关闭
    .detect       = ...,           // 热插拔检测
    .get_modes    = ...,           // 读 EDID
};

// bridge_connector 自动从 bridge chain 最末端创建 connector
// 驱动无需手写 connector，由 drm_bridge_connector_init() 生成
```

---

## 十、Etnaviv — NXP Vivante GPU 渲染

NXP i.MX 系列内置 Vivante GPU（GC7000/GC2000），上游驱动是 etnaviv：

```
drivers/gpu/drm/etnaviv/
    ├── etnaviv_drv.c          # DRM 注册
    ├── etnaviv_gpu.c          # GPU 核心，命令提交
    ├── etnaviv_gem.c          # GEM (支持 shmem + CMA)
    ├── etnaviv_sched.c        # GPU scheduler 后端
    └── etnaviv_buffer.c       # ring buffer 管理
```

### 完整渲染流程

```
Mesa (OpenGL ES) → libdrm_etnaviv
    │
    ▼
ioctl(DRM_IOCTL_ETNAVIV_GEM_SUBMIT)      // 提交命令 buffer
    │
    ▼
etnaviv_ioctl_gem_submit()
    ├── 解析 bo list, relocs
    ├── drm_sched_job_init(&job)
    ├── drm_sched_job_arm(&job)            // 创建 scheduled fence
    ├── drm_sched_entity_push_job(&job)    // 入队 scheduler
    └── 返回 out_fence_fd 给用户空间
        │
        ▼ (scheduler kthread)
drm_sched_main()
    → etnaviv_sched_run_job(job)
        ├── etnaviv_buffer_queue()          // 拼命令到 ring buffer
        ├── 写 GPU FE (Front End) 寄存器   // 启动 GPU DMA
        └── 返回 hw_fence
        │
        ▼ (GPU 执行完毕)
GPU IRQ → etnaviv_gpu_irq_handler()
    → dma_fence_signal(hw_fence)
        → drm_sched_job_done()
            → free_job()
```

---

## 十一、Page Flip 与 VSync — 完整时序

```
时间线:
────────────────────────────────────────────────────────────────▶

  GPU 渲染 buffer B        Display 扫描 buffer A       用户空间
  ─────────────────        ───────────────────        ─────────

  ┌──────────────┐
  │ GPU 渲染中...│
  │              │
  │ fence=unsig  │
  └──────┬───────┘
         │ dma_fence_signal()
         ▼
  atomic commit (fb=B)
         │
         ├── wait_for_fences() ← 已 signal，立即通过
         ├── plane.atomic_update() ← 写 buffer B 地址到寄存器
         ├── crtc.atomic_flush()  ← arm vblank event
         │
         │         ┌─── VSync ───┐
         │         │             │
         │         ▼             │
         │   Display 切换到 B    │
         │   开始扫描 buffer B   │
         │                       │
         │   VBlank IRQ ─────────┼─────→ drm_crtc_handle_vblank()
         │                       │              │
         │                       │              ▼
         │                       │       用户收到 FLIP_COMPLETE
         │                       │       → 可以复用 buffer A
         │                       │       → 开始渲染下一帧到 A
         └───────────────────────┘
```

---

## 十二、源文件索引

| 路径 | 内容 |
|------|------|
| `drivers/gpu/drm/drm_drv.c` | DRM 设备注册 |
| `drivers/gpu/drm/drm_crtc.c` | CRTC 核心 |
| `drivers/gpu/drm/drm_plane.c` | Plane 核心 |
| `drivers/gpu/drm/drm_connector.c` | Connector 核心 |
| `drivers/gpu/drm/drm_bridge.c` | Bridge 框架 |
| `drivers/gpu/drm/drm_atomic_helper.c` | Atomic commit 流程编排 |
| `drivers/gpu/drm/drm_gem_dma_helper.c` | GEM DMA/CMA (dumb buffer) |
| `drivers/gpu/drm/drm_dumb_buffers.c` | Dumb buffer ioctl |
| `drivers/gpu/drm/drm_prime.c` | DMA-BUF import/export |
| `drivers/gpu/drm/drm_vblank.c` | VBlank 事件管理 |
| `drivers/gpu/drm/drm_syncobj.c` | Sync object |
| `drivers/gpu/drm/scheduler/` | GPU scheduler 框架 |
| `drivers/gpu/drm/imx/dcss/` | NXP i.MX8MQ DCSS 显示 |
| `drivers/gpu/drm/etnaviv/` | NXP Vivante GPU 渲染 |
| `include/drm/drm_*.h` | DRM 头文件 |
| `include/linux/dma-fence.h` | DMA fence API |
