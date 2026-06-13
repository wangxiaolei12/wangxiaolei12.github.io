---
layout: post
title: "Linux 中断子系统(1): 核心数据结构 — irq_desc、irq_domain、irq_chip、irqaction"
date: 2026-06-13 08:30:00 +0800
excerpt: "深入分析 Linux 中断子系统的核心数据结构及其关系：irq_desc 中断描述符、irq_data 中断数据、irq_chip 硬件抽象、irq_domain 中断域（hwirq→virq 映射）、irqaction 处理链。以 GICv3 为例。"
---

# Linux 中断子系统(1): 核心数据结构

---

## 一、整体架构与数据结构关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  驱动 (request_irq)                                                          │
│      │                                                                      │
│      ▼                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  irq_desc [virq]                  每个 Linux 虚拟中断号一个           │   │
│  │  ┌────────────────────────────────────────────────────────────┐      │   │
│  │  │  irq_data                                                  │      │   │
│  │  │  ├── irq (virq: Linux 虚拟中断号)                          │      │   │
│  │  │  ├── hwirq (硬件中断号)                                    │      │   │
│  │  │  ├── chip → struct irq_chip (硬件操作: mask/unmask/ack/eoi)│      │   │
│  │  │  ├── domain → struct irq_domain (hwirq↔virq 映射)         │      │   │
│  │  │  ├── chip_data (控制器私有数据)                            │      │   │
│  │  │  └── parent_data → 上级 irq_data (级联/层次化)             │      │   │
│  │  └────────────────────────────────────────────────────────────┘      │   │
│  │  ├── handle_irq → 流控处理函数 (handle_fasteoi_irq 等)               │   │
│  │  ├── action → struct irqaction 链表 (驱动注册的 handler)             │   │
│  │  ├── depth (嵌套 disable 计数)                                       │   │
│  │  └── lock                                                            │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  irq_domain (GIC domain)                                              │   │
│  │  ├── ops: xlate/map/alloc/translate                                  │   │
│  │  ├── parent → 上级 domain (层次化)                                    │   │
│  │  ├── hwirq_max                                                       │   │
│  │  └── revmap[]: hwirq → irq_data 反向映射表                           │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、struct irq_desc — 中断描述符

**每个 Linux 虚拟中断号 (virq) 对应一个 `irq_desc`**，是中断子系统的核心：

```c
// include/linux/irqdesc.h
struct irq_desc {
    struct irq_common_data  irq_common_data;   // 共享数据 (affinity, node...)
    struct irq_data         irq_data;          // ★ 中断数据 (chip/domain/hwirq)
    struct irqstat __percpu *kstat_irqs;       // per-cpu 统计 (/proc/interrupts)
    irq_flow_handler_t      handle_irq;        // ★ 流控 handler (高层处理)
    struct irqaction        *action;           // ★ 驱动 handler 链表
    unsigned int            status_use_accessors;
    unsigned int            depth;             // disable 嵌套深度
    unsigned int            irq_count;         // 检测 stalled irq
    raw_spinlock_t          lock;              // SMP 保护
    struct cpumask          *percpu_enabled;   // per-cpu 使能掩码
    wait_queue_head_t       wait_for_threads;  // 等待 threaded handler
    struct proc_dir_entry   *dir;              // /proc/irq/N/
    const char              *name;             // 用于 /proc/interrupts
};
```

### 存储方式

```c
// 两种模式:
#ifdef CONFIG_SPARSE_IRQ  // 现代内核默认
  // 动态分配，用 radix tree 管理
  struct irq_desc *irq_to_desc(unsigned int irq);  // 查表
#else
  // 静态数组
  struct irq_desc irq_desc[NR_IRQS];  // 编译时固定大小
#endif
```

---

## 三、struct irq_data — 连接 desc/chip/domain

```c
// include/linux/irq.h
struct irq_data {
    u32                     mask;          // chip 内部用
    unsigned int            irq;           // Linux 虚拟中断号 (virq)
    irq_hw_number_t         hwirq;         // ★ 硬件中断号 (控制器看到的)
    struct irq_common_data  *common;       // 指向 desc->irq_common_data
    struct irq_chip         *chip;         // ★ 硬件操作集
    struct irq_domain       *domain;       // ★ 所属中断域
    struct irq_data         *parent_data;  // 级联: 上级控制器的 irq_data
    void                    *chip_data;    // 控制器私有数据
};
```

**关键理解：**
- `irq` = virq = Linux 软件中断号，驱动用这个调用 `request_irq()`
- `hwirq` = 硬件中断号，GIC 看到的 INTID（如 SPI 32）
- 两者的映射由 `irq_domain` 管理

---

## 四、struct irq_chip — 中断控制器硬件抽象

每个中断控制器驱动实现一组硬件操作：

```c
// include/linux/irq.h
struct irq_chip {
    const char  *name;                          // "GICv3", "GPIO"...

    /* 生命周期 */
    unsigned int (*irq_startup)(struct irq_data *data);
    void         (*irq_shutdown)(struct irq_data *data);
    void         (*irq_enable)(struct irq_data *data);
    void         (*irq_disable)(struct irq_data *data);

    /* ★ 核心操作 */
    void         (*irq_ack)(struct irq_data *data);      // 应答中断
    void         (*irq_mask)(struct irq_data *data);     // 屏蔽中断
    void         (*irq_unmask)(struct irq_data *data);   // 解除屏蔽
    void         (*irq_eoi)(struct irq_data *data);      // End of Interrupt
    void         (*irq_mask_ack)(struct irq_data *data); // mask + ack 原子操作

    /* 配置 */
    int          (*irq_set_affinity)(struct irq_data *data,
                                     const struct cpumask *dest, bool force);
    int          (*irq_set_type)(struct irq_data *data, unsigned int type);
                                     // 设置触发类型: 边沿/电平/高/低
    int          (*irq_set_wake)(struct irq_data *data, unsigned int on);
                                     // 设为唤醒源

    /* MSI */
    void         (*irq_compose_msi_msg)(struct irq_data *data, struct msi_msg *msg);
    void         (*irq_write_msi_msg)(struct irq_data *data, struct msi_msg *msg);

    unsigned long flags;
};
```

### GICv3 的 irq_chip 实现

```c
// drivers/irqchip/irq-gic-v3.c
static struct irq_chip gic_chip = {
    .name                   = "GICv3",
    .irq_mask               = gic_mask_irq,       // 写 GICD_ICENABLER
    .irq_unmask             = gic_unmask_irq,     // 写 GICD_ISENABLER
    .irq_eoi                = gic_eoi_irq,        // 写 ICC_EOIR1_EL1
    .irq_set_type           = gic_set_type,       // 写 GICD_ICFGR
    .irq_set_affinity       = gic_set_affinity,   // 写 GICD_IROUTER
    .irq_set_wake           = gic_set_wake,
    .flags                  = IRQCHIP_SET_TYPE_MASKED |
                              IRQCHIP_SKIP_SET_WAKE |
                              IRQCHIP_MASK_ON_SUSPEND,
};
```

---

## 五、struct irq_domain — 中断域（hwirq ↔ virq 映射）

**解决的问题：** 硬件中断号 (hwirq) 是控制器本地的（GIC 的 SPI 32, GPIO 的 pin 5），但 Linux 需要全局唯一的虚拟中断号 (virq)。`irq_domain` 负责这个映射。

```c
// include/linux/irqdomain.h
struct irq_domain {
    const char                  *name;         // "GICv3", "pinctrl-gpio"
    const struct irq_domain_ops *ops;          // ★ 映射操作
    void                        *host_data;    // 控制器私有数据
    unsigned int                flags;
    struct irq_domain           *parent;       // ★ 层次化: 上级 domain
    struct fwnode_handle        *fwnode;       // DT/ACPI 节点

    /* 反向映射: hwirq → irq_data */
    irq_hw_number_t             hwirq_max;
    unsigned int                revmap_size;
    struct radix_tree_root      revmap_tree;   // 大号 hwirq 用 radix tree
    struct irq_data __rcu       *revmap[];     // 小号 hwirq 用线性数组
};
```

### irq_domain_ops — 映射操作

```c
struct irq_domain_ops {
    /* DT 解析: 从 DT interrupts 属性解析出 hwirq + type */
    int (*xlate)(struct irq_domain *d, struct device_node *node,
                 const u32 *intspec, unsigned int intsize,
                 unsigned long *out_hwirq, unsigned int *out_type);

    /* 建立映射: hwirq → virq (设置 irq_data, 关联 chip) */
    int (*map)(struct irq_domain *d, unsigned int virq, irq_hw_number_t hw);

    /* 层次化域的操作 */
    int (*alloc)(struct irq_domain *d, unsigned int virq,
                 unsigned int nr_irqs, void *arg);
    void (*free)(struct irq_domain *d, unsigned int virq, unsigned int nr_irqs);
    int (*translate)(struct irq_domain *d, struct irq_fwspec *fwspec,
                     unsigned long *out_hwirq, unsigned int *out_type);
};
```

### 层次化 irq_domain (Hierarchy)

现代 SoC 中断经过多级控制器：

```
设备中断 → GPIO 控制器 → GIC → CPU

对应 domain 层次:
┌─────────────────┐
│  GPIO domain    │  hwirq = pin 5
│  gpio_chip      │
└────────┬────────┘
         │ parent
┌────────▼────────┐
│  GIC domain     │  hwirq = SPI 72 (GPIO 连到 GIC 的 SPI 72)
│  gic_chip       │
└────────┬────────┘
         │
     CPU 收到中断

irq_data 链:
  irq_data (GPIO level): irq=167, hwirq=5, chip=gpio_chip, domain=gpio_domain
      └── parent_data (GIC level): hwirq=72, chip=gic_chip, domain=gic_domain
```

---

## 六、struct irqaction — 驱动处理函数

驱动调用 `request_irq()` 注册的处理函数挂在这里：

```c
// include/linux/interrupt.h
struct irqaction {
    irq_handler_t       handler;        // ★ 硬中断 handler (top half)
    void                *dev_id;        // 传给 handler 的参数 (区分共享中断)
    struct irqaction    *next;          // ★ 链表: 共享中断支持多个 handler
    irq_handler_t       thread_fn;      // ★ threaded handler (在内核线程执行)
    struct task_struct  *thread;        // threaded handler 的内核线程
    unsigned int        irq;            // 中断号
    unsigned int        flags;          // IRQF_SHARED, IRQF_ONESHOT...
    const char          *name;          // /proc/interrupts 中的名称
};
```

### 共享中断 (IRQF_SHARED)

```
irq_desc[167].action → irqaction(eth0) → irqaction(usb) → NULL
                       handler: e1000_intr  handler: usb_hcd_irq
                       dev_id: netdev       dev_id: hcd

中断来了 → 逐个调用 handler，由各自判断是不是自己的中断
  if (handler(irq, dev_id) == IRQ_HANDLED) → 是我的
  if (handler(irq, dev_id) == IRQ_NONE)    → 不是我的
```

---

## 七、流控 handler — handle_irq

`irq_desc->handle_irq` 是高层流控函数，根据中断类型（电平/边沿）调用不同策略：

```c
// 常见的流控 handler:
void handle_fasteoi_irq(struct irq_desc *desc);     // ★ GIC 最常用 (ack由硬件做)
void handle_level_irq(struct irq_desc *desc);       // 电平触发
void handle_edge_irq(struct irq_desc *desc);        // 边沿触发
void handle_simple_irq(struct irq_desc *desc);      // 无需硬件操作
void handle_percpu_devid_irq(struct irq_desc *desc); // per-CPU 中断
```

### handle_fasteoi_irq 流程（GIC 使用）

```c
void handle_fasteoi_irq(struct irq_desc *desc)
{
    struct irq_chip *chip = desc->irq_data.chip;

    raw_spin_lock(&desc->lock);

    // 遍历 action 链表，调用每个 handler
    handle_irq_event(desc);
    //   → for each action:
    //       ret = action->handler(irq, action->dev_id);
    //       if (ret == IRQ_WAKE_THREAD)
    //           wake_up_process(action->thread);  // 唤醒 threaded handler

    // 发 EOI 给 GIC
    chip->irq_eoi(&desc->irq_data);

    raw_spin_unlock(&desc->lock);
}
```

---

## 八、数据结构关系全景图

```
/proc/interrupts 中一行:
 167:    1234    0    0    GICv3  72 Level  eth0, usb

对应内核结构:
┌─────────────────────────────────────────────────────────────────┐
│ irq_desc[167]                                                    │
│                                                                  │
│  irq_data:                                                       │
│    irq = 167 (virq)          ←── /proc 中的中断号               │
│    hwirq = 72 (SPI 72)      ←── GIC 看到的硬件号               │
│    chip = &gic_chip          ←── "GICv3"                        │
│    domain = gic_domain       ←── hwirq↔virq 映射              │
│                                                                  │
│  handle_irq = handle_fasteoi_irq  ←── "Level" 触发用 fasteoi    │
│                                                                  │
│  action → irqaction {                                            │
│             handler = e1000_intr    ←── "eth0"                  │
│             name = "eth0"                                        │
│             next → irqaction {                                   │
│                      handler = usb_hcd_irq  ←── "usb"          │
│                      name = "usb"                                │
│                      next = NULL                                 │
│                    }                                              │
│           }                                                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 九、hwirq → virq 映射建立过程

```
设备树:
  ethernet {
      interrupts = <GIC_SPI 72 IRQ_TYPE_LEVEL_HIGH>;
  };

内核启动/设备 probe:
  platform_get_irq(pdev, 0)
      → of_irq_get(node, 0)
          → irq_create_fwspec_mapping(&fwspec)
              │
              ├── irq_domain_translate(gic_domain, fwspec)
              │       → gic_irq_domain_translate()
              │         解析 DT: type=SPI, hwirq=72, trigger=LEVEL_HIGH
              │
              ├── irq_domain_alloc_irqs(gic_domain, 1, ...)
              │       → __irq_domain_alloc_irqs()
              │           ├── irq_domain_alloc_descs()
              │           │     分配 virq=167, 创建 irq_desc[167]
              │           │
              │           └── gic_domain->ops->alloc()
              │                 → gic_irq_domain_alloc()
              │                   ├── irq_data->hwirq = 72
              │                   ├── irq_data->chip = &gic_chip
              │                   └── irq_set_handler(167, handle_fasteoi_irq)
              │
              └── 返回 virq = 167

驱动:
  int irq = platform_get_irq(pdev, 0);  // 得到 167
  request_irq(irq, my_handler, IRQF_SHARED, "eth0", dev);
      → 创建 irqaction，挂到 irq_desc[167]->action 链表
```

---

## 十、关键 API 总结

| API | 作用 |
|-----|------|
| `request_irq(irq, handler, flags, name, dev)` | 注册中断 handler |
| `request_threaded_irq(irq, handler, thread_fn, ...)` | 注册 threaded handler |
| `free_irq(irq, dev_id)` | 注销中断 |
| `irq_domain_create_linear(fwnode, size, ops, data)` | 创建线性映射 domain |
| `irq_domain_create_hierarchy(parent, flags, size, ...)` | 创建层次化 domain |
| `irq_create_fwspec_mapping(fwspec)` | 从 DT/ACPI 建立 hwirq→virq |
| `irq_set_chip_and_handler(virq, chip, handler)` | 设置 chip 和流控函数 |
| `generic_handle_domain_irq(domain, hwirq)` | 中断到来时分发 |

---

## 十一、源文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/irqdesc.h` | struct irq_desc |
| `include/linux/irq.h` | struct irq_data, struct irq_chip |
| `include/linux/irqdomain.h` | struct irq_domain, irq_domain_ops |
| `include/linux/interrupt.h` | struct irqaction, request_irq API |
| `kernel/irq/irqdesc.c` | irq_desc 分配/管理 |
| `kernel/irq/irqdomain.c` | domain 创建/映射/层次化 |
| `kernel/irq/chip.c` | handle_fasteoi_irq, handle_level_irq 等 |
| `kernel/irq/manage.c` | request_irq/free_irq 实现 |
| `kernel/irq/handle.c` | generic_handle_irq, handle_irq_event |
| `drivers/irqchip/irq-gic-v3.c` | GICv3 驱动 (irq_chip + domain) |
