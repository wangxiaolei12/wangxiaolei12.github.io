---
layout: post
title: "Linux 中断子系统(1): 核心数据结构 — irq_desc、irq_domain、irq_chip、irqaction"
date: 2026-06-13 08:30:00 +0800
excerpt: "用实际例子讲清楚 Linux 中断子系统四大核心结构的关系：irq_domain 是电话簿、irq_chip 是遥控器、irq_desc 是档案、irqaction 是该做什么。以 GICv3 + 网卡为例。"
---

# Linux 中断子系统(1): 核心数据结构

---

## 一、先搞清楚要解决什么问题

一个 SoC 上有很多中断控制器，每个控制器自己编号：

```
GPIO 控制器 A:  hwirq=5 (第5个引脚)
GPIO 控制器 B:  hwirq=5 (也是第5个引脚)  ← 和上面重复！
GIC:            hwirq=72 (SPI 72)
GIC:            hwirq=5  (SGI 5)         ← 和 GPIO 也重复！
```

内核需要一个**全局唯一的编号 (virq)**，驱动用它 `request_irq()`，`/proc/interrupts` 显示它：

```
GPIO-A hwirq=5   →  virq=120
GPIO-B hwirq=5   →  virq=145   ← 同样 hwirq=5 但不同 virq
GIC    hwirq=72  →  virq=167
GIC    hwirq=5   →  virq=5
```

---

## 二、用一个真实例子讲清四个结构的关系

**场景：网卡中断连到 GIC 的 SPI 72**

```
网卡 ───IRQ线───→ GIC (INTID 72) ───→ CPU
```

### 四个角色，各管什么

| 结构 | 角色 | 比喻 |
|------|------|------|
| `irq_domain` | 管"硬件号→软件号"的映射 | **电话簿**：查名字找号码 |
| `irq_chip` | 管"怎么操作硬件" | **遥控器**：mask/unmask/eoi 按钮 |
| `irq_desc` | 一个中断的全部信息 | **档案**：谁的中断、怎么处理、谁来处理 |
| `irqaction` | 驱动注册的处理函数 | **执行人**：中断来了该做什么 |

### 谁创建谁？按时间顺序

```
═══════════════════════════════════════════════════════════
 第一步：GIC 驱动 probe (系统启动早期)
═══════════════════════════════════════════════════════════

创建 irq_chip:
  "我是 GIC，要 mask 中断写 GICD_ICENABLER 寄存器，
   要 eoi 写 ICC_EOIR1_EL1 寄存器..."

创建 irq_domain:
  "我负责 hwirq 0~1019 的映射，
   谁问我 hwirq 对应什么 virq，我给他分配一个"

═══════════════════════════════════════════════════════════
 第二步：网卡驱动 probe (解析 DT: interrupts = <SPI 72 LEVEL>)
═══════════════════════════════════════════════════════════

platform_get_irq(pdev, 0):
  → 问 GIC 的 irq_domain："hwirq=72 对应什么 virq？"
  → domain 分配 virq=167
  → 创建 irq_desc[167]，填好 irq_data:
        .hwirq = 72
        .chip = &gic_chip      (绑定遥控器)
        .domain = &gic_domain  (记住电话簿)
  → 返回 virq=167 给网卡驱动

═══════════════════════════════════════════════════════════
 第三步：网卡驱动 request_irq(167, e1000_intr, ...)
═══════════════════════════════════════════════════════════

  → 创建 irqaction { handler=e1000_intr, name="eth0" }
  → 挂到 irq_desc[167].action 链表
  → 调 gic_chip.irq_unmask()：使能 GIC 的 hwirq 72
  → 中断就绑了！
```

### 中断来了怎么查？一路追踪

```
网卡产生中断 → GIC 给 CPU：hwirq=72
    │
    │ "hwirq=72 对应哪个 irq_desc？问电话簿"
    ▼
irq_domain.revmap[72] ──→ 找到 irq_desc[167]
    │
    │ "找到档案了，怎么处理？看档案上写的流程"
    ▼
irq_desc[167].handle_irq ──→ handle_fasteoi_irq()
    │
    │ "要操作硬件（eoi），用什么遥控器？"
    ▼
irq_desc[167].irq_data.chip ──→ gic_chip.irq_eoi()
    │
    │ "要通知驱动，谁是执行人？"
    ▼
irq_desc[167].action ──→ e1000_intr(167, dev)
```

### 一张图：谁指向谁

```
         irq_domain (GIC)
         ┌───────────────────────┐
         │ name = "GICv3"        │
         │ revmap[72] ─────────────────┐
         │ ops = gic_domain_ops  │     │
         └───────────────────────┘     │
                                       │ 指向
              irq_chip (GIC)           │
              ┌──────────────────┐     │
              │ name = "GICv3"   │     │
              │ irq_mask = ...   │     │
              │ irq_unmask = ... │     │
              │ irq_eoi = ...    │     │
              └──────────────────┘     │
                  ▲   ▲                │
                  │   │                ▼
┌─────────────────┼───┼───── irq_desc[167] ──────────────────────┐
│                 │   │                                           │
│  irq_data:     │   │                                           │
│    .irq = 167 (virq)                                           │
│    .hwirq = 72                                                 │
│    .chip ───────┘   │                                           │
│    .domain ─────────│──→ gic_domain                            │
│                     │                                           │
│  handle_irq ──→ handle_fasteoi_irq                             │
│                                                                 │
│  action ──→ irqaction ──→ irqaction ──→ NULL                   │
│              │              │                                   │
│              │ handler=     │ handler=                          │
│              │ e1000_intr   │ usb_irq   (共享中断可多个)        │
│              │ name="eth0"  │ name="usb"                       │
│              │ dev_id=net   │ dev_id=hcd                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、struct irq_desc — 中断的"档案"

```c
struct irq_desc {
    struct irq_data      irq_data;       // ★ 粘合剂：连接 chip + domain + hwirq
    irq_flow_handler_t   handle_irq;     // ★ 流控函数：这类中断怎么处理
    struct irqaction     *action;        // ★ 驱动 handler 链表
    unsigned int         depth;          // disable 嵌套计数
    raw_spinlock_t       lock;           // 保护
    const char           *name;          // /proc/interrupts 中显示
    struct irqstat __percpu *kstat_irqs; // 统计
};
```

存储方式：
```c
#ifdef CONFIG_SPARSE_IRQ   // 现代内核默认
  // 动态分配，按需创建（platform_get_irq 时）
  struct irq_desc *irq_to_desc(unsigned int irq); // radix tree 查找
#else
  // 静态数组，编译时固定
  struct irq_desc irq_desc[NR_IRQS];
#endif
```

---

## 四、struct irq_data — 粘合剂

住在 `irq_desc` 里面，把所有东西连在一起：

```c
struct irq_data {
    unsigned int         irq;          // virq (Linux 全局唯一中断号)
    irq_hw_number_t      hwirq;        // 硬件中断号 (控制器本地的)
    struct irq_chip      *chip;        // → 遥控器 (操作硬件的方法)
    struct irq_domain    *domain;      // → 电话簿 (管映射的)
    void                 *chip_data;   // 控制器私有数据
    struct irq_data      *parent_data; // 级联：上级控制器的 irq_data
};
```

**为什么不直接把这些字段放 irq_desc 里？**
因为层次化中断（GPIO→GIC）每一级都需要自己的 chip/hwirq，`irq_data` 通过 `parent_data` 链起来：

```
设备 → GPIO 控制器 (pin 5) → GIC (SPI 72) → CPU

irq_desc[167]:
  irq_data (GPIO 级):
    hwirq = 5, chip = gpio_chip, domain = gpio_domain
    └── parent_data (GIC 级):
          hwirq = 72, chip = gic_chip, domain = gic_domain
```

---

## 五、struct irq_chip — 遥控器

每个中断控制器驱动提供一组操作硬件的方法：

```c
struct irq_chip {
    const char *name;                    // "GICv3", "gpio-mxc"

    // ★ 核心操作（每个都是写寄存器）
    void (*irq_mask)(struct irq_data *);    // 屏蔽：不让这个中断到 CPU
    void (*irq_unmask)(struct irq_data *);  // 解除屏蔽：允许到 CPU
    void (*irq_ack)(struct irq_data *);     // 应答：告诉控制器"我收到了"
    void (*irq_eoi)(struct irq_data *);     // End of Interrupt："我处理完了"

    // 配置
    int (*irq_set_type)(struct irq_data *, unsigned int type);
        // 设置触发方式：上升沿/下降沿/高电平/低电平
    int (*irq_set_affinity)(struct irq_data *, const struct cpumask *, bool);
        // 设置哪个 CPU 响应这个中断
    int (*irq_set_wake)(struct irq_data *, unsigned int on);
        // 设为唤醒源（suspend 时能唤醒系统）
};
```

**GICv3 的实现：**
```c
static struct irq_chip gic_chip = {
    .name           = "GICv3",
    .irq_mask       = gic_mask_irq,      // 写 GICD_ICENABLER[n]
    .irq_unmask     = gic_unmask_irq,    // 写 GICD_ISENABLER[n]
    .irq_eoi        = gic_eoi_irq,       // 写 ICC_EOIR1_EL1
    .irq_set_type   = gic_set_type,      // 写 GICD_ICFGR[n]
    .irq_set_affinity = gic_set_affinity, // 写 GICD_IROUTER[n]
};
```

---

## 六、struct irq_domain — 电话簿

管理 "hwirq ↔ virq" 映射，每个中断控制器有自己的 domain：

```c
struct irq_domain {
    const char              *name;       // "GICv3"
    const struct irq_domain_ops *ops;    // 映射操作
    void                    *host_data;  // 控制器私有数据 (如 gic_data)
    struct irq_domain       *parent;     // 上级 domain (层次化)

    // ★ 反向映射表：给一个 hwirq，快速找到对应的 irq_data
    irq_hw_number_t         hwirq_max;
    unsigned int            revmap_size;
    struct irq_data __rcu   *revmap[];   // 线性数组: revmap[hwirq] → irq_data
};
```

### irq_domain_ops — domain 怎么工作

```c
struct irq_domain_ops {
    // 从设备树解析出 hwirq 和触发类型
    int (*xlate)(struct irq_domain *d, struct device_node *node,
                 const u32 *intspec, unsigned int intsize,
                 unsigned long *out_hwirq, unsigned int *out_type);
    // 举例: interrupts = <GIC_SPI 72 IRQ_TYPE_LEVEL_HIGH>
    //       → out_hwirq=72, out_type=LEVEL_HIGH

    // 建立映射：给 virq 关联 chip 和 handler
    int (*map)(struct irq_domain *d, unsigned int virq, irq_hw_number_t hw);

    // 层次化 domain 用的：分配 + 向上级 domain 传播
    int (*alloc)(struct irq_domain *d, unsigned int virq,
                 unsigned int nr_irqs, void *arg);
};
```

---

## 七、struct irqaction — 执行人

驱动调 `request_irq()` 时创建，挂在 `irq_desc->action` 链表上：

```c
struct irqaction {
    irq_handler_t    handler;      // ★ 硬中断 handler (top half, 不可睡眠)
    irq_handler_t    thread_fn;    // ★ threaded handler (可睡眠)
    void             *dev_id;      // 设备标识 (共享中断时区分是谁的)
    struct irqaction *next;        // 链表：共享中断多个 handler
    unsigned int     irq;          // virq
    unsigned int     flags;        // IRQF_SHARED, IRQF_ONESHOT...
    const char       *name;        // /proc/interrupts 中显示的名字
    struct task_struct *thread;    // threaded handler 的内核线程
};
```

### 共享中断（多个设备共用一条中断线）

```
irq_desc[167].action:
  ┌──────────────┐     ┌──────────────┐
  │ irqaction    │────→│ irqaction    │────→ NULL
  │ handler=     │     │ handler=     │
  │  e1000_intr  │     │  usb_hcd_irq │
  │ name="eth0"  │     │ name="usb"   │
  │ dev_id=net   │     │ dev_id=hcd   │
  └──────────────┘     └──────────────┘

中断来了 → 逐个调用：
  ret = e1000_intr(167, net);   // "是我的" → IRQ_HANDLED
  ret = usb_hcd_irq(167, hcd);  // "不是我的" → IRQ_NONE
```

---

## 八、流控 handler — handle_irq

`irq_desc->handle_irq` 定义了"这类中断的处理套路"：

| handler | 适用场景 | 流程 |
|---------|---------|------|
| `handle_fasteoi_irq` | GIC 等现代控制器 | 调 action → eoi |
| `handle_level_irq` | 电平触发 | mask → 调 action → unmask |
| `handle_edge_irq` | 边沿触发 | ack → 调 action → (可能重触发) |
| `handle_percpu_devid_irq` | per-CPU 中断 (PPI) | ack → 调 action → eoi |

**handle_fasteoi_irq（GIC 最常用）做了什么：**
```
1. 锁 desc->lock
2. 调用所有 action->handler()（驱动处理）
3. chip->irq_eoi()（告诉 GIC "处理完了"）
4. 解锁
```

---

## 九、/proc/interrupts 每一列对应什么

```
           CPU0  CPU1  CPU2  CPU3   控制器   hwirq  触发   名称
 167:      1234     0     0     0   GICv3     72   Level  eth0, usb

对应结构:
  "167"     = irq_desc.irq_data.irq (virq)
  "1234"    = irq_desc.kstat_irqs[cpu0]
  "GICv3"   = irq_desc.irq_data.chip->name
  "72"      = irq_desc.irq_data.hwirq
  "Level"   = 触发类型 (irq_set_type 设置的)
  "eth0,usb"= action->name 链表中所有的 name
```

---

## 十、源文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/irqdesc.h` | struct irq_desc |
| `include/linux/irq.h` | struct irq_data, struct irq_chip |
| `include/linux/irqdomain.h` | struct irq_domain, irq_domain_ops |
| `include/linux/interrupt.h` | struct irqaction, request_irq API |
| `kernel/irq/irqdesc.c` | irq_desc 分配管理 |
| `kernel/irq/irqdomain.c` | domain 创建、映射、revmap |
| `kernel/irq/chip.c` | handle_fasteoi_irq 等流控函数 |
| `kernel/irq/manage.c` | request_irq/free_irq |
| `drivers/irqchip/irq-gic-v3.c` | GICv3 chip + domain 实现 |
