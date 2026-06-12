---
layout: post
title: "MIPI CSI-2 协议详解及 i.MX93 CSI 控制器分析"
date: 2026-06-08 16:00:00 +0800
excerpt: "从物理层到协议层全面解析 MIPI CSI-2，结合 i.MX93 的 Synopsys CSI-2 Host Controller 和 ISI 模块进行实际分析，包括虚拟通道、IPI 接口、数据包格式等。"
---

# MIPI CSI-2 协议详解及 i.MX93 CSI 控制器分析

## 1. 整体架构分层

```
┌─────────────────────────────────────────────┐
│          应用层 (Application Layer)           │
│         图像数据、嵌入式数据                    │
├─────────────────────────────────────────────┤
│        协议层 (Protocol Layer)               │
│    数据包封装、虚拟通道、数据类型               │
├─────────────────────────────────────────────┤
│        通道管理层 (Lane Management)           │
│       多 Lane 分发与合并                      │
├─────────────────────────────────────────────┤
│        物理层 (PHY Layer - D-PHY)            │
│    差分信号、高速/低功耗模式                    │
└─────────────────────────────────────────────┘
```

## 2. 物理层 (D-PHY)

CSI-2 使用 MIPI D-PHY 作为物理层。

### 信号线组成

- 1 个 Clock Lane（差分对：CLK_P / CLK_N）
- 1~4 个 Data Lane（每个是差分对：D0_P/D0_N, D1_P/D1_N...）
- imx93 支持最多 2 个 Data Lane

### 两种工作模式

| 模式 | 速率 | 用途 |
|------|------|------|
| 高速模式 (HS) | 80Mbps ~ 2.5Gbps/lane | 传输图像数据 |
| 低功耗模式 (LP) | ≤10Mbps | 控制信号、总线翻转 |

### 传输时序

```
LP-11 → LP-01 → LP-00 → HS-0 → [HS数据传输] → LP-11
 空闲    请求     桥接    同步码    高速突发       空闲
```

## 3. 协议层 - 数据包结构

CSI-2 有两种包：

### 短包 (Short Packet) - 4 字节

```
┌──────────┬────────────┬──────────────┬─────────┐
│ Data ID  │  Data Field (16-bit)      │  ECC    │
│ (1 byte) │  (2 bytes)               │ (1 byte)│
└──────────┴────────────┴──────────────┴─────────┘
     │
     ├─ VC[1:0]: 虚拟通道 (2 bit)
     └─ DT[5:0]: 数据类型 (6 bit)
```

短包用于传输同步信号：
- **Frame Start (FS)** — DT=0x00，帧开始
- **Frame End (FE)** — DT=0x01，帧结束
- **Line Start (LS)** — DT=0x02，行开始（可选）
- **Line End (LE)** — DT=0x03，行结束（可选）

### 长包 (Long Packet) - 可变长度

```
┌────────────────┬─────────────────────────────┬──────────┐
│  Packet Header │        Payload              │  Packet  │
│    (4 bytes)   │    (0 ~ 65535 bytes)        │  Footer  │
│                │                             │ (2 bytes)│
└────────────────┴─────────────────────────────┴──────────┘

Packet Header:
┌──────────┬──────────────────┬─────────┐
│ Data ID  │ Word Count (WC)  │  ECC    │
│ (1 byte) │ (2 bytes)        │ (1 byte)│
└──────────┴──────────────────┴─────────┘

Packet Footer:
┌──────────────────┐
│    CRC (16-bit)  │
└──────────────────┘
```

长包用于传输实际图像数据和嵌入式数据。

## 4. Data ID 字段详解

```
Data ID (8 bit):
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│ VC1 │ VC0 │ DT5 │ DT4 │ DT3 │ DT2 │ DT1 │ DT0 │
└─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
  虚拟通道       数据类型 (Data Type)
```

### 常见数据类型 (DT)

| DT 值 | 含义 |
|--------|------|
| 0x00 | Frame Start |
| 0x01 | Frame End |
| 0x12 | Embedded Data (8-bit) |
| 0x1E | YUV422 8-bit |
| 0x22 | RGB565 |
| 0x24 | RGB888 |
| 0x28 | RAW6 |
| 0x2A | RAW8 |
| 0x2B | RAW10 |
| 0x2C | RAW12 |
| 0x2D | RAW14 |

## 5. 虚拟通道 (Virtual Channel)

```
                    CSI-2 物理链路（共享）
Sensor A (VC0) ──┐
                  ├──→ [Clock Lane + Data Lanes] ──→ CSI-2 Controller
Sensor B (VC1) ──┘                                       │
                                                    ┌────┴────┐
                                                    │按 VC 分离│
                                                    ├────┬────┤
                                                  VC0    VC1
                                                  数据   数据
```

- 每个包的 Data ID 里有 2-bit VC 字段（CSI-2 v1.x 支持 VC0~VC3）
- 接收端按 VC 过滤，只处理感兴趣的通道
- 同一 sensor 也可以用多个 VC（比如 VC0 发图像，VC1 发 metadata）
- CSI-2 v2.0+ 扩展到最多 16 个虚拟通道（4-bit VC ID）

## 6. 一帧数据的传输流程

```
时间轴 →

[LP-11 空闲]
    │
    ▼
[Short Packet: Frame Start, VC=0, DT=0x00]
    │
    ▼
[Long Packet: Line 1 数据, VC=0, DT=0x2B(RAW10), WC=行字节数]
    │
    ▼
[Long Packet: Line 2 数据, VC=0, DT=0x2B(RAW10), WC=行字节数]
    │
    ▼
   ...（逐行传输）
    │
    ▼
[Long Packet: Line N 数据]
    │
    ▼
[Short Packet: Frame End, VC=0, DT=0x01]
    │
    ▼
[LP-11 空闲，等待下一帧]
```

## 7. 多 Lane 数据分发

数据按字节轮流分配到各 Lane：

```
2-Lane 模式:
Byte 0 → Lane 0
Byte 1 → Lane 1
Byte 2 → Lane 0
Byte 3 → Lane 1
...

总带宽 = 单 Lane 速率 × Lane 数
例: 1.5Gbps/lane × 2 lanes = 3Gbps = 375MB/s
```

## 8. ECC 和 CRC 校验

- **ECC (6-bit)** — 保护 Packet Header 的前 3 字节，能纠 1-bit 错误，检测 2-bit 错误
- **CRC (16-bit)** — 保护整个 Payload 数据完整性

---

## 9. i.MX93 CSI-2 控制器分析

imx93 集成的是 **Synopsys DesignWare MIPI CSI-2 Host Controller** IP（非 NXP 自研）。

### 硬件架构

```
                        CSI-2 Host Controller
                    ┌─────────────────────────────────────────────┐
                    │                                             │
 D-PHY Lane 0 ────►│  PPI Data     ┌──────────┐                  │
 (rxdatahs_0)      │  Processor    │ Packet   │    ┌─────┐      │──► IPI 输出
                    │  (Lane Sync)  │ Analyzer │───►│ IPI │      │   (48-bit pixel bus
 D-PHY Lane 1 ────►│               │(合并+解码)│    │Controller│  │    + vsync/hsync)
 (rxdatahs_1)      │  De-scrambler │          │    └─────┘      │
                    │               └──────────┘                  │
 D-PHY CLK ───────►│  PHY Adaptation Layer                       │
                    │                                             │
                    │  PPI Pattern Generator (调试用)              │
                    │                                             │
                    │  Error Handler ─────────────────────────────│──► interrupt
                    │                                             │
          APB ◄───►│  Register Bank                              │
                    └─────────────────────────────────────────────┘
```

### 各模块功能

#### PPI Data Processor（物理协议接口处理器）

- 接收来自 D-PHY 的原始字节流
- Lane 同步：两条 Data Lane 可能存在 skew，此模块对齐它们
- 可配置 1 级 pipeline 缓冲，降低 PHY→Controller 时序要求
- 缓冲的信号：`rxdatahs`、`rxvalidhs`、`errsoths`、`errsotsynchs`

#### De-scrambler（解扰器）

- CSI-2 传输时经 LFSR 加扰（减少 EMI）
- 多项式：`G(x) = x^16 + x^5 + x^4 + x^3 + 1`
- 每条 Lane 独立一个解扰实例，各自可配不同 16-bit seed
- 寄存器：`SCRAMBLING`（使能）、`SCRAMBLING_SEED1`、`SCRAMBLING_SEED2`

#### Packet Analyzer（包分析器）

协议解析核心：
- 多 Lane 数据合并：把 Lane 0/1 字节按顺序交织还原为完整数据包
- Header 解码：解析 Data ID（VC + DT）和 Word Count
- ECC 校验：纠正 1-bit 错误，检测 2-bit 错误
- CRC 校验：验证 payload 完整性
- 帧大小检测：行/帧数据是否符合预期

#### IPI Controller（图像像素接口控制器）

最重要的输出模块，把 CSI-2 数据包转换为像素流：

| 特性 | 说明 |
|------|------|
| 输出总线宽度 | 48-bit 或 16-bit 可选 |
| 虚拟通道过滤 | `IPI_VCID` 寄存器选择，只处理 1 个 VC |
| 数据类型过滤 | `IPI_DATA_TYPE` 寄存器配置 |
| 内部 FIFO | 双端口 RAM，最小深度 32 |
| 背压机制 | `ipi_halt` 信号暂停输出 |

**两种时序模式：**

- **Camera Timing**：vsync/hsync 从 sensor 发的 FS/LS 短包提取，适合普通摄像头
- **Controller Timing**：由控制器寄存器生成帧时序（VSA/VBP/VACTIVE/VFP/HSA/HBP/HLINE），适合严格视频时序场景

Controller Timing 帧结构：

```
├── VSA (IPI_VSA_LINES) ──────── 垂直同步
├── VBP (IPI_VBP_LINES) ──────── 垂直后肩
├── VACTIVE (IPI_VACTIVE_LINES)─ 有效图像区域
├── VFP (IPI_VFP_LINES) ──────── 垂直前肩

每行内：
├── HSA (IPI_HSA_TIME) ────────── 水平同步
├── HBP (IPI_HBP_TIME) ────────── 水平后肩
├── Video Zone ────────────────── 有效像素
├── HFP (剩余时间) ────────────── 水平前肩
```

#### Error Handler（错误处理器）

| 错误类型 | 含义 |
|----------|------|
| PHY errors | SOT 同步码不匹配 |
| Packet errors | ECC/CRC 校验失败 |
| Line errors | LS/LE 不匹配、行序列错误 |
| Frame errors | FS/FE 不匹配、帧序列错误 |
| IPI errors | IPI 层面溢出/行超时 |

#### PPI Pattern Generator（调试用）

- 内部注入测试包，不需要外接真实 sensor
- 可编程 packet-to-packet 间隔
- 用于芯片验证和驱动调试

### imx93 规格限制

| 参数 | 值 |
|------|------|
| Data Lanes | 最多 2 lanes |
| 协议版本 | CSI-2 v1.2 |
| D-PHY 版本 | v1.2 |
| IPI 数量 | 1 个（只能同时处理 1 路 VC） |
| ISI 实例 | 1 个（支持 1080p30 处理） |
| 支持格式 | RGB/YUV/RAW/User-defined/Embedded |
| 像素位深 | 48-bit 或 16-bit 模式 |

### 初始化流程

手册给出的编程顺序（Reference Manual Section 54.4）：

1. 释放 PHY test codes 复位
2. 配置 PHY 频率范围
3. 可选：额外 PHY test code 配置
4. 配置活跃 Lane 数量
5. 释放 PHY 复位
6. 可选：配置 Data ID 值
7. 定义要屏蔽的错误中断
8. 释放 CSI-2 控制器复位
9. 检查 Data Lanes 进入 Stop State

### 虚拟通道支持情况

根据手册：

> "The IPI monitors packets that match the virtual channel, programmed in the IPI_VCID register. All other Virtual Channel identifier packets are ignored."

> "The ISI module on the chip implements one channel and one camera input. Virtual channels are not supported."

结论：CSI-2 控制器协议层能识别 VC0~VC3，可通过 `IPI_VCID` 寄存器选择监听哪个 VC，但由于只有 1 个 IPI + 1 个 ISI 通道，**同一时间只能接收 1 路虚拟通道的视频流**。

---

## 10. ISI（Image Sensing Interface）通道

ISI 是 CSI-2 控制器的下游处理单元，负责把像素流加工后写入 DDR。

### 在系统中的位置

```
Camera Sensor (如 imx678)
       │
       │  2-lane MIPI CSI-2 差分信号
       ▼
┌──────────────┐
│  MIPI D-PHY   │  物理层：差分信号 → 数字字节
│  (Chapter 55) │
└──────┬───────┘
       │  PPI (8-bit per lane)
       ▼
┌──────────────┐
│  CSI-2        │  协议层：包解析、ECC/CRC、VC 过滤
│  Controller   │
│  (Chapter 54) │
└──────┬───────┘
       │  IPI (48-bit pixel bus + sync signals)
       ▼
┌──────────────┐
│  ISI          │  处理层：缩放、色彩转换、DMA
│  (Chapter 57) │
└──────┬───────┘
       │  AXI DMA
       ▼
   DDR Memory → CPU/NPU 消费
```

### ISI 处理 Pipeline

```
像素输入 (Pixel Link)
    │
    ▼
┌──────────────┐
│  Scaler       │  缩放：抽取(÷2/4/8) + 双线性滤波(÷1.0~2.0)，最大 ÷16
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  CSC          │  色彩空间转换：RGB↔YUV，系数可编程
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Output Buf   │  裁剪、翻转(水平/垂直)、Alpha 插入
│  Control      │  去隔行（Weaving）
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  AXI DMA      │  128-bit AXI 总线写 DDR
│  (Y/U/V 分离) │  支持 Planar/Semi-planar 多平面存储
└──────────────┘
```

### ISI 功能列表

| 功能 | 说明 |
|------|------|
| 缩放 | 硬件降采样，最大 16x 缩小（抽取 ÷8 × 双线性 ÷2） |
| 色彩转换 | RAW→RGB、RGB→YUV、YUV→RGB，3×3 矩阵系数可编程 |
| 裁剪 | 只取感兴趣区域 (ROI) |
| 翻转 | 水平/垂直镜像 |
| Alpha 插入 | 给 RGB 加透明通道，支持 4 个 ROI 独立 Alpha |
| 去隔行 | 隔行→逐行（Weaving 方式） |
| 格式转换 | 输出 RAW8~32、RGB888/565、YUV444/422/420 等 |
| DMA 写入 | Ping-pong 双缓冲，Y/U/V 可分别写不同地址 |
| 流控 | Panic 机制防溢出，背压暂停 |
| Metadata | 可处理 sensor 的 embedded data 并写出 |

### 色彩空间转换公式

RGB → YUV：
```
Y = (A1 × R) + (A2 × G) + (A3 × B) + D1
U = (B1 × R) + (B2 × G) + (B3 × B) + D2
V = (C1 × R) + (C2 × G) + (C3 × B) + D3
```

YUV → RGB：
```
R = (A1 × (Y-D1)) + (A2 × (U-D2)) + (A3 × (V-D3))
G = (B1 × (Y-D1)) + (B2 × (U-D2)) + (B3 × (V-D3))
B = (C1 × (Y-D1)) + (C2 × (U-D2)) + (C3 × (V-D3))
```

系数 A1~D3 全部可编程。

### 为什么需要 ISI 而不是直接 DMA？

CSI-2 控制器的 IPI 输出只是实时像素流（48-bit bus + sync 信号）：
- 没有 DMA 能力，不能直接写内存
- 没有处理能力，不能缩放/转换格式

ISI 就是硬件加速的"搬运工 + 预处理器"。

---

## 11. 与高端 SoC 对比

| | imx93 | imx8MP | imx95 |
|---|---|---|---|
| Data Lanes | 2 | 4 | 4 |
| IPI 数量 | 1 | 4 | 多个 |
| 同时 VC 数 | 1 | 4 | 多个 |
| ISI 通道 | 1 | 8 | 多个 |
| 最大分辨率 | 2K@30fps | 4K | 4K+ |
| GPU | 无 | 有 | 有 |

imx93 定位是低功耗 IoT/边缘 AI 平台，单摄像头 + NPU 推理是典型用法。多摄同时处理需要用更高端的 SoC。

---

## 12. Linux 内核驱动中的对应

内核中 imx93 CSI-2 使用的驱动是 `imx-mipi-csis.c`（基于 Samsung CSIS IP 的驱动）：

```c
#define MIPI_CSIS_MAX_CHANNELS  4   // 协议层最多4个VC

struct mipi_csis_device {
    unsigned int num_channels;      // 通过 DT "fsl,num-channels" 配置
};
```

设备树绑定（`nxp,imx-mipi-csi2.yaml`）：

```yaml
fsl,num-channels:
    description: Number of output channels
    minimum: 1
    maximum: 4
    default: 1
```
