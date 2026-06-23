---
layout: post
title: "MIPI CSI-2 协议深入理解：以树莓派 5 RP1 CFE 驱动为例"
date: 2026-06-23 15:00:00 +0800
excerpt: "从数据包结构（短包/长包）、VC/DT 路由、D-PHY 物理层到 DMA 传输，结合树莓派 5 RP1 CFE 驱动源码逐层解析 CSI-2 协议的工作原理。"
---

# MIPI CSI-2 协议深入理解：以树莓派 5 RP1 CFE 驱动为例

## 1. MIPI 协议族概览

MIPI（Mobile Industry Processor Interface）不是单一协议，而是一族面向移动/嵌入式设备的接口标准：

| 协议 | 用途 |
|------|------|
| MIPI CSI-2 | 摄像头 → SoC 的图像传输 |
| MIPI DSI | SoC → 显示屏的图像传输 |
| MIPI D-PHY | 物理层（CSI 和 DSI 共用） |
| MIPI C-PHY | 更高效的物理层 |

**CSI-2 和 D-PHY 的关系**：CSI-2 是协议层（管数据包格式），D-PHY 是物理层（管电信号怎么发）。类比网络：D-PHY ≈ 网线，CSI-2 ≈ HTTP。

```
┌──────────────┐
│   MIPI CSI-2 │  协议层：定义数据包格式、帧结构、像素编码
├──────────────┤
│  MIPI D-PHY  │  物理层：定义电压、时序、差分信号传输
└──────────────┘
```

D-PHY 不只服务于 CSI，显示接口 DSI 也用 D-PHY。

---

## 2. CSI-2 数据包结构：短包与长包

CSI-2 协议中所有数据以**包（Packet）**为单位传输，分为两种：

### 2.1 短包（Short Packet）

只有一个 32-bit 包头，**没有 payload**：

```
┌─────────────────────────────────────────┐
│  VC(2b) │ DT(6b) │ Data(16b) │ ECC(8b) │
│  虚拟通道 │ 数据类型 │  帧号等   │  纠错码  │
└─────────────────────────────────────────┘
         总共 4 字节，没有数据体
```

短包的作用是**纯同步/控制信号**：

| 短包类型 | DT 值 | 含义 |
|---------|-------|------|
| FS (Frame Start) | 0x00 | "新帧来了" |
| FE (Frame End) | 0x01 | "这帧完了" |
| LS (Line Start) | 0x02 | "一行开始"（可选） |
| LE (Line End) | 0x03 | "一行结束"（可选） |

**类比**：短包就像书的章节标题——本身不是正文，只标记边界。

### 2.2 长包（Long Packet）

有包头 + 实际数据 + 校验尾：

```
┌──────────┬───────────────────────────────────┬──────┐
│ Header   │           Payload                  │ CRC  │
│ (4字节)   │     （像素数据 或 metadata）        │(2字节)│
└──────────┴───────────────────────────────────┴──────┘

Header 结构：
┌────────┬────────┬──────────────┬─────┐
│ VC(2b) │ DT(6b) │  WC(16b)    │ ECC │
│ 虚拟通道 │ 数据类型│ payload字节数│ 纠错 │
└────────┴────────┴──────────────┴─────┘
```

- **WC（Word Count）**：payload 的字节数
- **Payload**：真正的数据
- **CRC**：校验 payload 完整性

**一个长包通常对应图像的一行**。例如 1920×1080 RAW10：每行 1920 像素 × 10bit ÷ 8 = 2400 字节 payload。

### 2.3 长包不只是像素

长包的内容由 DT（Data Type）决定：

| DT 值 | 长包 payload 内容 |
|--------|------------------|
| 0x2A~0x2D | 图像像素（RAW8/10/12/14） |
| 0x1E~0x1F | 图像像素（YUV422） |
| 0x22~0x24 | 图像像素（RGB） |
| **0x12** | **嵌入式数据（Embedded Data）**：曝光、增益等 |
| 0x10~0x17 | 通用用户自定义数据 |

### 2.4 一帧的完整传输

一帧 1080p RAW10 图像（含 metadata）的传输：

```
[FS 短包]                                              ← 帧开始（4字节）
[长包: DT=0x12, Embedded Data - 曝光/增益等]            ← 前置 metadata
[长包: DT=0x2B, 第1行像素数据 - 2400字节]               ← 像素
[长包: DT=0x2B, 第2行像素数据 - 2400字节]
...
[长包: DT=0x2B, 第1080行像素数据 - 2400字节]
[长包: DT=0x12, Embedded Data - 后置 metadata]          ← 可选
[FE 短包]                                              ← 帧结束（4字节）
```

**关键点**：
- 一帧有多少行 = 图像高度（640×480 就是 480 行，4K 就是 2160 行）
- Metadata 和像素是 **1:1** 关系，每帧附带自己的 metadata（因为每帧曝光参数可能不同）
- 接收端通过 FS/FE 短包知道帧边界

---

## 3. VC 和 DT：CSI-2 的路由机制

### 3.1 Virtual Channel（虚拟通道）

一条物理 CSI-2 链路可以同时传输最多 4 路独立数据（VC 0~3），通过包头的 VC 字段区分。

典型场景：双摄像头共用一条 CSI 总线，VC=0 给主摄，VC=1 给副摄。

### 3.2 Data Type（数据类型）

同一 VC 内还可以有不同类型的数据混传，用 DT 区分。

典型场景：VC=0 上同时传 RAW10 图像（DT=0x2B）和 Embedded Data（DT=0x12）。

### 3.3 接收端的分发

接收端硬件用 **VC + DT** 做过滤，把不同数据路由到不同 DMA 通道。这在 RP1 驱动中的体现：

```c
// csi2.c - csi2_start_channel()
set_field(&ctrl, vc, VC_MASK);   // Channel 只接收指定 VC 的包
set_field(&ctrl, dt, DT_MASK);   // Channel 只接收指定 DT 的包
csi2_reg_write(csi2, CSI2_CH_CTRL(channel), ctrl);
```

---

## 4. 树莓派 5 RP1 CFE 驱动架构

### 4.1 整体硬件结构

```
Camera Sensor
     │
     │  MIPI CSI-2 差分线（data lanes + clock lane）
     ▼
┌──────────────────────────────────────────────────┐
│                   RP1 CFE 硬件                     │
│                                                    │
│  ┌─────────┐    ┌──────────────┐    ┌──────────┐ │
│  │  D-PHY  │───▶│  CSI-2 Host  │───▶│  PiSP FE │ │
│  │ (物理层) │    │ (协议解析+DMA)│    │ (前端ISP) │ │
│  └─────────┘    └──────────────┘    └──────────┘ │
└──────────────────────────────────────────────────┘
```

### 4.2 源码文件对应关系

| 文件 | 硬件模块 | CSI-2 协议层 |
|------|---------|-------------|
| `dphy.c` | D-PHY 控制器 | 物理层：lane 配置、HS 频率 |
| `csi2.c` | CSI-2 Host + DMA | 协议层：包解析、VC/DT 分发、DMA |
| `cfe.c` | 整体管理 | 应用层：V4L2 接口、buffer 管理 |
| `pisp_fe.c` | PiSP Front End | ISP 前端处理 |

---

## 5. 物理层实现：dphy.c

### 5.1 D-PHY 数据结构

```c
struct dphy_data {
    void __iomem *base;
    u32 dphy_rate;       // 每 lane 的数据速率（Mbps）
    u32 max_lanes;       // 硬件最大 lane 数
    u32 active_lanes;    // 当前使用的 lane 数
};
```

CSI-2 物理链路包括：
- **Clock Lane**：1 条，提供时钟参考
- **Data Lane**：1~4 条，并行传数据（lane 越多带宽越大）

D-PHY 有两种电气模式：
- **LP（Low Power）**：低速控制/同步
- **HS（High Speed）**：高速差分信号传像素

### 5.2 启动流程

```c
void dphy_start(struct dphy_data *dphy)
{
    dw_csi2_host_write(dphy, RESETN, 0);                    // 复位
    dw_csi2_host_write(dphy, N_LANES, (dphy->active_lanes - 1)); // 配 lane 数
    dphy_init(dphy);                                         // 配 HS 频率
    dw_csi2_host_write(dphy, RESETN, 0xffffffff);            // 释放复位
}
```

### 5.3 HS 频率配置

PHY 必须知道 sensor 的发送速率才能正确采样：

```c
static void dphy_set_hsfreqrange(struct dphy_data *dphy, uint32_t mbps)
{
    // 查表：80~1500 Mbps 对应不同的硬件配置值
    static const u16 hsfreqrange_table[][2] = {
        { 89, 0b000000 }, { 99, 0b010000 }, ...
        { 1500, 0b111100 },
    };
    // 写入 PHY 寄存器
    dphy_transaction(dphy, DPHY_HS_RX_CTRL_LANE0_OFFSET,
                     hsfreqrange_table[i][1] << 1);
}
```

---

## 6. 协议层实现：csi2.c

### 6.1 4 通道 DMA 架构

```c
#define CSI2_NUM_CHANNELS 4
```

RP1 CSI-2 Host 有 4 个独立 DMA 通道，每个可配置接收特定 VC+DT 的数据。树莓派 5 典型配置：

| Channel | 用途 | VC | DT |
|---------|------|----|----|
| 0 | 图像数据 | 0 | RAW10 (0x2B) |
| 1 | 嵌入式 metadata | 0 | Embedded (0x12) |
| 2~3 | 备用 | - | - |

对应代码中的 node 定义：

```c
[CSI2_CH0] = { .name = "csi2_ch0", ... },   // 图像
[CSI2_CH1] = { .name = "embedded", ... },    // metadata
```

### 6.2 通道启动：配置 VC/DT 过滤

```c
void csi2_start_channel(struct csi2_device *csi2, unsigned int channel,
                        enum csi2_mode mode, bool auto_arm,
                        bool pack_bytes, unsigned int width,
                        unsigned int height)
{
    u8 vc, dt;
    csi2_get_vc_dt(csi2, channel, &vc, &dt);  // 从 sensor 获取 VC/DT

    ctrl = DMA_EN | IRQ_EN_FS | IRQ_EN_FE_ACK | PACK_LINE;

    set_field(&ctrl, vc, VC_MASK);   // 只收这个 VC
    set_field(&ctrl, dt, DT_MASK);   // 只收这个 DT
    csi2_reg_write(csi2, CSI2_CH_CTRL(channel), ctrl);

    // 配置帧尺寸
    csi2_reg_write(csi2, CSI2_CH_FRAME_SIZE(channel),
                   (height << 16) | width);
}
```

### 6.3 DMA Buffer 设置

```c
void csi2_set_buffer(struct csi2_device *csi2, unsigned int channel,
                     dma_addr_t dmaaddr, unsigned int stride,
                     unsigned int size)
{
    u64 addr = dmaaddr;
    addr >>= 4;  // 16字节对齐
    csi2_reg_write(csi2, CSI2_CH_LENGTH(channel), size >> 4);
    csi2_reg_write(csi2, CSI2_CH_STRIDE(channel), stride >> 4);
    csi2_reg_write(csi2, CSI2_CH_ADDR1(channel), addr >> 32);
    csi2_reg_write(csi2, CSI2_CH_ADDR0(channel), addr & 0xffffffff);
    // 写 ADDR0 触发双缓冲机制
}
```

用户空间 `qbuf` 提交 buffer → 驱动写地址到寄存器 → 硬件收到匹配数据时自动 DMA 写入。

### 6.4 中断处理：帧同步

```c
void csi2_isr(struct csi2_device *csi2, bool *sof, bool *eof)
{
    status = csi2_reg_read(csi2, CSI2_STATUS);
    csi2_reg_write(csi2, CSI2_STATUS, status);  // 写回清中断

    for (i = 0; i < CSI2_NUM_CHANNELS; i++) {
        sof[i] = !!(status & IRQ_FS(i));       // Frame Start
        eof[i] = !!(status & IRQ_FE_ACK(i));   // Frame End (DMA完成)
    }
}
```

对应协议时序：

```
Sensor:  [FS短包] → [行数据长包×N] → [FE短包]
Host:    SOF中断 →  DMA写入内存   → EOF中断 → 通知用户空间
```

### 6.5 错误处理

```c
#define IRQ_OVERFLOW          BIT(20)  // FIFO 溢出
#define IRQ_DISCARD_OVERFLOW  BIT(21)  // 丢弃：溢出
#define IRQ_DISCARD_LEN_LIMIT BIT(22)  // 丢弃：包长超限
#define IRQ_DISCARD_UNMATCHED BIT(23)  // 丢弃：无通道匹配该 VC+DT
#define IRQ_DISCARD_INACTIVE  BIT(24)  // 丢弃：通道未激活
```

---

## 7. 应用层实现：cfe.c

### 7.1 Media Pipeline 拓扑

```
Sensor ──▶ CSI2 subdev ──┬──▶ /dev/video0 (csi2_ch0 - 图像)
                          ├──▶ /dev/video1 (embedded - metadata)
                          ├──▶ /dev/video2 (csi2_ch2)
                          ├──▶ /dev/video3 (csi2_ch3)
                          │
                          └──▶ PiSP FE ──┬──▶ /dev/video4 (fe_image0)
                                          ├──▶ /dev/video5 (fe_image1)
                                          ├──▶ /dev/video6 (fe_stats)
                                          └──◀ /dev/video7 (fe_config)
```

### 7.2 设备树解析：获取 CSI-2 链路参数

```c
static int of_cfe_connect_subdevs(struct cfe_device *cfe)
{
    struct v4l2_fwnode_endpoint ep = { .bus_type = V4L2_MBUS_CSI2_DPHY };

    v4l2_fwnode_endpoint_parse(of_fwnode_handle(ep_node), &ep);

    cfe->csi2.dphy.max_lanes = ep.bus.mipi_csi2.num_data_lanes;
    cfe->csi2.bus_flags = ep.bus.mipi_csi2.flags;
}
```

设备树中描述了 lane 数量和配置，驱动据此初始化 D-PHY。

### 7.3 数据格式映射

```c
struct cfe_fmt {
    u32 fourcc;    // V4L2 像素格式
    u32 code;      // media bus code
    u8 depth;      // 每像素位数
    u8 csi_dt;     // CSI-2 Data Type 编码
    u32 remap[2];
    u32 flags;
};
```

`csi_dt` 将 V4L2 格式映射回 CSI-2 协议的 DT 值，用于配置硬件过滤器。

---

## 8. 完整数据流：从 Sensor 到用户空间

```
1. Sensor 物理发送：
   LP→HS 切换 → [FS包] → [Embedded长包] → [RAW10行×N] → [FE包] → HS→LP

2. D-PHY (dphy.c)：
   检测 LP→HS → 用配置好的频率采样差分信号 → bit 流交给 CSI-2 Host

3. CSI-2 Host (csi2.c)：
   解析包头 → 提取 VC+DT → 匹配 Channel → DMA 写入对应 buffer
   FS → SOF 中断
   FE → EOF 中断

4. CFE 驱动 (cfe.c)：
   SOF → 标记帧开始，发 V4L2_EVENT_FRAME_SYNC
   EOF → vb2_buffer_done()，切换下一个 buffer

5. 用户空间：
   DQBUF → 拿到一帧完整图像 → 送 ISP 或保存
```

---

## 9. Media Pipeline Pad 连接图

### 9.1 完整拓扑（从左到右）

```
Sensor pad[0] ──▶ CSI2 pad[0] ···内部··· CSI2 pad[4] ──▶ /dev/video0 (csi2_ch0, 图像)
Sensor pad[1] ──▶ CSI2 pad[1] ···内部··· CSI2 pad[5] ──▶ /dev/video1 (embedded, metadata)
                                         CSI2 pad[6] ──▶ /dev/video2 (csi2_ch2)
                                         CSI2 pad[7] ──▶ /dev/video3 (csi2_ch3)

                                         CSI2 pad[4] ──▶ FE pad[0] ──内部──▶ FE pad[2] ──▶ /dev/video4 (fe_image0)
                                                                              FE pad[3] ──▶ /dev/video5 (fe_image1)
                                                                              FE pad[4] ──▶ /dev/video6 (fe_stats)

                                         /dev/video7 (fe_config) ──▶ FE pad[1] (配置输入)
```

### 9.2 各 Entity 的 Pad 说明

| Entity | Pad 数量 | 说明 |
|--------|---------|------|
| Sensor (IMX500) | 2 | pad[0]=图像 SRC, pad[1]=metadata SRC |
| CSI2 subdev | 8 (4+4) | pad[0~3]=SINK（接收）, pad[4~7]=SOURCE（输出） |
| Video node | 1 | capture 节点=SINK，output 节点=SOURCE |
| PiSP FE | 5 | pad[0]=图像输入 SINK, pad[1]=配置输入 SINK, pad[2~4]=输出 SOURCE |

### 9.3 为什么 Metadata 不连接 PiSP FE？

注意 CSI2 pad[5]（metadata）只连接到 `/dev/video1`，**不连接 PiSP FE**。原因：

**PiSP FE 是图像处理引擎（ISP）**，只处理像素数据（去噪、白平衡、色彩校正等）。Metadata 是曝光参数、寄存器值等数值信息，不是像素，不需要也无法做 ISP 处理。

代码中的体现：

```c
// cfe.c - cfe_link_node_pads()
for (i = 0; i < CSI2_NUM_CHANNELS; i++) {
    // 所有通道都连 video node
    media_create_pad_link(&cfe->csi2.sd.entity,
                          node_desc[i].link_pad,
                          &node->video_dev.entity, 0, 0);

    // 只有图像通道才连 FE
    if (node_supports_image(node)) {
        media_create_pad_link(&cfe->csi2.sd.entity,
                              node_desc[i].link_pad,
                              &cfe->fe.sd.entity,
                              FE_STREAM_PAD, 0);
    }
}
```

`CSI2_CH1`（embedded）的 caps 是 `V4L2_CAP_META_CAPTURE`，不含 `V4L2_CAP_VIDEO_CAPTURE`，所以 `node_supports_image()` 为 false，不创建到 FE 的 link。

**数据流分工**：

```
像素数据：  CSI2 pad[4] ──▶ FE ──▶ ISP处理 ──▶ /dev/video4（处理后的图像）
Metadata： CSI2 pad[5] ──▶ /dev/video1 ──▶ 用户空间直接读取（无需处理）
```

Metadata 由用户空间（如 libcamera）直接读取，用来决定下一帧的曝光/增益控制策略。

---

## 10. 总结

| 概念 | 一句话解释 |
|------|-----------|
| D-PHY | 管电信号怎么在差分线上跑 |
| CSI-2 | 管数据怎么打包、怎么标记帧边界 |
| 短包 | 4 字节同步信号（FS/FE），没有数据体 |
| 长包 | 有数据体的包（像素或 metadata），由 DT 区分内容 |
| VC | 虚拟通道，一条线复用多路 |
| DT | 数据类型，区分像素/metadata/格式 |
| Channel | 接收端的 DMA 通道，按 VC+DT 过滤接收 |

CSI-2 协议的本质：**用少量差分线高速传输打了标签（VC+DT）的数据包，接收端按标签路由分发到不同 DMA 通道写入内存。**

---

*发布于 {{ page.date | date: "%Y年%m月%d日" }}*
