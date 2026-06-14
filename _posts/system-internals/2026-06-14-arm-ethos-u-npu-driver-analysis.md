---
layout: post
title: "Arm Ethos-U NPU 驱动深度分析：从硬件架构到 DRM/accel 框架"
date: 2026-06-14 18:00:00 +0800
excerpt: "深入分析 Linux mainline 中 Arm Ethos-U65/U85 NPU 驱动的完整实现，包括硬件命令流架构、DRM accel 子系统集成、GPU scheduler 调度、命令流验证机制、内存管理、中断处理与电源管理。基于 drivers/accel/ethosu/ 源码。"
---

# Arm Ethos-U NPU 驱动深度分析：从硬件架构到 DRM/accel 框架

基于 mainline `drivers/accel/ethosu/` 源码分析（作者：Rob Herring / Arm, Ltd.，2025 年合入）

---

## 一、Ethos-U 硬件概述

### 1.1 什么是 Ethos-U

Arm Ethos-U 是专为微控制器和嵌入式 SoC 设计的 **NPU (Neural Processing Unit)**，用于加速机器学习推理（如目标检测、关键词识别、姿态估计等）。

| 型号 | 定位 | MAC 单元 | 典型平台 |
|------|------|----------|----------|
| Ethos-U55 | MCU 级 | 32/64/128/256 MAC | Cortex-M55 搭配 |
| Ethos-U65 | 高性能嵌入式 | 256/512 MAC | Corstone-300/1000 |
| Ethos-U85 | 最新一代 | 128~2048 MAC | i.MX95 等 |

这个驱动支持 **U65 和 U85**。

### 1.2 硬件工作模型

Ethos-U 的核心设计是 **命令流 (Command Stream)** 驱动：

```
┌─────────────────────────────────────────────────────┐
│                   Ethos-U NPU                        │
│                                                     │
│  ┌─────────────┐    ┌──────────────────────────┐   │
│  │ Command     │    │  MAC Engine              │   │
│  │ Processor   │───▶│  (卷积/池化/逐元素运算)    │   │
│  └─────────────┘    └──────────────────────────┘   │
│        │                                            │
│        │ 读取命令流                                   │
│        ▼                                            │
│  ┌─────────────┐    ┌──────────────────────────┐   │
│  │ QBASE/QSIZE │    │  DMA Engine              │   │
│  │ (命令队列)   │    │  (数据搬运)               │   │
│  └─────────────┘    └──────────────────────────┘   │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  BASEP[0..7] — 8 个内存区域基地址寄存器        │  │
│  │  Region 0~7: 指向 IFM/OFM/权重/SRAM 等 buffer │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

CPU 准备好命令流 buffer 后，写入 `QBASE`（命令流基地址）和 `QSIZE`（命令流大小），然后写 `CMD` 寄存器让 NPU 开始执行。NPU 完成后产生中断。

### 1.3 关键寄存器

```c
#define NPU_REG_ID          0x0000  // NPU 版本信息
#define NPU_REG_STATUS      0x0004  // 状态（运行中/中断/错误）
#define NPU_REG_CMD         0x0008  // 命令（启动/清中断）
#define NPU_REG_RESET       0x000c  // 复位
#define NPU_REG_QBASE       0x0010  // 命令流基地址（低32位）
#define NPU_REG_QBASE_HI    0x0014  // 命令流基地址（高32位）
#define NPU_REG_QREAD       0x0018  // 当前命令流读取偏移（用于调试进度）
#define NPU_REG_QSIZE       0x0020  // 命令流大小
#define NPU_REG_BASEP(x)    (0x0080 + (x) * 8)  // 区域 x 基地址
```

---

## 二、驱动架构总览

### 2.1 文件结构

```
drivers/accel/ethosu/
├── ethosu_drv.c       — 主驱动：probe/remove、ioctl、reset、PM
├── ethosu_drv.h       — per-file 私有数据
├── ethosu_device.h    — 硬件寄存器定义、设备结构体
├── ethosu_gem.c       — GEM 内存对象管理 + 命令流验证
├── ethosu_gem.h       — GEM 对象定义
├── ethosu_job.c       — 作业调度（GPU scheduler 集成）
└── ethosu_job.h       — 作业结构体
```

### 2.2 框架选择：DRM/accel

驱动使用 **DRM accel 子系统**（`DRIVER_COMPUTE_ACCEL`），这是 Linux 6.2+ 新增的子系统，专门用于非图形的硬件加速器（NPU、DSP 等）。

```c
static const struct drm_driver ethosu_drm_driver = {
    .driver_features = DRIVER_COMPUTE_ACCEL | DRIVER_GEM,
    .open = ethosu_open,
    .postclose = ethosu_postclose,
    .ioctls = ethosu_drm_driver_ioctls,
    .gem_create_object = ethosu_gem_create_object,
    .name = "ethosu",
};
```

设备节点出现在 `/dev/accel/accel0`（不是 `/dev/dri/`），表明这是计算加速器而非 GPU。

### 2.3 依赖的内核基础设施

| 基础设施 | 用途 |
|----------|------|
| DRM/GEM | 内存对象管理（分配、mmap、引用计数） |
| DRM GPU Scheduler | 作业排队、超时处理、依赖管理 |
| dma_fence | 异步完成通知、跨 BO 依赖 |
| Runtime PM | NPU 空闲时自动下电 |
| gen_pool | SRAM 管理 |

---

## 三、UAPI：用户空间接口

### 3.1 IOCTL 列表

| IOCTL | 功能 |
|-------|------|
| `DRM_ETHOSU_DEV_QUERY` | 查询 NPU 信息（版本、MAC 数、SRAM 大小） |
| `DRM_ETHOSU_BO_CREATE` | 创建数据 buffer（输入/输出/权重） |
| `DRM_ETHOSU_BO_MMAP_OFFSET` | 获取 mmap 偏移（CPU 映射 buffer） |
| `DRM_ETHOSU_BO_WAIT` | 等待 buffer 上的推理完成 |
| `DRM_ETHOSU_CMDSTREAM_BO_CREATE` | 创建命令流 buffer（含验证） |
| `DRM_ETHOSU_SUBMIT` | 提交推理作业 |

### 3.2 典型用户空间流程

```c
// 1. 查询 NPU 信息
ioctl(fd, DRM_IOCTL_ETHOSU_DEV_QUERY, &query);

// 2. 创建数据 buffer（输入张量、输出张量、权重）
ioctl(fd, DRM_IOCTL_ETHOSU_BO_CREATE, &input_bo);
ioctl(fd, DRM_IOCTL_ETHOSU_BO_CREATE, &output_bo);
ioctl(fd, DRM_IOCTL_ETHOSU_BO_CREATE, &weight_bo);

// 3. mmap 并填充输入数据和权重
mmap(..., input_bo.offset);

// 4. 创建命令流（由 Vela 编译器生成，内核会验证）
ioctl(fd, DRM_IOCTL_ETHOSU_CMDSTREAM_BO_CREATE, &cmd_bo);

// 5. 提交推理作业
struct drm_ethosu_job job = {
    .cmd_bo = cmd_handle,
    .sram_size = 64 * 1024,
    .region_bo_handles = { input_handle, output_handle, 0, weight_handle, ... },
};
struct drm_ethosu_submit submit = { .jobs = &job, .job_count = 1 };
ioctl(fd, DRM_IOCTL_ETHOSU_SUBMIT, &submit);

// 6. 等待完成
ioctl(fd, DRM_IOCTL_ETHOSU_BO_WAIT, &wait);

// 7. 读取输出
```

---

## 四、命令流验证（安全核心）

这是驱动最复杂的部分，也是 **安全关键路径**。

### 4.1 为什么需要验证

命令流是 NPU 直接执行的指令序列。如果用户空间传入恶意命令流，NPU 可能访问任意物理地址——这是严重的安全漏洞。

驱动在 `CMDSTREAM_BO_CREATE` 时做完整验证：
- 解析每条命令，计算每个 region 的最大访问范围
- 提交时检查：命令流访问的范围不能超出用户提供的 BO 大小

### 4.2 命令流格式

命令流是 32-bit 指令数组，格式为：

```
┌────────────────────────────────────────┐
│ [31:16] param │ [15:0] command opcode  │  ← 单字命令
└────────────────────────────────────────┘

┌────────────────────────────────────────┐
│ [23:16] addr_hi │ [15:0] command       │  ← 双字命令 (bit14=1)
├────────────────────────────────────────┤
│ [31:0] addr_lo / value                 │
└────────────────────────────────────────┘
```

### 4.3 支持的操作

```c
enum ethosu_cmds {
    NPU_OP_CONV         = 0x2,   // 卷积
    NPU_OP_DEPTHWISE    = 0x3,   // 深度可分离卷积
    NPU_OP_POOL         = 0x5,   // 池化
    NPU_OP_ELEMENTWISE  = 0x6,   // 逐元素运算（加/乘/最大值等）
    NPU_OP_DMA_START    = 0x10,  // DMA 搬运
    NPU_SET_IFM_*       = 0x100+, // 设置输入特征图参数
    NPU_SET_OFM_*       = 0x110+, // 设置输出特征图参数
    NPU_SET_WEIGHT_*    = 0x120+, // 设置权重参数
    NPU_SET_DMA0_*      = 0x130+, // 设置 DMA 参数
    ...
};
```

### 4.4 验证逻辑

```c
static int ethosu_gem_cmdstream_copy_and_validate(...)
{
    // 1. 从用户空间拷贝命令流
    // 2. 逐条解析命令：
    //    - NPU_SET_* 命令：更新内部状态 (cmd_state)
    //    - NPU_OP_* 命令：根据 IFM/OFM/weight 参数计算访问范围
    // 3. 记录每个 region 的最大访问地址 → info->region_size[i]
    // 4. 记录哪些 region 是写目标 → info->output_region[i]
}
```

提交作业时：
```c
// 验证每个 region 的 BO 足够大
if (cmd_info->region_size[i] > gem->size) {
    return -EOVERFLOW;  // 命令流会越界，拒绝提交
}
```

### 4.5 Region 模型

NPU 通过 8 个 `BASEP` 寄存器访问内存，每个 region 对应一个 BO：

```
Region 0: 通常用于 IFM (输入特征图)
Region 1: 通常用于 OFM (输出特征图)
Region 2: SRAM（硬编码，由 Vela 编译器约定）
Region 3+: 权重、scale 等
```

命令流中的地址是 **region 内偏移**，实际物理地址 = `BASEP[region] + offset`。

---

## 五、作业调度（GPU Scheduler）

### 5.1 为什么用 DRM GPU Scheduler

- **依赖管理** — 多个作业可能共享 BO，需要按序执行
- **超时处理** — NPU 卡死时自动恢复
- **公平调度** — 多进程共享 NPU

### 5.2 调度流程

```
用户 SUBMIT ioctl
       │
       ▼
ethosu_ioctl_submit_job()
  ├── 查找 cmd_bo 和 region_bo（验证 handle 有效性）
  ├── 验证 region_size 不超出 BO 大小
  └── ethosu_job_push()
        ├── 锁定所有 BO 的 dma_resv
        ├── ethosu_acquire_object_fences() — 添加隐式依赖
        ├── drm_sched_job_arm() — 准备调度
        ├── drm_sched_entity_push_job() — 入队
        └── ethosu_attach_object_fences() — 给输出 BO 附加 fence
              │
              ▼
       GPU Scheduler 队列
              │
              ▼ (当依赖满足时)
ethosu_job_run()  ← scheduler 的 run_job 回调
  ├── 初始化 done_fence
  ├── dev->in_flight_job = job
  └── ethosu_job_hw_submit()
        ├── 写 BASEP[0..7] 寄存器（各 region 的物理地址）
        ├── 写 QBASE/QSIZE（命令流地址和大小）
        └── writel(CMD_TRANSITION_TO_RUN) — NPU 开始执行
              │
              ▼
       NPU 硬件执行命令流...
              │
              ▼ (完成)
       中断 → ethosu_job_irq_handler()
        ├── 清中断 (CMD_CLEAR_IRQ)
        └── ethosu_job_handle_irq()
              ├── 检查 STATUS（错误处理）
              └── dma_fence_signal(job->done_fence) — 通知完成
```

### 5.3 超时处理

```c
static enum drm_gpu_sched_stat ethosu_job_timedout(struct drm_sched_job *bad)
{
    // 1. 读 QREAD 检查 NPU 是否还在推进
    cmdaddr = readl(dev->regs + NPU_REG_QREAD);

    // 2. 如果仍在运行且有进展，再等 100ms
    ret = readl_poll_timeout(..., reg != cmdaddr, ...);
    if (!ret)
        return DRM_GPU_SCHED_STAT_NO_HANG;  // 没卡，继续等

    // 3. 确认卡死，执行恢复：
    drm_sched_stop(&dev->sched, bad);
    dev->in_flight_job = NULL;
    pm_runtime_force_suspend(dev);   // 断电
    pm_runtime_force_resume(dev);    // 重新上电 + reset
    drm_sched_start(&dev->sched);   // 重启调度器

    return DRM_GPU_SCHED_STAT_RESET;
}
```

超时默认 500ms（`JOB_TIMEOUT_MS`）。

---

## 六、内存管理 (GEM)

### 6.1 BO 类型

| 类型 | 创建方式 | 用途 | CPU 可 mmap？ |
|------|----------|------|---------------|
| 数据 BO | `BO_CREATE` | 输入/输出/权重 buffer | 可以 |
| 命令流 BO | `CMDSTREAM_BO_CREATE` | NPU 命令序列 | 不可以 (NO_MMAP) |

### 6.2 实现

使用 `drm_gem_dma_helper`（CMA 分配器），保证物理地址连续：

```c
struct ethosu_gem_object {
    struct drm_gem_dma_object base;  // CMA GEM 对象
    struct ethosu_validated_cmdstream_info *info;  // 仅命令流 BO 有
    u32 flags;
};
```

NPU 需要连续物理地址（没有 IOMMU/MMU），所以用 CMA 是合理的。DMA mask 设为 40-bit：

```c
dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(40));
```

### 6.3 SRAM 管理

Ethos-U 可以搭配片上 SRAM 作为临时 workspace（比外部 DRAM 快得多）：

```c
static int ethosu_sram_init(struct ethosu_device *ethosudev)
{
    // 从设备树获取 SRAM pool
    ethosudev->srampool = of_gen_pool_get(np, "sram", 0);
    // 分配整个 SRAM
    ethosudev->sram = gen_pool_dma_alloc(ethosudev->srampool, sram_size, &sramphys);
}
```

SRAM 固定映射到 Region 2（与 Vela 编译器约定一致）。

---

## 七、硬件初始化与复位

```c
static int ethosu_reset(struct ethosu_device *ethosudev)
{
    // 1. 触发复位
    writel(RESET_PENDING_CSL, regs + NPU_REG_RESET);
    readl_poll_timeout(regs + NPU_REG_STATUS, !STATUS_RESET_STATUS, ...);

    // 2. 确认非安全模式
    if (!FIELD_GET(PROT_ACTIVE_CSL, readl(regs + NPU_REG_PROT)))
        dev_warn(...);

    // 3. 配置 AXI 总线参数
    //    Region 2 (SRAM) → AXI M0 端口（低延迟）
    //    其他 Region → AXI M1 端口（高带宽）
    writel(0x0000aa8a, regs + NPU_REG_REGIONCFG);

    if (ethosu_is_u65(ethosudev)) {
        writel(U65_SRAM_AXI_LIMIT_CFG, regs + NPU_REG_AXILIMIT0);
        writel(U65_DRAM_AXI_LIMIT_CFG, regs + NPU_REG_AXILIMIT2);
    } else {  // U85
        writel(U85_AXI_SRAM_CFG, regs + NPU_REG_AXI_SRAM);
        writel(U85_AXI_EXT_CFG, regs + NPU_REG_AXI_EXT);
        writel(U85_MEM_ATTR0_CFG, regs + NPU_REG_MEM_ATTR0);
        writel(U85_MEM_ATTR2_CFG, regs + NPU_REG_MEM_ATTR2);
    }

    // 4. 清零 SRAM
    if (ethosudev->sram)
        memset_io(ethosudev->sram, 0, sram_size);
}
```

REGIONCFG 寄存器决定每个 region 走哪个 AXI master 端口，这对性能很重要：
- SRAM 走低延迟端口（M0）
- DRAM 走高带宽端口（M1）

---

## 八、电源管理

```c
static int ethosu_device_resume(struct device *dev)
{
    clk_bulk_prepare_enable(ethosudev->num_clks, ethosudev->clks);
    ethosu_reset(ethosudev);  // 每次上电都要重新初始化
}

static int ethosu_device_suspend(struct device *dev)
{
    clk_bulk_disable_unprepare(ethosudev->num_clks, ethosudev->clks);
}
```

使用 Runtime PM + autosuspend（50ms 延迟）：
- 提交作业时 `pm_runtime_resume_and_get()` — 唤醒 NPU
- 作业完成后 `pm_runtime_put_autosuspend()` — 50ms 无新作业则下电
- 超时恢复用 `pm_runtime_force_suspend/resume` 做硬复位

---

## 九、中断处理

```c
// 硬中断：快速确认
static irqreturn_t ethosu_job_irq_handler(int irq, void *data)
{
    u32 status = readl(dev->regs + NPU_REG_STATUS);
    if (!(status & STATUS_IRQ_RAISED))
        return IRQ_NONE;
    writel(CMD_CLEAR_IRQ, dev->regs + NPU_REG_CMD);  // 清中断
    return IRQ_WAKE_THREAD;
}

// 线程化中断：处理完成逻辑
static irqreturn_t ethosu_job_irq_handler_thread(int irq, void *data)
{
    // 检查错误
    if (status & (STATUS_BUS_STATUS | STATUS_CMD_PARSE_ERR))
        drm_sched_fault(&dev->sched);  // 通知调度器出错

    // 正常完成：signal fence
    dma_fence_signal(dev->in_flight_job->done_fence);
    dev->in_flight_job = NULL;
}
```

使用 threaded_irq 因为 `dma_fence_signal` 可能触发回调链，不适合在硬中断中执行。

---

## 十、完整数据流

```
┌─────────────────────────────────────────────────────────────────┐
│ 用户空间 (Vela 编译器生成命令流 + runtime)                         │
│                                                                 │
│  1. 编译模型 → 生成命令流（NPU 指令序列）                           │
│  2. BO_CREATE → 分配 input/output/weight buffer                  │
│  3. CMDSTREAM_BO_CREATE → 拷贝+验证命令流                         │
│  4. SUBMIT → 提交作业                                            │
└───────────────────────────────┬─────────────────────────────────┘
                                │ ioctl
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 内核驱动                                                         │
│                                                                 │
│  5. 验证 region BO 大小 ≥ 命令流访问范围                           │
│  6. 加入 GPU scheduler 队列，等待依赖                              │
│  7. run_job: 写 BASEP[] + QBASE + QSIZE + CMD                   │
└───────────────────────────────┬─────────────────────────────────┘
                                │ 寄存器写入
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ NPU 硬件                                                         │
│                                                                 │
│  8. 从 QBASE 读取命令流                                           │
│  9. 按命令执行：设置参数 → 执行 CONV/POOL/ELEMENTWISE              │
│     - 从 BASEP[region] + offset 读取 IFM/权重                    │
│     - 写结果到 BASEP[ofm_region] + offset                        │
│ 10. 命令流执行完毕 → 产生中断                                      │
└───────────────────────────────┬─────────────────────────────────┘
                                │ IRQ
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 中断处理                                                         │
│                                                                 │
│ 11. 清中断 → signal done_fence → 唤醒等待者                       │
│ 12. GPU scheduler 标记作业完成 → signal inference_done_fence      │
│ 13. BO_WAIT 返回 → 用户读取输出                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 十一、与 Vela 编译器的关系

Ethos-U NPU 不能直接执行 TFLite/ONNX 模型，需要 **Vela 编译器** 预处理：

```
TFLite 模型 → Vela 编译器 → 优化后的命令流 (command stream)
                              + 权重（重新排列/压缩）
                              + SRAM 分配策略
```

Vela 做的事：
1. 将算子映射为 NPU 硬件命令（CONV、POOL、ELEMENTWISE 等）
2. 切分大张量为 NPU 能处理的 tile
3. 决定 SRAM 分配策略（哪些中间结果放 SRAM）
4. 生成命令流二进制

驱动不做任何模型编译/优化，只负责：验证、调度、提交、完成通知。

---

## 十二、设计亮点总结

| 设计决策 | 原因 |
|----------|------|
| 使用 DRM/accel 而非自定义字符设备 | 复用 GEM 内存管理、GPU scheduler、dma_fence 等成熟基础设施 |
| 命令流内核验证 | 安全：防止 NPU 越界访问任意物理地址 |
| 用户空间生成命令流 | 灵活：编译器可以独立迭代，驱动只做验证+提交 |
| GPU Scheduler | 依赖管理 + 超时恢复 + 多进程公平 |
| credit_limit = 1 | NPU 一次只能跑一个作业（硬件限制） |
| Runtime PM + autosuspend 50ms | 推理通常是突发式的，快速下电省电 |
| CMA 内存 | NPU 无 IOMMU，需要物理连续地址 |
| SRAM Region 固定为 2 | 与 Vela 编译器约定，避免运行时协商 |

---

## 十三、代码量统计

```
ethosu_drv.c     — 280 行（probe、ioctl、reset、PM）
ethosu_gem.c     — 470 行（GEM 管理 + 命令流验证）
ethosu_job.c     — 330 行（调度、中断、超时）
ethosu_device.h  — 150 行（寄存器定义、命令枚举）
────────────────────────
总计约 1230 行
```

对于一个完整的 NPU 驱动来说非常精简——得益于 DRM 框架提供的大量基础设施和"用户空间编译、内核只验证提交"的设计哲学。
