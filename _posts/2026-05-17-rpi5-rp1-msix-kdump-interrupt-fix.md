---
layout: post
title: "树莓派5 RP1 MSI-X 中断机制与 Kdump 中断丢失问题分析"
date: 2026-05-17 17:00:00 +0800
excerpt: "深入分析树莓派5 RP1 芯片的 MSI-X 状态机机制，以及 kdump/kexec 后网口中断丢失的根因与修复方案。"
---

# 树莓派5 RP1 MSI-X 中断机制与 Kdump 中断丢失问题分析

## 一、问题现象

在树莓派5（BCM2712）平台上，执行 kdump/kexec 重启后，macb 以太网控制器无法收到任何数据包，DHCP 请求长时间挂起，网络接口虽然 Link Up 但完全不可用。

通过 `/proc/interrupts` 观察：

```
 95:          0 rp1_irq_chip   6 Level     end0
```

macb 的中断计数为 0——中断从未触发过。

## 二、硬件架构

### 2.1 树莓派5 中断拓扑

树莓派5 的 I/O 外设（以太网、USB、SD 卡等）不直接连接 SoC，而是通过一颗名为 RP1 的 PCIe 外设芯片提供。中断路径如下：

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────┐
│  macb   │────▶│   RP1   │────▶│  MIP0   │────▶│   GIC   │────▶│ CPU │
│(网卡硬件)│level│(MSI-X   │write│(MSI目标 │edge │(中断    │     │     │
│         │trig │ 状态机)  │     │ 外设)   │trig │ 控制器) │     │     │
└─────────┘     └─────────┘     └─────────┘     └─────────┘     └─────┘
```

关键点：
- macb 到 RP1 是**电平触发**（level-triggered）：中断源持续 assert
- RP1 到 GIC 是**边沿触发**（edge-triggered）：MSI-X 是一次性内存写操作

### 2.2 设备树中的中断配置

```dts
pcie2: pcie@1000120000 {
    msi-parent = <&mip0>;  /* MSI 由 MIP0 处理 */
};

mip0: msi-controller@1000130000 {
    compatible = "brcm,bcm2712-mip";
    msi-ranges = <&gicv2 GIC_SPI 128 IRQ_TYPE_EDGE_RISING 64>;
    /* 64 个 MSI slot，映射到 GIC SPI 128~191，边沿触发 */
};
```

### 2.3 RP1 的 MSI-X 状态机

RP1 在标准 PCI MSI-X 之上实现了自己的中断管理层。每个中断源（hwirq）有独立的 MSIX_CFG 寄存器：

```
MSIX_CFG 寄存器位定义：
  bit 0: MSIX_CFG_ENABLE   - 使能该中断源
  bit 2: MSIX_CFG_IACK     - 软件应答（写入触发）
  bit 3: MSIX_CFG_IACK_EN  - 启用应答机制（level-triggered 时设置）
```

**Edge-triggered 模式（IACK_EN=0）：**
```
中断触发 → 发 MSI-X → 完成（不等待，可立刻响应下一次）
```

**Level-triggered 模式（IACK_EN=1）：**
```
中断 assert → 发 MSI-X → 锁定在"等待 IACK"状态
                                    │
                          软件写 MSIX_CFG_IACK
                                    │
                                    ▼
                              回到"空闲"状态
                                    │
                          如果中断源仍 assert
                                    │
                                    ▼
                            再次发 MSI-X → 再次锁定...
```

这个机制将持续的电平信号转换为可控的边沿序列，每次只发一个 MSI-X，等软件确认处理完毕后才发下一个。

## 三、Linux 内核中断子系统

### 3.1 核心数据结构

```c
struct irq_desc {
    struct irq_data     irq_data;       /* 中断数据 */
    irq_flow_handler_t  handle_irq;     /* flow handler */
    struct irqaction    *action;        /* 设备 handler 链表 */
};

struct irq_data {
    unsigned int        irq;            /* Linux virq */
    unsigned long       hwirq;          /* 硬件中断号 */
    struct irq_chip     *chip;          /* 中断控制器操作 */
    struct irq_domain   *domain;        /* 所属中断域 */
    struct irq_data     *parent_data;   /* 层级域中的 parent */
};

struct irq_chip {
    void (*irq_mask)(struct irq_data *);    /* 屏蔽中断 */
    void (*irq_unmask)(struct irq_data *);  /* 取消屏蔽 */
    void (*irq_ack)(struct irq_data *);     /* 应答中断 */
    void (*irq_eoi)(struct irq_data *);     /* 结束中断 */
    int  (*irq_set_type)(struct irq_data *, unsigned int); /* 设置触发类型 */
};
```

### 3.2 IRQ Domain（中断域）

IRQ Domain 负责硬件中断号（hwirq）与 Linux 虚拟中断号（virq）之间的映射。现代 SoC 使用层级域（Hierarchical Domain）：

```
┌────────────────────────────────────────────────────────┐
│              RPi5 中断域层级                             │
│                                                        │
│  RP1 domain (rp1_irq_chip, rp1_domain_ops)             │
│    hwirq: 0~60 (RP1 内部中断源编号)                     │
│    flow handler: handle_level_irq                      │
│    │                                                   │
│    ▼ (通过 chained handler 连接)                       │
│                                                        │
│  PCI MSI-X domain (PCI-MSI chip)                       │
│    hwirq: MSI-X table entry index                      │
│    │                                                   │
│    ▼                                                   │
│                                                        │
│  MIP middle domain (MIP chip)                          │
│    hwirq: bitmap slot index                            │
│    │                                                   │
│    ▼                                                   │
│                                                        │
│  GIC domain (gic_chip)                                 │
│    hwirq: SPI 128+offset                              │
│    flow handler: handle_fasteoi_irq                    │
└────────────────────────────────────────────────────────┘
```

### 3.3 Flow Handler 详解

内核为不同触发类型提供不同的 flow handler：

**handle_level_irq（电平触发）：**
```c
void handle_level_irq(struct irq_desc *desc)
{
    mask_ack_irq(desc);      // 先屏蔽，防止电平持续触发导致重入
    handle_irq_event(desc);  // 调用设备注册的 handler
    cond_unmask_irq(desc);   // 处理完后取消屏蔽
}
```

**handle_fasteoi_irq（GIC 使用）：**
```c
void handle_fasteoi_irq(struct irq_desc *desc)
{
    handle_irq_event(desc);       // 直接处理
    cond_unmask_eoi_irq(desc);    // 发 EOI 通知 GIC 处理完毕
}
```

**Chained handler（级联，RP1 使用）：**
```c
void rp1_chained_handle_irq(struct irq_desc *desc)
{
    chained_irq_enter(chip, desc);          // 通知 parent chip
    virq = irq_find_mapping(domain, hwirq); // 找到子中断的 virq
    generic_handle_irq(virq);               // 分发到子中断的 flow handler
    msix_cfg_set(rp1, hwirq, MSIX_CFG_IACK); // 解锁 RP1 状态机
    chained_irq_exit(chip, desc);           // 通知 parent chip
}
```

Chained handler 不是独立的 flow handler，而是替换 parent IRQ 的 `handle_irq`，用于中断控制器级联场景。

### 3.4 IRQ Domain 回调函数

```c
static const struct irq_domain_ops rp1_domain_ops = {
    .xlate      = rp1_irq_xlate,       /* 设备树解析时调用 */
    .activate   = rp1_irq_activate,    /* request_irq 时调用一次 */
    .deactivate = rp1_irq_deactivate,  /* free_irq 时调用一次 */
};
```

- **xlate**：子设备 probe 时解析设备树 `interrupts` 属性，将 `<6 IRQ_TYPE_LEVEL_HIGH>` 转换为 hwirq=6, type=LEVEL_HIGH
- **activate**：子设备调用 `request_irq()` 时，中断首次被激活，整个生命周期只调用一次
- **deactivate**：子设备调用 `free_irq()` 时，中断被释放

## 四、MSI-X 中断分配与传递

### 4.1 MSI-X Vector 分配流程

```
rp1_probe()
  → pci_alloc_irq_vectors(pdev, 61, 61, PCI_IRQ_MSIX)
    → 为 RP1 的 61 个 MSI-X entry 各分配一个 virq
    → 每个 virq 经过: PCI-MSI domain → MIP domain → GIC domain
    → MIP 从 bitmap 分配 slot (0~63)
    → GIC 配置对应的 SPI (128+slot) 为 edge-triggered
    → PCI 子系统将 msg_addr/msg_data 写入 RP1 的 MSI-X Table
  → irq_set_chained_handler_and_data(pci_irq_vector(pdev, i), ...)
    → 将每个 MSI-X virq 的 handle_irq 替换为 rp1_chained_handle_irq
```

### 4.2 MIP0 的 MSI-X 组合

```c
static void mip_compose_msi_msg(struct irq_data *d, struct msi_msg *msg)
{
    struct mip_priv *mip = irq_data_get_irq_chip_data(d);
    msg->address_hi = upper_32_bits(mip->msg_addr);  // MIP0 寄存器地址高32位
    msg->address_lo = lower_32_bits(mip->msg_addr);  // MIP0 寄存器地址低32位
    msg->data = d->hwirq;                            // slot 编号
}
```

RP1 发 MSI-X 时，将 `msg_data`（slot 编号）写入 `msg_addr`（MIP0 地址 0x1000130000）。MIP0 收到写入后触发对应的 GIC SPI。

### 4.3 正常中断处理完整流程

以 macb 收到网络包为例：

```
 1. macb 硬件产生中断（level assert on RP1 hwirq 6）
 2. RP1 检测到 assert，IACK_EN=1，发 MSI-X 写入 MIP0
 3. MIP0 触发 GIC SPI (128+slot)，edge rising
 4. GIC 记录 pending，发送中断到 CPU
 5. CPU 进入异常向量 → gic_handle_irq()
 6. GIC 读取 IAR 获得 hwirq，映射到 virq=34
 7. 调用 virq 34 的 handle_irq = rp1_chained_handle_irq()
 8.   chained_irq_enter() → GIC EOI
 9.   desc->irq_data.hwirq & 0x3F = 6
10.   irq_find_mapping(rp1->domain, 6) → virq=95
11.   generic_handle_irq(95) → handle_level_irq()
12.     mask_ack_irq() → rp1_mask_irq()
13.     handle_irq_event() → macb_interrupt() 处理收包
14.     cond_unmask_irq() → rp1_unmask_irq()
15.   msix_cfg_set(rp1, 6, MSIX_CFG_IACK) → 解锁状态机
16.   chained_irq_exit()
17. RP1 状态机回到空闲，macb 仍 assert → 再发 MSI-X → 重复 3~16
```

## 五、Kdump 问题根因分析

### 5.1 Crash 时的硬件状态

正常运行时，macb 的 level 中断大部分时间处于以下状态之一：
- RP1 刚发完 MSI-X，等待软件 IACK
- 软件正在处理中断（mask 状态）

当 kernel panic 发生时，如果 RP1 hwirq 6 的状态机处于"等待 IACK"状态（这是大概率事件），crash 导致 IACK 永远不会被发出。

### 5.2 Kdump 内核启动后的时序

```
时间线：
════════════════════════════════════════════════════════════════

[crash 发生]
  RP1 hwirq 6 状态机：锁定在"等待 IACK"
  macb 中断源：持续 assert

════════════════════════════════════════════════════════════════

[kdump 内核启动]

1. PCI 子系统重新枚举 RP1
   → 重写 MSI-X Table（新的 msg_addr/msg_data）
   → 但 RP1 状态机仍卡在"等待 IACK"，不会用新配置发 MSI-X

2. rp1_irq_activate(hwirq=6) 被调用：
   → 设置 MSIX_CFG_ENABLE（使能中断源）
   → 【缺少 IACK】状态机继续卡死

3. macb probe → request_irq(95)
   → 等待中断触发

4. macb 中断源持续 assert
   → 但 RP1 不发新的 MSI-X（状态机卡死）
   → GIC 没有新的 edge 中断
   → chained handler 永远不被调用
   → macb 的 handler 永远不被调用

5. 结果：RX packets = 0，DHCP 超时，网口不可用
```

### 5.3 为什么 USB 中断不受影响

从 kdump log 可以看到 USB（hwirq 31, 36）的 chained handler 正常触发：

```
rp1_chained: hwirq=31 raw=0x1f
rp1_chained: hwirq=36 raw=0x24
```

这是因为 USB 中断是 **edge-triggered**（`IACK_EN=0`），RP1 的状态机不会锁定在"等待 IACK"状态。即使 crash 时有 pending，新内核 enable 后 RP1 可以立刻响应新的 edge。

## 六、修复方案

### 6.1 修复代码

```c
static int rp1_irq_activate(struct irq_domain *d, struct irq_data *irqd,
                            bool reserve)
{
    struct rp1_dev *rp1 = d->host_data;

    msix_cfg_set(rp1, (unsigned int)irqd->hwirq, MSIX_CFG_ENABLE);
    msix_cfg_set(rp1, (unsigned int)irqd->hwirq, MSIX_CFG_IACK);

    return 0;
}
```

### 6.2 修复原理

在 activate 时无条件发送 IACK：
1. 如果状态机卡在"等待 IACK"→ IACK 将其解锁回"空闲"
2. 中断源仍然 assert → RP1 立刻用新配置的 msg_data 发 MSI-X
3. MIP0 → GIC → chained handler → macb handler → 网络恢复

如果是冷启动（状态机本来就在"空闲"）→ 写 IACK 无效果，不影响正常功能。

### 6.3 修复后的时序

```
[kdump 内核启动]

1. PCI 子系统重写 RP1 MSI-X Table（新 msg_data）

2. rp1_irq_activate(hwirq=6)：
   → MSIX_CFG_ENABLE：使能
   → MSIX_CFG_IACK：解锁状态机 → 回到"空闲"

3. macb 中断仍 assert → RP1 立刻发新 MSI-X
   → MIP0 → GIC edge → chained handler 触发
   → generic_handle_irq → macb_interrupt()
   → 正常处理 → IACK → 循环继续

4. DHCP 成功，网络恢复
```

## 七、与 LTS25 内核的对比

LTS25 内核（`drivers/mfd/rp1.c`）通过不同的方式规避了这个问题：

| 方面 | LTS25 | Mainline |
|------|-------|----------|
| RP1 驱动位置 | `drivers/mfd/rp1.c` | `drivers/misc/rp1/rp1_pci.c` |
| MIP chip_flags | 无 `MSI_CHIP_FLAG_SET_ACK` | 有 `MSI_CHIP_FLAG_SET_ACK` |
| activate 中的 IACK | 无 | 修复后有 |
| chained handler IACK | 无条件发送 | 有条件发送 |

LTS25 能工作的原因：crash 后 GIC 中可能残留 edge pending bit，由于 LTS25 的 MIP 没有 `MSI_CHIP_FLAG_SET_ACK`，这个 pending 不会被框架清除，注册 chained handler 后立刻触发 handler，handler 中的无条件 IACK 解锁了状态机。但这依赖于 GIC 残留状态，不是确定性的修复。

Mainline 的正确修复是在 `rp1_irq_activate` 中主动发 IACK，不依赖任何残留状态，确定性地解锁状态机。

## 八、总结

本问题的核心是 RP1 芯片的 level-triggered MSI-X 状态机设计：它需要软件显式应答（IACK）才能发送下一个 MSI-X。当 kernel crash 时 IACK 丢失，状态机永久卡死。修复方法是在中断激活时无条件发送一次 IACK，确保状态机处于干净的初始状态。

这个问题体现了 kexec/kdump 场景下硬件状态残留的典型挑战：新内核必须假设硬件可能处于任何状态，并在初始化时将其恢复到已知的良好状态。
