---
layout: post
title: "Linux DMA-BUF 框架：跨设备零拷贝缓冲区共享机制深度解析"
date: 2026-06-27 18:00:00 +0800
excerpt: "深入分析 Linux DMA-BUF 框架的设计理念、核心数据结构、导出者/导入者工作流程、同步机制，以及实际应用场景。基于 mainline 源码 drivers/dma-buf/ 和 Documentation/driver-api/dma-buf.rst。"
---

# Linux DMA-BUF 框架：跨设备零拷贝缓冲区共享机制深度解析

基于 mainline `drivers/dma-buf/dma-buf.c`、`include/linux/dma-buf.h` 及 `Documentation/driver-api/dma-buf.rst` 源码分析

---

## 一、为什么需要 DMA-BUF

在现代嵌入式系统和多媒体设备中，数据经常需要在多个硬件模块之间流转：

```
摄像头 → ISP → 编码器 → 网络
GPU → 显示控制器
CPU → 加速器 → 存储
```

传统方式下，每次数据传递都需要 CPU 参与拷贝，带来：

1. **性能损失** — CPU 拷贝消耗大量计算资源
2. **内存浪费** — 多份数据副本占用内存
3. **延迟增加** — 数据拷贝增加处理延迟
4. **缓存失效** — 频繁拷贝导致 cache bouncing

**DMA-BUF 的核心目标：实现跨设备的零拷贝缓冲区共享**。

---

## 二、核心设计理念

### 2.1 三个基本原语

DMA-BUF 框架提供三个核心原语：

1. **dma-buf** — 共享缓冲区的抽象表示
   - 封装一块 DMA 可访问的内存
   - 通过文件描述符传递，支持跨进程共享
   
2. **dma-fence** — 异步操作的同步机制
   - 表示硬件操作完成的信号
   - 用于协调不同设备对缓冲区的访问
   
3. **dma-resv** — 保留对象（Reservation Object）
   - 管理缓冲区相关的 fence 集合
   - 维护隐式同步语义

### 2.2 导出者-导入者模型

DMA-BUF 采用导出者（Exporter）和导入者（Importer）的分工模型：

```
┌─────────────────────────────────────────────────────────┐
│                   DMA-BUF 框架                          │
│                                                         │
│  ┌──────────────┐              ┌──────────────┐       │
│  │   Exporter   │              │   Importer   │       │
│  │  (提供者)     │              │  (使用者)     │       │
│  └──────────────┘              └──────────────┘       │
│        │                              │                │
│        │ 1. 分配内存                   │                │
│        │ 2. 实现 dma_buf_ops           │                │
│        │ 3. 导出 dma_buf               │                │
│        │                              │                │
│        └────────── fd 传递 ────────────┘                │
│                   │                                     │
│                   ▼                                     │
│        ┌──────────────────────┐                        │
│        │   struct dma_buf     │                        │
│        │  - size              │                        │
│        │  - file (fd)         │                        │
│        │  - ops               │                        │
│        │  - resv (同步)       │                        │
│        │  - attachments       │                        │
│        └──────────────────────┘                        │
└─────────────────────────────────────────────────────────┘
```

**导出者职责：**
- 分配和管理后端存储
- 实现 `dma_buf_ops` 操作函数集
- 决定内存位置和迁移策略
- 处理缓冲区的生命周期

**导入者职责：**
- 通过 fd 获取 dma_buf
- 将缓冲区附加到设备
- 映射并使用缓冲区
- 遵守同步约束

---

## 三、核心数据结构

### 3.1 struct dma_buf

```c
// include/linux/dma-buf.h
struct dma_buf {
    size_t size;                    // 缓冲区大小（不变）
    struct file *file;              // 关联的文件对象（用于 fd 和引用计数）
    struct list_head attachments;   // 所有附加设备的链表（受 resv 锁保护）
    const struct dma_buf_ops *ops;  // 操作函数集
    struct dma_resv *resv;          // 保留对象（用于同步）
    void *priv;                     // 导出者私有数据
    
    // CPU 访问支持
    unsigned vmapping_counter;      // vmap 引用计数
    struct iosys_map vmap_ptr;      // 当前 vmap 指针
    
    // 元数据
    const char *exp_name;           // 导出者名称（调试用）
    const char *name;               // 用户空间设置的名称
    struct module *owner;           // 导出者模块
};
```

### 3.2 struct dma_buf_ops

```c
struct dma_buf_ops {
    // 设备附加/分离
    int (*attach)(struct dma_buf *, struct dma_buf_attachment *);
    void (*detach)(struct dma_buf *, struct dma_buf_attachment *);
    
    // Pin/Unpin（动态导出者）
    int (*pin)(struct dma_buf_attachment *);
    void (*unpin)(struct dma_buf_attachment *);
    
    // DMA 映射/解除映射（必须实现）
    struct sg_table *(*map_dma_buf)(struct dma_buf_attachment *,
                                    enum dma_data_direction);
    void (*unmap_dma_buf)(struct dma_buf_attachment *,
                         struct sg_table *,
                         enum dma_data_direction);
    
    // 释放缓冲区（必须实现）
    void (*release)(struct dma_buf *);
    
    // CPU 访问
    int (*begin_cpu_access)(struct dma_buf *, enum dma_data_direction);
    int (*end_cpu_access)(struct dma_buf *, enum dma_data_direction);
    
    // 内存映射
    int (*mmap)(struct dma_buf *, struct vm_area_struct *);
    int (*vmap)(struct dma_buf *dmabuf, struct iosys_map *map);
    void (*vunmap)(struct dma_buf *dmabuf, struct iosys_map *map);
};
```

### 3.3 struct dma_buf_attachment

```c
struct dma_buf_attachment {
    struct dma_buf *dmabuf;             // 关联的 dma_buf
    struct device *dev;                 // 附加的设备
    struct list_head node;              // 链表节点
    void *priv;                         // 导出者私有数据
    const struct dma_buf_attach_ops *importer_ops;  // 导入者操作
};
```

### 3.4 struct dma_buf_export_info

```c
struct dma_buf_export_info {
    const char *exp_name;       // 导出者名称
    const struct dma_buf_ops *ops;  // 操作函数集
    size_t size;                // 缓冲区大小
    int flags;                  // 文件标志
    struct dma_resv *resv;      // 外部提供的 resv（可选）
    void *priv;                 // 导出者私有数据
    struct module *owner;       // 导出者模块
};

// 便捷宏
#define DEFINE_DMA_BUF_EXPORT_INFO(name) \
    struct dma_buf_export_info name = { .exp_name = KBUILD_MODNAME, \
                                        .owner = THIS_MODULE }
```

---

## 四、导出者实现示例

### 4.1 System Heap 实现

系统堆是内核提供的通用 DMA-BUF 导出者，使用普通系统内存：

```c
// drivers/dma-buf/heaps/system_heap.c

static const struct dma_buf_ops system_heap_buf_ops = {
    .attach = system_heap_attach,
    .detach = system_heap_detach,
    .map_dma_buf = system_heap_map_dma_buf,
    .unmap_dma_buf = system_heap_unmap_dma_buf,
    .begin_cpu_access = system_heap_dma_buf_begin_cpu_access,
    .end_cpu_access = system_heap_dma_buf_end_cpu_access,
    .mmap = system_heap_mmap,
    .vmap = system_heap_vmap,
    .vunmap = system_heap_vunmap,
    .release = system_heap_dma_buf_release,
};

static struct dma_buf *system_heap_allocate(struct dma_heap *heap,
                                            unsigned long len,
                                            u32 fd_flags,
                                            u64 heap_flags)
{
    struct system_heap_buffer *buffer;
    DEFINE_DMA_BUF_EXPORT_INFO(exp_info);
    struct dma_buf *dmabuf;
    struct sg_table *table;
    
    // 1. 分配缓冲区结构
    buffer = kzalloc(sizeof(*buffer), GFP_KERNEL);
    INIT_LIST_HEAD(&buffer->attachments);
    mutex_init(&buffer->lock);
    buffer->len = len;
    
    // 2. 分配物理页面并构建 sg_table
    table = &buffer->sg_table;
    // ... 使用 alloc_pages() 分配页面
    // ... 构建 scatterlist
    
    // 3. 导出为 dma_buf
    exp_info.exp_name = dma_heap_get_name(heap);
    exp_info.ops = &system_heap_buf_ops;
    exp_info.size = buffer->len;
    exp_info.flags = fd_flags;
    exp_info.priv = buffer;
    
    dmabuf = dma_buf_export(&exp_info);
    if (IS_ERR(dmabuf)) {
        // 清理并返回错误
    }
    
    return dmabuf;
}
```

### 4.2 map_dma_buf 实现

```c
static struct sg_table *system_heap_map_dma_buf(
    struct dma_buf_attachment *attachment,
    enum dma_data_direction direction)
{
    struct system_heap_buffer *buffer = attachment->dmabuf->priv;
    struct sg_table *table = &buffer->sg_table;
    struct scatterlist *sg;
    int i;
    
    // 将每个 scatterlist 条目映射到设备地址空间
    for_each_sgtable_sg(table, sg, i) {
        sg_dma_address(sg) = dma_map_page(attachment->dev,
                                          sg_page(sg),
                                          0,
                                          sg->length,
                                          direction);
    }
    
    // 返回 sg_table（DMA 地址已填充）
    return table;
}
```

---

## 五、导入者使用示例

### 5.1 DRM 驱动导入 DMA-BUF

```c
// drivers/gpu/drm/drm_prime.c

struct drm_gem_object *drm_gem_prime_import(struct drm_device *dev,
                                            struct dma_buf *dma_buf)
{
    struct dma_buf_attachment *attach;
    struct sg_table *sgt;
    struct drm_gem_object *obj;
    int ret;
    
    // 1. 将 dma_buf 附加到设备
    attach = dma_buf_attach(dma_buf, dev->dev);
    if (IS_ERR(attach))
        return ERR_CAST(attach);
    
    // 2. 映射到设备地址空间
    sgt = dma_buf_map_attachment(attach, DMA_BIDIRECTIONAL);
    if (IS_ERR(sgt)) {
        ret = PTR_ERR(sgt);
        goto fail_detach;
    }
    
    // 3. 创建 GEM 对象并保存映射信息
    obj = dev->driver->gem_prime_import_sg_table(dev, attach, sgt);
    if (IS_ERR(obj)) {
        ret = PTR_ERR(obj);
        goto fail_unmap;
    }
    
    obj->import_attach = attach;
    return obj;
    
fail_unmap:
    dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
fail_detach:
    dma_buf_detach(dma_buf, attach);
    return ERR_PTR(ret);
}
```

### 5.2 使用流程

```c
// 典型的 DMA-BUF 使用流程
void example_use_dmabuf(int fd, struct device *dev)
{
    struct dma_buf *dmabuf;
    struct dma_buf_attachment *attach;
    struct sg_table *sgt;
    struct scatterlist *sg;
    int i;
    
    // 1. 通过 fd 获取 dma_buf
    dmabuf = dma_buf_get(fd);
    if (IS_ERR(dmabuf))
        return PTR_ERR(dmabuf);
    
    // 2. 附加到设备
    attach = dma_buf_attach(dmabuf, dev);
    if (IS_ERR(attach))
        goto err_put;
    
    // 3. 映射获取 sg_table
    sgt = dma_buf_map_attachment(attach, DMA_BIDIRECTIONAL);
    if (IS_ERR(sgt))
        goto err_detach;
    
    // 4. 使用缓冲区
    for_each_sgtable_dma_sg(sgt, sg, i) {
        dma_addr_t dma_addr = sg_dma_address(sg);
        size_t len = sg_dma_len(sg);
        
        // 配置 DMA 引擎使用这些地址
        dev_info(dev, "DMA segment: addr=%pad, len=%zu\n",
                 &dma_addr, len);
    }
    
    // 5. 提交 DMA 操作（可能需要等待 fence）
    // ...
    
    // 6. 清理
    dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
err_detach:
    dma_buf_detach(dmabuf, attach);
err_put:
    dma_buf_put(dmabuf);
}
```

---

## 六、同步机制详解

### 6.1 dma_resv 和 dma_fence

```c
// include/linux/dma-resv.h
struct dma_resv {
    struct ww_mutex lock;           // 互斥锁
    struct dma_resv_list *fences;   // fence 列表
};

// include/linux/dma-fence.h
struct dma_fence {
    spinlock_t lock;                // 自旋锁
    volatile const struct dma_fence_ops *ops;
    struct list_head cb_list;       // 回调链表
    u64 context;                    // 执行上下文
    u64 seqno;                      // 序列号
    ktime_t timestamp;              // 完成时间戳
};
```

### 6.2 同步工作流程

```
时间线 →

Device A (GPU):          Device B (显示控制器):
    │                          │
    ├─ 获取 dma_buf            │
    ├─ map_dma_buf             │
    ├─ 提交渲染作业            │
    │  └─ 创建 fence_A         │
    │  └─ fence_A → resv       │
    │                          │
    │                          ├─ 获取 dma_buf (同 fd)
    │                          ├─ 附加到设备
    │                          ├─ 查询 resv
    │                          ├─ 发现 fence_A
    │                          ├─ 等待 fence_A 完成
    │                          │
    ├─ GPU 完成                │
    │  └─ signal fence_A       │
    │                          │
    │                          ├─ fence_A 触发回调
    │                          ├─ 开始显示
    │                          └─ 从缓冲区读取
```

### 6.3 隐式同步

DMA-BUF 通过 `dma_resv` 实现隐式同步：

```c
// 导出者在提交操作时
dma_resv_lock(dmabuf->resv, NULL);
dma_resv_add_fence(dmabuf->resv, fence, DMA_RESV_USAGE_WRITE);
dma_resv_unlock(dmabuf->resv);

// 导入者在访问前
dma_resv_lock(dmabuf->resv, NULL);
ret = dma_resv_wait_timeout(dmabuf->resv, DMA_RESV_USAGE_READ,
                             false, MAX_SCHEDULE_TIMEOUT);
dma_resv_unlock(dmabuf->resv);
```

---

## 七、用户空间接口

### 7.1 文件描述符传递

DMA-BUF 通过文件描述符在进程间传递：

```c
// 进程 A：创建并导出
int fd = dma_heap_alloc(heap, size, O_RDWR | O_CLOEXEC);

// 通过 socket 或其他 IPC 机制传递 fd 给进程 B
send_fd(socket, fd);

// 进程 B：接收并使用
int fd = recv_fd(socket);
```

### 7.2 mmap 支持

用户空间可以 mmap DMA-BUF：

```c
void *map = mmap(NULL, size, PROT_READ | PROT_WRITE,
                 MAP_SHARED, dmabuf_fd, 0);
```

这会调用导出者的 `mmap` 操作。

### 7.3 ioctl 接口

```c
// include/uapi/linux/dma-buf.h

#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#define DMA_BUF_SET_NAME _IOW(DMA_BUF_BASE, 1, const char *)
#define DMA_BUF_SET_NAME_A _IOW(DMA_BUF_BASE, 1, u32)
#define DMA_BUF_SET_NAME_B _IOW(DMA_BUF_BASE, 1, u64)

struct dma_buf_sync {
    __u64 flags;
};

// 同步 CPU 访问
struct dma_buf_sync sync = {
    .flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ
};
ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);

// 读取数据...
// ...

sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
```

### 7.4 poll 支持

DMA-BUF 支持 poll 操作，用于等待 fence 完成：

```c
struct pollfd pfd = {
    .fd = dmabuf_fd,
    .events = POLLIN,
};

int ret = poll(&pfd, 1, timeout);
if (ret > 0 && (pfd.revents & POLLIN)) {
    // fence 已完成，可以访问缓冲区
}
```

---

## 八、DMA-BUF Heap 系统

内核提供了 DMA-BUF Heap 框架，用于用户空间分配 DMA 缓冲区：

```c
// drivers/dma-buf/dma-heap.c

// 用户空间通过 /dev/dma_heap/<heap_name> 访问
// 例如：
// /dev/dma_heap/system      - 系统内存堆
// /dev/dma_heap/linux,cma   - CMA 堆
// /dev/dma_heap/linux,dsp   - DSP 专用堆

struct dma_heap_allocation_data {
    __u64 len;           // 分配大小
    __u32 fd;            // 返回的 fd
    __u32 fd_flags;      // fd 标志
    __u64 heap_flags;    // 堆特定标志
};

#define DMA_HEAP_IOCTL_ALLOC _IOWR(DMA_HEAP_BASE, 0, \
                                    struct dma_heap_allocation_data)

// 用户空间使用
int heap_fd = open("/dev/dma_heap/system", O_RDWR);
struct dma_heap_allocation_data data = {
    .len = size,
    .fd_flags = O_RDWR | O_CLOEXEC,
};
ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &data);
int dmabuf_fd = data.fd;
```

### 8.1 内置堆类型

1. **system_heap** — 使用 `alloc_pages()` 分配
2. **cma_heap** — 使用 CMA 分配器分配连续内存
3. **carveout_heap** — 使用预留内存区域
4. **自定义堆** — 厂商可添加专用堆

---

## 九、实际应用场景

### 9.1 GPU → 显示管线

```
┌─────────┐     ┌─────────┐     ┌─────────┐
│  GPU    │────▶│dma-buf  │────▶│ 显示器  │
│ (渲染)  │     │ (零拷贝)│     │ (显示)  │
└─────────┘     └─────────┘     └─────────┘
     │                               │
     └──── fence 同步 ───────────────┘
```

- GPU 渲染完成时创建 fence
- 显示控制器等待 fence 后才能读取
- 零拷贝，数据始终在 GPU 内存

### 9.2 视频编解码流水线

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ 摄像头  │────▶│  ISP    │────▶│ 编码器  │────▶│  网络   │
│ (采集)  │     │(处理)   │     │(压缩)   │     │(传输)   │
└─────────┘     └─────────┘     └─────────┘     └─────────┘
     │               │               │               │
     └───────────────┴───────────────┴───────────────┘
                        dma-buf 零拷贝
```

### 9.3 Android ION → DMA-BUF

Android 的 ION 内存分配器已迁移到 DMA-BUF Heap：

```c
// 旧方式 (ION)
int fd = ion_alloc(...);

// 新方式 (DMA-BUF Heap)
int fd = dma_heap_alloc(...);
```

### 9.4 虚拟化场景

```
┌─────────────────────────────────────────┐
│              Hypervisor                 │
│                                         │
│  Guest A                  Guest B      │
│  ┌─────────┐             ┌─────────┐   │
│  │ GPU     │──┐     ┌───│ 编码器  │   │
│  └─────────┘  │     │   └─────────┘   │
│               ▼     ▼                  │
│         ┌──────────────┐               │
│         │   dma-buf    │               │
│         │  (共享内存)  │               │
│         └──────────────┘               │
└─────────────────────────────────────────┘
```

---

## 十、性能优化与注意事项

### 10.1 缓存一致性

```c
// CPU 写入后，设备读取前
dma_buf_begin_cpu_access(dmabuf, DMA_TO_DEVICE);
// 写入数据到缓冲区
memcpy(buffer, data, size);
dma_buf_end_cpu_access(dmabuf, DMA_TO_DEVICE);

// 设备写入后，CPU 读取前
dma_buf_begin_cpu_access(dmabuf, DMA_FROM_DEVICE);
// 等待设备完成
dma_buf_end_cpu_access(dmabuf, DMA_FROM_DEVICE);
// 读取数据
memcpy(data, buffer, size);
```

### 10.2 避免常见错误

1. **忘记同步** — CPU 和设备访问前必须同步
2. **引用计数泄漏** — 必须配对调用 `dma_buf_get()`/`dma_buf_put()`
3. **错误的映射方向** — 使用正确的 `DMA_TO_DEVICE`/`DMA_FROM_DEVICE`
4. **忽略 fence** — 必须等待设备完成才能访问

### 10.3 性能监控

```bash
# 查看 DMA-BUF 使用情况
cat /sys/kernel/debug/dma_buf/bufinfo

# 追踪 DMA-BUF 操作
trace-cmd record -e dma_buf:* -p function_graph <command>
```

---

## 十一、总结

DMA-BUF 框架是 Linux 内核中实现高效硬件协同的关键基础设施：

**核心价值：**
- 零拷贝数据传输，降低 CPU 负载
- 统一的跨设备缓冲区管理接口
- 完善的同步机制保证正确性
- 支持进程间共享和用户空间访问

**关键设计：**
- 导出者-导入者分离
- 基于 fd 的传递机制
- dma-fence + dma-resv 同步
- scatterlist 抽象

**应用场景：**
- GPU/显示流水线
- 视频编解码
- 多媒体处理
- 虚拟化

DMA-BUF 已成为现代 Linux 多媒体和图形子系统的基石，对于理解高性能硬件加速至关重要。

---

## 参考资料

- `Documentation/driver-api/dma-buf.rst` — DMA-BUF 官方文档
- `drivers/dma-buf/dma-buf.c` — 核心实现
- `drivers/dma-buf/heaps/` — Heap 实现示例
- `include/linux/dma-buf.h` — 核心数据结构定义
- `include/uapi/linux/dma-buf.h` — 用户空间 API
