---
layout: post
title: "Linux DMA Engine 子系统：设计理念、核心框架与 NXP SDMA/eDMA 实例"
date: 2026-06-14 14:30:00 +0800
excerpt: "深入分析 Linux DMA Engine 子系统的分层设计，包括 Provider-Consumer 模型、核心数据结构、传输流程，并以 NXP i.MX SDMA（脚本式）和 eDMA（硬件 TCD 式）两种 DMA 控制器为例详细讲解工作原理和设计差异。基于 mainline 源码。"
---

# Linux DMA Engine 子系统：设计理念、核心框架与 NXP SDMA/eDMA 实例

基于 mainline `drivers/dma/imx-sdma.c`、`drivers/dma/fsl-edma-*.c` 及 `include/linux/dmaengine.h` 源码分析

---

## 一、为什么需要 DMA Engine 子系统

在 DMA Engine 子系统出现之前，每个使用 DMA 的外设驱动（UART、SPI、Audio、网络等）都直接操作 DMA 控制器硬件。这带来以下问题：

1. **代码重复** — 每个外设驱动都要写一套 DMA 操作逻辑
2. **耦合严重** — 外设驱动和特定 DMA 控制器绑死
3. **不可移植** — 换个 SoC（DMA 控制器不同），外设驱动要大改
4. **资源管理混乱** — 多个驱动竞争 DMA 通道，没有统一的分配/释放机制

DMA Engine 子系统的核心目标：**将"谁需要搬运数据"和"谁负责搬运数据"彻底解耦**。

---

## 二、核心设计：Provider-Consumer 模型

```
┌──────────────────────────────────────────────────────────────┐
│                     Consumer（使用者）                          │
│          UART驱动 / SPI驱动 / Audio驱动 / ...                  │
│                                                              │
│     只需要说"我要从这个地址搬数据到那个地址，搬多少，搬完通知我"    │
└────────────────────────────┬─────────────────────────────────┘
                             │  统一 API (dmaengine_*)
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                   DMA Engine Framework                        │
│                                                              │
│   - 通道分配/释放 (dma_request_chan / dma_release_channel)     │
│   - 描述符管理 (dma_async_tx_descriptor)                      │
│   - 统一的传输提交/完成流程 (submit → issue → callback)         │
│   - 状态查询 (dma_tx_status)                                  │
│   - 设备树绑定 (of_dma)                                       │
└────────────────────────────┬─────────────────────────────────┘
                             │  ops 回调函数
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                  Provider（提供者/控制器驱动）                   │
│      imx-sdma / fsl-edma / pl330 / stm32-dma / ...           │
│                                                              │
│      实现具体硬件操作：配置寄存器、管理描述符、处理中断            │
└──────────────────────────────────────────────────────────────┘
```

**类比**：就像 block layer 把文件系统和磁盘驱动解耦一样，DMA Engine 把外设驱动和 DMA 控制器驱动解耦。UART 驱动在 i.MX6（SDMA）、i.MX93（eDMA）和 STM32（DMA）上可以用完全相同的代码。

---

## 三、核心数据结构

### 3.1 struct dma_device — DMA 控制器抽象

```c
struct dma_device {
    struct list_head channels;         // 该控制器拥有的所有通道
    dma_cap_mask_t cap_mask;           // 能力位图 (memcpy/slave/cyclic...)
    u32 src_addr_widths;               // 支持的源地址宽度
    u32 dst_addr_widths;               // 支持的目标地址宽度
    u32 directions;                    // 支持的传输方向

    // Provider 必须实现的回调函数：
    int (*device_alloc_chan_resources)(struct dma_chan *chan);
    void (*device_free_chan_resources)(struct dma_chan *chan);
    struct dma_async_tx_descriptor *(*device_prep_slave_sg)(...);
    struct dma_async_tx_descriptor *(*device_prep_dma_cyclic)(...);
    struct dma_async_tx_descriptor *(*device_prep_dma_memcpy)(...);
    int (*device_config)(struct dma_chan *chan, struct dma_slave_config *config);
    int (*device_terminate_all)(struct dma_chan *chan);
    enum dma_status (*device_tx_status)(...);
    void (*device_issue_pending)(struct dma_chan *chan);
};
```

### 3.2 struct dma_chan — DMA 通道

```c
struct dma_chan {
    struct dma_device *device;         // 所属控制器
    dma_cookie_t cookie;               // 最新提交的传输 cookie
    dma_cookie_t completed_cookie;     // 最近完成的 cookie
    void *private;                     // 私有数据（通道配置）
};
```

### 3.3 struct dma_async_tx_descriptor — 传输描述符

```c
struct dma_async_tx_descriptor {
    dma_cookie_t cookie;               // 此次传输的唯一标识
    struct dma_chan *chan;              // 所属通道
    dma_async_tx_callback callback;    // 完成回调
    void *callback_param;              // 回调参数
    dma_cookie_t (*tx_submit)(...);    // 提交函数
};
```

### 3.4 struct dma_slave_config — 从设备配置

```c
struct dma_slave_config {
    enum dma_transfer_direction direction;  // MEM_TO_DEV / DEV_TO_MEM
    phys_addr_t src_addr;                   // 源地址（外设 FIFO 物理地址）
    phys_addr_t dst_addr;                   // 目标地址
    enum dma_slave_buswidth src_addr_width; // 数据宽度 (1/2/4 字节)
    enum dma_slave_buswidth dst_addr_width;
    u32 src_maxburst;                       // 突发长度（watermark）
    u32 dst_maxburst;
};
```

### 3.5 数据结构关系图

```
dma_device (DMA 控制器)
 │
 ├── channels: dma_chan ──── dma_chan ──── dma_chan ...
 │                │
 │                └── private: imx_dma_data (event_id, peripheral_type)
 │
 └── ops: device_prep_slave_sg()
          device_prep_dma_cyclic()
          device_config()
          device_issue_pending()
                    │
                    ▼ 返回
          dma_async_tx_descriptor
           │
           ├── cookie (追踪 ID)
           ├── callback (完成通知)
           └── tx_submit() (排入队列)
```

---

## 四、三种传输模式

| 模式 | API | 场景 | 特点 |
|------|-----|------|------|
| **slave_sg** | `device_prep_slave_sg()` | SPI、NAND、一次性传输 | scatter-gather 列表，传完即止 |
| **cyclic** | `device_prep_dma_cyclic()` | Audio DMA（播放/录制） | 循环 buffer，自动绕回，每 period 通知 |
| **memcpy** | `device_prep_dma_memcpy()` | 纯内存拷贝加速 | mem-to-mem，无外设参与 |

为什么要分三种：
- Audio 需要循环不断搬运，每搬完一个 period 通知一次（对应硬件的 ring buffer）
- SPI 传输一次就结束，有明确的起止
- memcpy 不涉及外设，没有 watermark/event 概念，纯粹加速大块数据搬运

---

## 五、Consumer 使用 DMA 的标准流程

```c
// 1. 申请通道（从设备树解析 DMA 控制器和通道号）
chan = dma_request_chan(dev, "rx");

// 2. 配置通道（告诉 DMA 控制器外设信息）
struct dma_slave_config cfg = {
    .src_addr = uart_fifo_phys_addr,       // UART 的 FIFO 物理地址
    .src_addr_width = DMA_SLAVE_BUSWIDTH_1_BYTE,
    .src_maxburst = 8,                     // 每次突发读8字节
    .direction = DMA_DEV_TO_MEM,
};
dmaengine_slave_config(chan, &cfg);

// 3. 准备传输描述符
desc = dmaengine_prep_dma_cyclic(chan, buf_addr, buf_len, period_len,
                                  DMA_DEV_TO_MEM, flags);

// 4. 设置完成回调
desc->callback = my_dma_complete;
desc->callback_param = my_data;

// 5. 提交（排入软件队列，不触发硬件）
cookie = dmaengine_submit(desc);

// 6. 触发（开始真正的硬件传输）
dma_async_issue_pending(chan);

// 7. 完成后回调被调用，或主动查询状态
status = dma_async_is_tx_complete(chan, cookie, NULL, NULL);
```

### 步骤 5 和 6 为什么要分开？

```
submit()                              issue_pending()
   │                                       │
   ▼                                       ▼
┌────────────────┐                  ┌───────────────────┐
│ desc_submitted  │ ────移到────▶    │  desc_issued       │ ──取出──▶ 硬件
│ (已提交队列)    │                  │  (已发出队列)       │
└────────────────┘                  └───────────────────┘
```

1. **批量提交** — 可以先 submit 多个描述符，最后一次 issue_pending 统一启动
2. **原子性** — submit 只是软件排队，不涉及硬件竞争
3. **链式传输** — 多个 desc 排好队，硬件完成一个自动取下一个

---

## 六、设备树绑定：连接 Consumer 和 Provider

```dts
// SDMA 控制器
sdma: dma-controller@20ec000 {
    compatible = "fsl,imx6q-sdma";
    #dma-cells = <3>;
};

// eDMA 控制器
edma: dma-controller@44000000 {
    compatible = "fsl,imx93-edma3";
    #dma-cells = <3>;
};

// UART（Consumer）
uart1: serial@2020000 {
    dmas = <&sdma 25 4 0>, <&sdma 26 4 0>;
    dma-names = "rx", "tx";
    //         控制器 event_id peripheral_type priority
};
```

Consumer 调用 `dma_request_chan(dev, "rx")` 时：
1. 框架读取设备树 `dmas` 属性 → 找到 DMA 控制器
2. 调用控制器的 `of_dma_xlate()` 回调
3. 翻译参数为具体的通道 + 配置
4. 返回一个 `dma_chan` 给 Consumer

---

## 七、Provider 注册

```c
static int sdma_probe(struct platform_device *pdev)
{
    // 1. 注册能力
    dma_cap_set(DMA_SLAVE, sdma->dma_device.cap_mask);
    dma_cap_set(DMA_CYCLIC, sdma->dma_device.cap_mask);
    dma_cap_set(DMA_MEMCPY, sdma->dma_device.cap_mask);

    // 2. 填充回调
    sdma->dma_device.device_prep_slave_sg   = sdma_prep_slave_sg;
    sdma->dma_device.device_prep_dma_cyclic = sdma_prep_dma_cyclic;
    sdma->dma_device.device_config          = sdma_config;
    sdma->dma_device.device_terminate_all   = sdma_terminate_all;
    sdma->dma_device.device_tx_status       = sdma_tx_status;
    sdma->dma_device.device_issue_pending   = sdma_issue_pending;

    // 3. 注册到框架
    dma_async_device_register(&sdma->dma_device);

    // 4. 注册设备树 xlate
    of_dma_controller_register(np, sdma_xlate, sdma);
}
```

---

## 八、NXP SDMA 详解（脚本式 DMA）

### 8.1 架构特点

SDMA 独特之处：**内部有一个 RISC 微处理器，通过运行脚本 (microcode) 来执行传输**。

```
┌──────────────────────────────────────────────────────┐
│                    SDMA Engine                         │
│                                                      │
│  ┌─────────────────┐     ┌─────────────────────┐    │
│  │   RISC Core     │     │   32 Channels       │    │
│  │  (执行脚本)      │     │   (硬件 DMA 通道)    │    │
│  └─────────────────┘     └─────────────────────┘    │
│                                                      │
│  ┌─────────────────┐     ┌─────────────────────┐    │
│  │   ROM Scripts   │     │   RAM Scripts        │    │
│  │  (固化脚本)      │     │  (固件加载，可升级)   │    │
│  └─────────────────┘     └─────────────────────┘    │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  Channel Control Block (CCB) Array            │   │
│  │  每通道: base_bd_ptr + current_bd_ptr         │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  Buffer Descriptors (BD)                      │   │
│  │  描述每次传输的地址、大小、状态                   │   │
│  └──────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

### 8.2 为什么用脚本

不同外设有不同的 FIFO 行为：
- UART：单 FIFO，字节访问
- SAI (Audio)：多 FIFO，可能需要交织读写
- SPDIF：需要特殊的 padding/swallowing
- ASRC：外设到外设 (per-to-per)

脚本架构的好处：
1. **灵活** — 每种外设用不同脚本适配其特殊行为
2. **可升级** — 通过固件更新修复 bug 或添加新外设支持
3. **节省硬件** — 一套 RISC 核 + 脚本搞定所有外设

### 8.3 脚本地址表

```c
struct sdma_script_start_addrs {
    s32 ap_2_ap_addr;        // memory → memory
    s32 uart_2_mcu_addr;     // UART → memory
    s32 mcu_2_app_addr;      // memory → 通用外设
    s32 mcu_2_shp_addr;      // memory → SuperHighPerformance 外设
    s32 per_2_per_addr;      // 外设 → 外设 (ASRC)
    s32 sai_2_mcu_addr;      // SAI → memory (multi-FIFO)
    s32 mcu_2_sai_addr;      // memory → SAI
    ...
};
```

驱动根据 `peripheral_type` 选择脚本：

```c
static int sdma_get_pc(struct sdma_channel *sdmac, enum sdma_peripheral_type type)
{
    switch (type) {
    case IMX_DMATYPE_UART:
        per_2_emi = sdma->script_addrs->uart_2_mcu_addr;
        emi_2_per = sdma->script_addrs->mcu_2_app_addr;
        break;
    case IMX_DMATYPE_SSI:
    case IMX_DMATYPE_SAI:
        per_2_emi = sdma->script_addrs->app_2_mcu_addr;
        emi_2_per = sdma->script_addrs->mcu_2_app_addr;
        break;
    ...
    }
}
```

### 8.4 Buffer Descriptor (BD)

```c
struct sdma_buffer_descriptor {
    struct sdma_mode_count mode;   // count(16) + status(8) + command(8)
    u32 buffer_addr;               // 数据 buffer 物理地址
    u32 ext_buffer_addr;           // 扩展地址（memcpy 时为目标地址）
};
```

BD 状态位：
```c
#define BD_DONE  0x01  // SDMA 拥有此 BD（传输进行中）
#define BD_WRAP  0x02  // 最后一个 BD，绕回第一个（cyclic）
#define BD_CONT  0x04  // 完成后继续下一个 BD
#define BD_INTR  0x08  // 此 BD 完成后产生中断
#define BD_RROR  0x10  // 传输出错
#define BD_LAST  0x20  // 链中最后一个 BD
```

### 8.5 Channel 0 — 控制通道

Channel 0 是 ARM 核心和 SDMA 引擎通信的特殊通道：

```c
// 加载脚本到 SDMA 程序内存
bd0->mode.command = C0_SETPM;
sdma_run_channel0(sdma);

// 加载通道上下文（PC、外设地址、watermark）
context->channel_state.pc = load_address;  // 脚本入口
context->gReg[2] = sdmac->per_addr;        // 外设地址
context->gReg[7] = sdmac->watermark_level;

bd0->mode.command = C0_SETDM;
sdma_run_channel0(sdma);
```

### 8.6 固件加载

```c
static void sdma_load_firmware(const struct firmware *fw, void *context)
{
    // 校验 magic ("SDMA")
    // 通过 channel 0 将 RAM 脚本下载到 SDMA 内部 RAM
    sdma_load_script(sdma, ram_code, header->ram_code_size,
                     addr->ram_code_start_addr);
    // 合并脚本地址
    sdma_add_scripts(sdma, addr);
}
```

### 8.7 中断处理

```c
static irqreturn_t sdma_int_handler(int irq, void *dev_id)
{
    stat = readl_relaxed(sdma->regs + SDMA_H_INTR);
    writel_relaxed(stat, sdma->regs + SDMA_H_INTR);
    stat &= ~1;  // channel 0 不在这里处理

    while (stat) {
        int channel = fls(stat) - 1;

        if (sdmac->flags & IMX_DMA_SG_LOOP)
            sdma_update_channel_loop(sdmac);  // cyclic：更新 BD，回调
        else {
            mxc_sdma_handle_channel_normal(sdmac);  // 单次：标记完成
            sdma_start_desc(sdmac);                  // 启动下一个传输
        }

        __clear_bit(channel, &stat);
    }
}
```

### 8.8 Cyclic 模式 BD 环形处理

```c
static void sdma_update_channel_loop(struct sdma_channel *sdmac)
{
    while (sdmac->desc) {
        bd = &desc->bd[desc->buf_tail];
        if (bd->mode.status & BD_DONE)
            break;  // SDMA 还在用

        desc->buf_tail = (desc->buf_tail + 1) % desc->num_bd;

        // 通知 Consumer 一个 period 的数据到了
        dmaengine_desc_get_callback_invoke(&desc->vd.tx, NULL);

        // 归还 BD 给 SDMA 继续搬运
        bd->mode.status |= BD_DONE;
    }
}
```

---

## 九、NXP eDMA 详解（硬件 TCD 式 DMA）

### 9.1 架构特点

eDMA 与 SDMA 完全不同：**不需要固件，传输逻辑由硬件状态机固定实现，通过 TCD (Transfer Control Descriptor) 配置传输参数**。

```
┌──────────────────────────────────────────────────────┐
│                    eDMA Engine                         │
│                                                      │
│  ┌─────────────────┐     ┌─────────────────────┐    │
│  │  Hardware State │     │   N Channels         │    │
│  │  Machine        │     │  (每通道独立 TCD 寄存器)│    │
│  └─────────────────┘     └─────────────────────┘    │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  TCD Registers (per channel)                  │   │
│  │  saddr/soff/attr/nbytes/slast/daddr/doff/...  │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  DMAMUX (v1/v2) 或 内建 CH_MUX (v3/v4)       │   │
│  │  将外设 DMA 请求路由到通道                       │   │
│  └──────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

### 9.2 核心概念：TCD (Transfer Control Descriptor)

TCD 是 eDMA 的灵魂，一个 32 字节的结构完整描述一次传输：

```c
struct fsl_edma_hw_tcd {
    __le32 saddr;       // 源地址
    __le16 soff;        // 每次读取后源地址偏移
    __le16 attr;        // 源/目标数据宽度 (SSIZE/DSIZE)
    __le32 nbytes;      // 每次 minor loop 传输的字节数
    __le32 slast;       // major loop 结束后源地址调整
    __le32 daddr;       // 目标地址
    __le16 doff;        // 每次写入后目标地址偏移
    __le16 citer;       // 当前剩余 major loop 迭代次数
    __le32 dlast_sga;   // major loop 结束后目标地址调整 / scatter-gather 链接
    __le16 csr;         // 控制状态
    __le16 biter;       // 起始 major loop 迭代总次数
};
```

64-bit 地址版本（eDMA v4，用于 i.MX93/95）：

```c
struct fsl_edma_hw_tcd64 {
    __le64 saddr;       // 64-bit 源地址
    __le16 soff;
    __le16 attr;
    __le32 nbytes;
    __le64 slast;       // 64-bit 调整
    __le64 daddr;       // 64-bit 目标地址
    __le64 dlast_sga;   // 64-bit scatter-gather
    __le16 doff;
    __le16 citer;
    __le16 csr;
    __le16 biter;
};
```

### 9.3 传输模型：Minor Loop + Major Loop

```
                    ┌── Minor Loop (一次 DMA 请求触发) ──┐
                    │                                    │
                    │  传输 nbytes 字节                   │
                    │  saddr += soff (每拍)              │
                    │  daddr += doff (每拍)              │
                    │                                    │
                    └────────────────────────────────────┘
                              × citer 次
                    ┌──────────── Major Loop ────────────┐
                    │                                    │
                    │  执行 citer 次 minor loop           │
                    │  每完成一次 minor loop: citer--     │
                    │  citer=0 时: major loop 完成       │
                    │  saddr += slast (回绕/调整)         │
                    │  daddr += dlast_sga (回绕/链接)     │
                    │  触发中断 / scatter-gather          │
                    └────────────────────────────────────┘
```

对应到实际场景：
- **Minor Loop** = 一次 DMA 请求传多少字节 = `src_maxburst × src_addr_width`
- **Major Loop** = 整个传输需要多少次 minor loop = `total_size / nbytes`
- **slast/dlast** = cyclic 模式下 buffer 回绕（设为 `-total_size`）

### 9.4 Scatter-Gather (TCD 链)

eDMA 硬件原生支持 scatter-gather——**不需要 CPU 介入，硬件自动加载下一个 TCD**：

```
TCD0 (period 0) ──▶ TCD1 (period 1) ──▶ TCD2 (period 2) ──▶ TCD3 (period 3)
 ↑                                                                │
 └────────────── dlast_sga 指回 TCD0 (cyclic 模式) ────────────────┘
```

每个 TCD 的 `dlast_sga` 存储下一个 TCD 的物理地址，设置 `E_SG` bit，major loop 完成后硬件自动加载下一个 TCD 到通道寄存器。

CSR 控制位：
```c
#define EDMA_TCD_CSR_START      BIT(0)  // 立即启动传输
#define EDMA_TCD_CSR_INT_MAJOR  BIT(1)  // major loop 完成时中断
#define EDMA_TCD_CSR_INT_HALF   BIT(2)  // 半程中断
#define EDMA_TCD_CSR_D_REQ      BIT(3)  // 完成后自动禁用请求
#define EDMA_TCD_CSR_E_SG       BIT(4)  // 启用 scatter-gather
#define EDMA_TCD_CSR_E_LINK     BIT(5)  // major link（完成后触发另一通道）
```

### 9.5 eDMA 通道寄存器（v3/v4）

eDMA v3+ 每个通道有独立的寄存器空间：

```c
struct fsl_edma3_ch_reg {
    __le32 ch_csr;      // 通道控制状态（ERQ 使能、DONE、ACTIVE）
    __le32 ch_es;       // 通道错误状态
    __le32 ch_int;      // 中断标志
    __le32 ch_sbr;      // 系统总线属性（读/写标志）
    __le32 ch_pri;      // 通道优先级
    __le32 ch_mux;      // DMA 请求源选择（内建 MUX）
    __le32 ch_mattr;    // 内存属性（eDMA v4）
    __le32 ch_reserved;
    union {
        struct fsl_edma_hw_tcd tcd;    // 32-bit TCD
        struct fsl_edma_hw_tcd64 tcd64; // 64-bit TCD
    };
};
```

### 9.6 DMAMUX vs 内建 MUX

| 版本 | 请求路由方式 |
|------|------------|
| eDMA v1/v2 | 外部 DMAMUX 模块：`EDMAMUX_CHCFG_SOURCE(n) | EDMAMUX_CHCFG_ENBL` |
| eDMA v3/v4 | 内建 `ch_mux` 寄存器，直接写 source ID |

### 9.7 例：UART RX DMA cyclic (period=64B, buf=256B, 4 periods)

```c
// 分配 4 个 TCD（每个对应一个 period）
for (i = 0; i < 4; i++) {
    tcd[i].saddr = UART_FIFO_PHYS;      // 源 = UART FIFO（固定地址）
    tcd[i].soff  = 0;                     // FIFO 地址不变
    tcd[i].daddr = dma_buf + i * 64;     // 目标 = buffer 偏移
    tcd[i].doff  = 1;                     // 每字节目标地址+1
    tcd[i].attr  = SSIZE(0) | DSIZE(0);  // 1字节宽度
    tcd[i].nbytes = 1;                    // 每次 minor loop 1字节
    tcd[i].citer = 64;                    // 64次 minor loop = 1 period
    tcd[i].biter = 64;
    tcd[i].slast = 0;                     // 源不调整
    tcd[i].dlast_sga = tcd[(i+1) % 4].phys;  // 指向下一个 TCD（环形）
    tcd[i].csr = EDMA_TCD_CSR_INT_MAJOR | EDMA_TCD_CSR_E_SG;
}
// 把 tcd[0] 写入通道 TCD 寄存器，启动
```

### 9.8 中断处理

```c
// eDMA 中断处理更简单——直接检查通道标志
irqreturn_t fsl_edma_tx_chan_handler(struct fsl_edma_chan *fsl_chan)
{
    // 清中断
    edma_writel_chreg(fsl_chan, 1, ch_int);

    // 通知完成
    vchan_cyclic_callback(&desc->vdesc);  // cyclic
    // 或
    vchan_cookie_complete(&desc->vdesc);  // 单次
}
```

### 9.9 eDMA 版本演进

| 版本 | 平台 | 通道数 | 特点 |
|------|------|--------|------|
| v1/v2 | i.MX RT、Vybrid | 32 | 共享寄存器空间，外部 DMAMUX |
| v3 | i.MX8 QM/QXP | 32 | 通道独立寄存器(SPLIT_REG)、内建 MUX、8字节总线 |
| v4 | i.MX93/95 | 64 | TCD64 支持 64-bit 地址、per-channel 电源域 |

驱动通过 flags 区分：
```c
#define FSL_EDMA_DRV_EDMA3  (FSL_EDMA_DRV_SPLIT_REG | FSL_EDMA_DRV_BUS_8BYTE | ...)
#define FSL_EDMA_DRV_EDMA4  (FSL_EDMA_DRV_SPLIT_REG | FSL_EDMA_DRV_BUS_8BYTE | ...)
#define FSL_EDMA_DRV_TCD64  BIT(15)
```

---

## 十、SDMA vs eDMA 完整对比

| 维度 | SDMA | eDMA |
|------|------|------|
| **传输引擎** | RISC 微处理器 + microcode 脚本 | 硬件状态机 (Minor/Major Loop) |
| **描述符** | BD (Buffer Descriptor) | TCD (Transfer Control Descriptor) |
| **链式传输** | BD 链 (BD_WRAP / BD_CONT) | TCD scatter-gather (E_SG + dlast_sga) |
| **外设适配** | 不同外设用不同脚本 | TCD 参数配置（soff/doff/nbytes 组合） |
| **通道配置** | 通过 channel 0 加载上下文到 SDMA 内部 RAM | 直接写通道 TCD 寄存器 |
| **固件** | 必须加载（RAM 脚本） | 不需要 |
| **循环模式** | BD_WRAP（最后一个 BD 绕回） | TCD 链尾的 dlast_sga 指回链头 |
| **中断粒度** | per BD (BD_INTR) | per TCD (INT_MAJOR / INT_HALF) |
| **寻址能力** | 32-bit | v4 支持 64-bit (TCD64) |
| **通道数** | 32 | 32~64 |
| **CPU 开销** | 高（需要 channel 0 通信） | 低（直接寄存器读写） |
| **灵活性** | 极高（脚本可做任意逻辑） | 有限（但 minor loop offset 等特性覆盖大多数场景） |
| **调试难度** | 高（脚本不透明） | 低（TCD 状态可直接读取） |
| **用于** | i.MX6/7/8M 系列 | i.MX RT、i.MX8 QM/QXP、i.MX9 系列 |

### 为什么 NXP 新平台全面转向 eDMA

1. **简单可靠** — 不需要固件，少一个故障点
2. **调试友好** — TCD 寄存器状态可直接读取，不像 SDMA 内部状态不可见
3. **性能更好** — 直接写寄存器启动，不需要通过 channel 0 中转
4. **64-bit 支持** — TCD64 天然支持大于 4GB 的地址空间
5. **per-channel 电源** — v4 每个通道可独立管理电源域
6. **硬件 scatter-gather** — 无需 CPU 介入即可链式传输

SDMA 的脚本灵活性在某些极端场景（如 multi-FIFO SAI 交织、ASRC per-to-per 配合 padding）仍有价值，但对 90% 以上的使用场景，eDMA 的硬件 TCD 方案已经足够。

---

## 十一、完整传输流程对比

### SDMA (以 UART RX 为例)

```
dma_request_chan()
    → of_dma_xlate → 得到 event_id=25, type=UART

dmaengine_slave_config()
    → sdma_config() → watermark = maxburst * width
                     → sdma_get_pc() → pc = uart_2_mcu_addr

dmaengine_prep_dma_cyclic()
    → sdma_prep_dma_cyclic()
        → 分配 BD 数组（环形，BD_WRAP）
        → sdma_load_context(): channel 0 加载 {pc, per_addr, watermark}

dmaengine_submit()
    → desc 入 desc_submitted 队列

dma_async_issue_pending()
    → sdma_issue_pending()
        → 设置 CCB.base_bd_ptr
        → writel(BIT(ch), SDMA_H_START)  // 启动

硬件运行: event → SDMA RISC 执行脚本 → 从 FIFO 搬到 buffer → 中断
中断: sdma_int_handler() → sdma_update_channel_loop() → callback
```

### eDMA (以 UART RX 为例)

```
dma_request_chan()
    → of_dma_xlate → 得到 source_id, channel

dmaengine_slave_config()
    → fsl_edma_slave_config() → 保存 src_addr, width, maxburst

dmaengine_prep_dma_cyclic()
    → fsl_edma_prep_dma_cyclic()
        → 分配 TCD 数组（dma_pool）
        → 填充每个 TCD: saddr/daddr/nbytes/citer/...
        → TCD 链接成环（dlast_sga + E_SG）

dmaengine_submit()
    → desc 入 desc_submitted 队列

dma_async_issue_pending()
    → fsl_edma_issue_pending()
        → 把 TCD 写入通道寄存器
        → 设置 ch_csr.ERQ = 1  // 使能请求

硬件运行: DMA request → 硬件执行 minor loop → major loop 完成 → 自动加载下一 TCD → 中断
中断: fsl_edma_tx_chan_handler() → clear ch_int → callback
```

---

## 十二、virt-dma 辅助层

SDMA 和 eDMA 驱动都使用了 `virt-dma` 辅助框架：

```c
struct sdma_channel {
    struct virt_dma_chan vc;  // SDMA
};
struct fsl_edma_chan {
    struct virt_dma_chan vchan;  // eDMA
};
```

virt-dma 提供统一的软件队列管理：
- `desc_submitted` 链表 — submit 后暂存
- `desc_issued` 链表 — issue_pending 后
- `vchan_tx_prep()` / `vchan_issue_pending()` / `vchan_cookie_complete()`
- tasklet 机制执行 Consumer 的完成回调

---

## 十三、总结

### 设计分层

| 层次 | 职责 | 关键文件 |
|------|------|----------|
| Consumer | 调用标准 API，不关心底层硬件 | 各外设驱动 |
| Framework | 统一 API、通道管理、设备树绑定 | `include/linux/dmaengine.h` |
| virt-dma | 描述符队列管理辅助 | `drivers/dma/virt-dma.h` |
| Provider | 实现硬件操作 | `drivers/dma/imx-sdma.c`、`drivers/dma/fsl-edma-*.c` |

### 核心设计思想

1. **解耦** — Consumer 不知道底层是 SDMA/eDMA/PL330，通过统一接口调用
2. **标准化** — 所有 DMA 控制器统一注册、统一分配通道、统一提交传输
3. **灵活性** — Provider 可以有完全不同的硬件架构（脚本 vs TCD vs PL330 microcode），只要实现相同的 ops 接口

这就是分层设计的价值——UART 驱动从 i.MX6（SDMA）迁移到 i.MX93（eDMA），代码 **零修改**，只需设备树指向不同的 DMA 控制器。
