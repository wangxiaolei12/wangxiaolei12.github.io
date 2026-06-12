---
layout: post
title: "Linux 设备驱动模型深度源码分析"
date: 2026-06-09 16:00:00 +0800
excerpt: "结合 Linux mainline 源码全面分析设备驱动模型：从 kobject/sysfs 基础设施、bus/device/driver 三角关系、match/probe 绑定流程、deferred probe、device links、devres 资源管理到电源管理集成。"
---

# Linux 设备驱动模型深度源码分析

源码路径：`drivers/base/`，基于 Linux mainline (v7.1-rc)

---

## 第一部分：基础设施层

### 1.1 kobject — 内核对象基石

Linux 设备模型的一切都建立在 kobject 之上。每个 kobject 对应 sysfs 中的一个目录。

```c
// include/linux/kobject.h
struct kobject {
    const char      *name;       // 对象名称 → sysfs 目录名
    struct list_head entry;      // 挂在 kset 的链表
    struct kobject  *parent;     // 父对象 → sysfs 父目录
    struct kset     *kset;       // 所属集合
    const struct kobj_type *ktype;  // 类型（定义 sysfs 属性和释放函数）
    struct kernfs_node *sd;      // sysfs 目录节点
    struct kref     kref;        // 引用计数
    // 状态位...
};
```

**kobject 与 sysfs 的映射**：

```
内核对象树                              sysfs 文件系统
═══════════                           ═══════════════
kobject("devices")                    /sys/devices/
    └── kobject("platform")               └── platform/
        └── kobject("2000000.i2c")            └── 2000000.i2c/
            ├── attribute: "uevent"                ├── uevent
            ├── attribute: "driver"                ├── driver → ../../bus/i2c/drivers/xxx
            └── kobject("i2c-0")                   └── i2c-0/
```

**引用计数管理**：

```c
kobject_get(kobj);   // kref_get → refcount++
kobject_put(kobj);   // kref_put → refcount-- → 到0时调用 ktype->release()
```

### 1.2 kset — 对象集合与 uevent

```c
struct kset {
    struct list_head list;           // 所有成员 kobject 的链表
    spinlock_t list_lock;
    struct kobject kobj;             // kset 自身也是 kobject
    const struct kset_uevent_ops *uevent_ops;  // 热插拔事件操作
};
```

kset 是 kobject 的容器，关键作用：
- 管理同类对象的集合
- 提供 **uevent** 机制通知用户空间（udev/mdev 据此创建设备节点）

**uevent 流程**：

```
device_add()
    → kobject_uevent(&dev->kobj, KOBJ_ADD)
        → 生成环境变量 (ACTION=add, DEVPATH=..., SUBSYSTEM=...)
        → netlink 广播给用户空间
        → udev 接收 → 创建 /dev/xxx 节点、加载固件等
```

### 1.3 sysfs 目录全景

```
/sys/
├── bus/                    ← 所有总线类型
│   ├── platform/
│   │   ├── devices/        ← 符号链接到 /sys/devices/ 下的设备
│   │   └── drivers/        ← 该总线上注册的驱动
│   │       └── my_driver/
│   ├── i2c/
│   ├── spi/
│   └── pci/
├── class/                  ← 按功能分类（面向用户）
│   ├── input/
│   ├── net/
│   └── video4linux/
├── devices/                ← 实际设备层次树（反映硬件拓扑）
│   └── platform/
│       └── soc/
│           └── 2000000.i2c/
└── firmware/
    └── devicetree/         ← 设备树的 sysfs 表示
```

---

## 第二部分：核心三角关系

### 2.1 总体架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        bus_type                                   │
│                   (如 platform_bus_type)                          │
│                                                                 │
│  ┌───────────────────────┐     ┌───────────────────────────┐   │
│  │    klist_devices       │     │     klist_drivers          │   │
│  │                       │     │                           │   │
│  │  device A ─────────────────────── driver X              │   │
│  │  device B             │     │     driver Y              │   │
│  │  device C ─────────────────────── driver Y              │   │
│  │  device D (unbound)   │     │                           │   │
│  └───────────────────────┘     └───────────────────────────┘   │
│                                                                 │
│  match(): 判断 device 和 driver 是否匹配                          │
│  probe(): 匹配后调用驱动的初始化                                   │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 bus_type — 总线

```c
// include/linux/device/bus.h
struct bus_type {
    const char      *name;          // 总线名称 → /sys/bus/<name>
    const char      *dev_name;      // 设备编号前缀

    // sysfs 属性组
    const struct attribute_group **bus_groups;
    const struct attribute_group **dev_groups;
    const struct attribute_group **drv_groups;

    // 核心回调
    int (*match)(struct device *dev, const struct device_driver *drv);
    int (*uevent)(const struct device *dev, struct kobj_uevent_env *env);
    int (*probe)(struct device *dev);
    void (*remove)(struct device *dev);
    void (*shutdown)(struct device *dev);

    // DMA 配置
    int (*dma_configure)(struct device *dev);
    void (*dma_cleanup)(struct device *dev);

    // 电源管理
    const struct dev_pm_ops *pm;
};
```

**bus_register() 源码关键流程**：

```c
// drivers/base/bus.c
int bus_register(const struct bus_type *bus)
{
    struct subsys_private *priv;
    priv = kzalloc(sizeof(*priv), GFP_KERNEL);
    priv->bus = bus;

    // 创建 /sys/bus/<name>/ 目录
    kobject_set_name(&priv->subsys.kobj, "%s", bus->name);
    priv->subsys.kobj.kset = bus_kset;  // 父 kset = /sys/bus
    kset_register(&priv->subsys);

    // 创建 /sys/bus/<name>/devices/ 和 /sys/bus/<name>/drivers/
    priv->devices_kset = kset_create_and_add("devices", NULL, bus_kobj);
    priv->drivers_kset = kset_create_and_add("drivers", NULL, bus_kobj);

    // 初始化设备和驱动链表
    klist_init(&priv->klist_devices, ...);
    klist_init(&priv->klist_drivers, ...);

    priv->drivers_autoprobe = 1;  // 默认自动 probe
}
```

**注册后的 sysfs 结构**：

```
/sys/bus/platform/
├── devices/           ← 设备符号链接
├── drivers/           ← 驱动子目录
├── drivers_autoprobe  ← 写1自动绑定
├── drivers_probe      ← 写设备名手动触发 probe
└── uevent
```

### 2.3 device — 设备

```c
// include/linux/device.h
struct device {
    struct kobject kobj;             // 内嵌 kobject → sysfs 目录
    struct device       *parent;     // 父设备（硬件拓扑）

    struct device_private *p;        // 私有数据（deferred probe 等）

    const char          *init_name;  // 初始名称
    const struct device_type *type;  // 设备类型

    const struct bus_type *bus;      // 所在总线
    struct device_driver  *driver;   // 绑定的驱动（NULL=未绑定）

    void *platform_data;             // 板级数据
    void *driver_data;               // 驱动私有数据

    struct dev_links_info links;     // device links（依赖关系）
    struct dev_pm_info    power;     // 电源管理状态

    struct device_node  *of_node;    // 设备树节点
    struct fwnode_handle *fwnode;    // 固件节点（统一抽象）

    dev_t               devt;        // 主次设备号
    const struct class  *class;      // 设备类（如 input, net）

    spinlock_t          devres_lock;
    struct list_head    devres_head;  // devres 资源链表

    void (*release)(struct device *dev);  // 释放回调
};
```

**device_add() 核心流程**：

```c
// drivers/base/core.c
int device_add(struct device *dev)
{
    // 1. 设置设备名称
    if (dev->init_name) {
        dev_set_name(dev, "%s", dev->init_name);
        dev->init_name = NULL;
    }

    // 2. 建立 kobject 层次（确定 sysfs 位置）
    parent = get_device(dev->parent);
    kobj = get_device_parent(dev, parent);
    dev->kobj.parent = kobj;
    kobject_add(&dev->kobj, dev->kobj.parent, NULL);

    // 3. 创建 sysfs 属性文件
    device_create_file(dev, &dev_attr_uevent);
    device_add_class_symlinks(dev);
    device_add_attrs(dev);

    // 4. 加入总线的设备列表
    bus_add_device(dev);

    // 5. 加入电源管理
    device_pm_add(dev);

    // 6. 创建 devtmpfs 节点（/dev/xxx）
    if (MAJOR(dev->devt))
        devtmpfs_create_node(dev);

    // 7. 通知用户空间
    bus_notify(dev, BUS_NOTIFY_ADD_DEVICE);
    kobject_uevent(&dev->kobj, KOBJ_ADD);

    // 8. 创建 device links
    device_links_supplier_sync_state_pause();
    fw_devlink_link_device(dev);

    // 9. 触发 probe！
    bus_probe_device(dev);
}
```

### 2.4 device_driver — 驱动

```c
// include/linux/device/driver.h
struct device_driver {
    const char      *name;             // 驱动名称
    const struct bus_type *bus;         // 所属总线

    struct module   *owner;            // 所属模块
    const char      *mod_name;

    bool suppress_bind_attrs;          // 禁用 sysfs bind/unbind
    enum probe_type probe_type;        // PROBE_DEFAULT_STRATEGY / PREFER_ASYNCHRONOUS

    const struct of_device_id   *of_match_table;   // 设备树匹配表
    const struct acpi_device_id *acpi_match_table; // ACPI 匹配表

    int  (*probe)(struct device *dev);     // 探测（初始化）
    void (*sync_state)(struct device *dev);
    int  (*remove)(struct device *dev);    // 移除
    void (*shutdown)(struct device *dev);  // 关机

    const struct dev_pm_ops *pm;           // 电源管理操作

    struct driver_private *p;              // 私有（kobject, 设备链表等）
};
```

**driver_register() 流程**：

```c
// drivers/base/driver.c
int driver_register(struct device_driver *drv)
{
    // 1. 把驱动加入总线的 drivers 链表
    bus_add_driver(drv);
        // → 创建 /sys/bus/<bus>/drivers/<name>/ 目录
        // → klist_add_tail(&priv->knode_bus, &bus->klist_drivers)

    // 2. 如果 autoprobe，遍历总线上所有设备尝试匹配
    if (bus->drivers_autoprobe)
        driver_attach(drv);
            // → bus_for_each_dev(drv->bus, NULL, drv, __driver_attach)
            //     对每个设备调用 driver_match_device() + driver_probe_device()
}
```

---

## 第三部分：匹配与绑定 (Match & Probe)

### 3.1 触发 Probe 的两条路径

```
路径 A：设备先注册，驱动后加载
═══════════════════════════════
device_add(dev)
    → bus_probe_device(dev)
        → __device_attach(dev)
            → bus_for_each_drv(dev->bus, ..., __device_attach_driver)
                → driver_match_device(drv, dev)  ← match!
                → driver_probe_device(drv, dev)
                    → really_probe(dev, drv)

路径 B：驱动先注册，设备后出现
═══════════════════════════════
driver_register(drv)
    → driver_attach(drv)
        → bus_for_each_dev(drv->bus, ..., __driver_attach)
            → driver_match_device(drv, dev)  ← match!
            → driver_probe_device(drv, dev)
                → really_probe(dev, drv)
```

### 3.2 platform_match() — 4 级匹配优先级

```c
// drivers/base/platform.c
static int platform_match(struct device *dev, const struct device_driver *drv)
{
    struct platform_device *pdev = to_platform_device(dev);
    struct platform_driver *pdrv = to_platform_driver(drv);

    // 优先级 1：driver_override（用户通过 sysfs 强制指定）
    ret = device_match_driver_override(dev, drv);
    if (ret >= 0) return ret;

    // 优先级 2：设备树 compatible 匹配（最常用！）
    if (of_driver_match_device(dev, drv))
        return 1;

    // 优先级 3：ACPI 匹配
    if (acpi_driver_match_device(dev, drv))
        return 1;

    // 优先级 4：id_table 名称匹配
    if (pdrv->id_table)
        return platform_match_id(pdrv->id_table, pdev) != NULL;

    // 优先级 5：设备名 == 驱动名
    return (strcmp(pdev->name, drv->name) == 0);
}
```

**设备树匹配示例**：

```c
// 驱动的 of_match_table
static const struct of_device_id imx_i2c_dt_ids[] = {
    { .compatible = "fsl,imx21-i2c", .data = &imx21_i2c_hwdata, },
    { .compatible = "fsl,imx93-lpi2c", .data = &imx93_lpi2c_hwdata, },
    { }
};
MODULE_DEVICE_TABLE(of, imx_i2c_dt_ids);

// 设备树节点
i2c@44340000 {
    compatible = "fsl,imx93-lpi2c";  ← 和驱动表匹配！
    reg = <0x44340000 0x10000>;
    ...
};
```

### 3.3 really_probe() — 绑定核心

```c
// drivers/base/dd.c
static int really_probe(struct device *dev, const struct device_driver *drv)
{
    // 1. 检查 device links（供应商是否就绪）
    link_ret = device_links_check_suppliers(dev);
    if (link_ret == -EPROBE_DEFER)
        return link_ret;

    // 2. 设置驱动
    device_set_driver(dev, drv);  // dev->driver = drv

    // 3. 绑定 pinctrl
    pinctrl_bind_pins(dev);

    // 4. 配置 DMA
    if (dev->bus->dma_configure)
        dev->bus->dma_configure(dev);

    // 5. 添加 sysfs driver 链接
    driver_sysfs_add(dev);

    // 6. 激活 PM domain
    if (dev->pm_domain && dev->pm_domain->activate)
        dev->pm_domain->activate(dev);

    // 7. 调用 probe！！！
    ret = call_driver_probe(dev, drv);
    //   → if (dev->bus->probe) dev->bus->probe(dev);
    //     else if (drv->probe) drv->probe(dev);

    // 8. 成功后添加驱动的 dev_groups
    device_add_groups(dev, drv->dev_groups);

    // 9. 标记绑定完成
    driver_bound(dev);
}
```

**really_probe 完整时序图**：

```
really_probe(dev, drv)
    │
    ├─ device_links_check_suppliers() ← 依赖检查
    │      └─ 供应商未就绪？→ return -EPROBE_DEFER
    │
    ├─ device_set_driver(dev, drv)    ← dev->driver = drv
    │
    ├─ pinctrl_bind_pins(dev)         ← 引脚复用配置
    │
    ├─ bus->dma_configure(dev)        ← DMA/IOMMU 配置
    │
    ├─ driver_sysfs_add(dev)          ← 创建 sysfs 链接
    │      /sys/bus/xxx/drivers/my_drv/my_dev → /sys/devices/.../my_dev
    │      /sys/devices/.../my_dev/driver → /sys/bus/xxx/drivers/my_drv
    │
    ├─ pm_domain->activate(dev)       ← 电源域激活
    │
    ├─ call_driver_probe(dev, drv)    ← 调用驱动 probe()！
    │      │
    │      ├─ bus->probe(dev)  (如果总线定义了 probe)
    │      └─ drv->probe(dev)  (否则用驱动自己的 probe)
    │              │
    │              ├─ 成功 (0)      → 继续
    │              ├─ -EPROBE_DEFER → 加入延迟列表
    │              └─ 其他错误       → 清理回退
    │
    ├─ device_add_groups()            ← 创建驱动的 sysfs 属性
    │
    └─ driver_bound(dev)              ← 绑定完成
           ├─ klist_add_tail (加入驱动的设备列表)
           ├─ device_links_driver_bound (通知 consumers)
           └─ bus_notify(BUS_NOTIFY_BOUND_DRIVER)
```

### 3.4 Deferred Probe — 延迟探测

当驱动的 probe() 返回 `-EPROBE_DEFER` 时：

```c
// drivers/base/dd.c
// 两个链表
static LIST_HEAD(deferred_probe_pending_list);   // 等待重试
static LIST_HEAD(deferred_probe_active_list);    // 即将重试

// probe 失败时
driver_probe_device() {
    ret = __driver_probe_device(drv, dev);
    if (ret == -EPROBE_DEFER) {
        driver_deferred_probe_add(dev);
        // → list_add_tail(&dev->p->deferred_probe, &deferred_probe_pending_list)
    }
}

// 某个设备 probe 成功后，触发重试
driver_bound(dev) {
    // 有新的 supplier 就绪了，把 pending 移到 active
    driver_deferred_probe_trigger();
    // → list_splice_tail_init(&pending_list, &active_list)
    // → queue_work(deferred_probe_work)
}

// worker 重试
deferred_probe_work_func() {
    while (!list_empty(&deferred_probe_active_list)) {
        dev = list_first_entry(&active_list, ...);
        list_del_init(&dev->p->deferred_probe);
        bus_probe_device(dev);  // 重新尝试 probe
    }
}
```

**Deferred Probe 状态机**：

```
设备 probe()
    │
    ├─ 成功(0) → driver_bound()
    │              └─ trigger: pending → active → retry others
    │
    ├─ -EPROBE_DEFER → 加入 pending_list
    │                    等待 supplier probe 成功触发重试
    │
    └─ 其他错误 → 失败，不重试
```

---

## 第四部分：Platform 设备驱动

### 4.1 platform_device

```c
// include/linux/platform_device.h
struct platform_device {
    const char      *name;         // 设备名
    int             id;            // 实例 ID（-1 = 自动分配）
    struct device   dev;           // 内嵌 device
    u32             num_resources; // 资源数量
    struct resource *resource;     // 资源数组（MMIO, IRQ 等）
    const struct platform_device_id *id_entry;
};
```

### 4.2 设备树到 platform_device 的创建

```c
// drivers/of/platform.c

// 启动时自动调用（arch_initcall_sync）
of_platform_default_populate_init()
    → of_platform_default_populate(NULL, NULL, NULL)
        → of_platform_populate(root, match_table, ...)
            → for_each_child_of_node(root, child)
                → of_platform_bus_create(child, ...)
                    → of_platform_device_create_pdata(node, ...)
                        → of_device_alloc(node, ...)  // 分配 platform_device
                        → of_device_add(dev)          // → device_add()
```

**match_table 决定哪些节点递归展开**：

```c
static const struct of_device_id match_table[] = {
    { .compatible = "simple-bus", },   // 继续展开子节点
    { .compatible = "simple-mfd", },
    { .compatible = "isa", },
    { .compatible = "arm,amba-bus", },
    {}
};
```

**一个设备树节点变成 platform_device 的过程**：

```
设备树:
soc {
    compatible = "simple-bus";  ← 递归展开子节点

    i2c@44340000 {
        compatible = "fsl,imx93-lpi2c";
        reg = <0x44340000 0x10000>;
        interrupts = <GIC_SPI 13 IRQ_TYPE_LEVEL_HIGH>;
        clocks = <&clk IMX93_CLK_LPI2C1_ROOT>;
    };
};

内核创建:
platform_device {
    .name = "44340000.i2c"
    .dev.of_node = <指向设备树节点>
    .resource[0] = { .start=0x44340000, .end=0x4434FFFF, .flags=IORESOURCE_MEM }
    .resource[1] = { .start=45, .flags=IORESOURCE_IRQ }
}
```

### 4.3 platform_driver 注册

```c
// 驱动定义
static struct platform_driver imx_lpi2c_driver = {
    .probe  = imx_lpi2c_probe,
    .remove = imx_lpi2c_remove,
    .driver = {
        .name = "imx-lpi2c",
        .of_match_table = imx_lpi2c_dt_ids,
        .pm = &imx_lpi2c_pm_ops,
    },
};
module_platform_driver(imx_lpi2c_driver);

// module_platform_driver 展开为：
static int __init imx_lpi2c_driver_init(void) {
    return platform_driver_register(&imx_lpi2c_driver);
}
module_init(imx_lpi2c_driver_init);
```

```c
// platform_driver_register 内部
int __platform_driver_register(struct platform_driver *drv, struct module *owner)
{
    drv->driver.bus = &platform_bus_type;  // 绑定到 platform 总线
    drv->driver.owner = owner;

    // 包装 probe/remove
    if (drv->probe)
        drv->driver.probe = platform_drv_probe;  // 包一层，转换参数类型
    if (drv->remove)
        drv->driver.remove = platform_drv_remove;

    return driver_register(&drv->driver);
}
```

---

## 第五部分：Device Links（设备依赖）

### 5.1 问题背景

设备之间有依赖：I2C 控制器依赖时钟、GPIO 控制器依赖 pinctrl。如果 supplier 还没 probe，consumer 的 probe 会失败。

### 5.2 fw_devlink — 自动建立依赖

内核解析设备树中的 phandle 引用，自动建立 device link：

```
// 设备树
i2c@44340000 {
    clocks = <&clk IMX93_CLK_LPI2C1_ROOT>;  ← phandle 引用 clk
    //       ↑ supplier                        consumer = i2c
};

内核自动创建:
device_link: supplier=clk_device, consumer=i2c_device
```

### 5.3 device_link 结构

```c
struct device_link {
    struct device *supplier;     // 供应商
    struct device *consumer;     // 消费者
    struct list_head s_node;     // 挂在 supplier 的链表
    struct list_head c_node;     // 挂在 consumer 的链表
    enum device_link_state status;  // 状态机
    u32 flags;                   // DL_FLAG_*
};
```

**状态机**：

```
                  supplier probe
DORMANT ──────────────────────────→ AVAILABLE
                                        │
                              consumer probe
                                        │
                                        ▼
                                     ACTIVE
                                        │
                              consumer remove
                                        │
                                        ▼
                                   AVAILABLE
```

### 5.4 对 probe 的影响

```c
// drivers/base/dd.c - really_probe()
link_ret = device_links_check_suppliers(dev);
if (link_ret == -EPROBE_DEFER)
    return link_ret;  // supplier 没 probe，consumer 也等着
```

---

## 第六部分：资源管理 (devres)

### 6.1 问题：probe 失败时的清理

传统方式需要大量 goto 清理：

```c
// 传统方式（容易出错）
static int my_probe(struct device *dev) {
    base = ioremap(res->start, size);
    if (!base) return -ENOMEM;

    irq = request_irq(...);
    if (irq < 0) { ret = irq; goto err_unmap; }

    clk = clk_get(dev, NULL);
    if (IS_ERR(clk)) { ret = PTR_ERR(clk); goto err_free_irq; }

    return 0;

err_free_irq:  free_irq(irq, dev);
err_unmap:     iounmap(base);
    return ret;
}
```

### 6.2 devres 机制

```c
// drivers/base/devres.c
struct devres {
    struct devres_node  node;
    dr_release_t        release;    // 释放回调
    u8 __aligned(ARCH_DMA_MINALIGN) data[];  // 用户数据
};
```

**原理**：每次 `devm_*` 分配时，在 `dev->devres_head` 链表上挂一个节点。当驱动 remove 或 probe 失败时，自动遍历链表调用每个节点的 release()。

```c
// devm 方式（自动清理）
static int my_probe(struct device *dev) {
    base = devm_ioremap(dev, res->start, size);
    if (!base) return -ENOMEM;

    ret = devm_request_irq(dev, irq, handler, 0, "my", dev);
    if (ret) return ret;

    clk = devm_clk_get(dev, NULL);
    if (IS_ERR(clk)) return PTR_ERR(clk);

    return 0;
    // 失败时自动按逆序释放所有资源！
}
```

**devres 链表示意**：

```
dev->devres_head
    ↓
[devm_ioremap: base=0xffffff800000] → release = devm_iounmap
    ↓
[devm_request_irq: irq=45]         → release = devm_irq_release
    ↓
[devm_clk_get: clk=lpi2c1_root]    → release = devm_clk_put

probe 失败或 remove 时，从尾到头逆序调用 release()
```

**设备解绑时的清理**：

```c
// drivers/base/dd.c
static void device_unbind_cleanup(struct device *dev)
{
    devres_release_all(dev);  // 释放所有 devres
    dev->driver = NULL;
    // ...
}
```

---

## 第七部分：电源管理集成

### 7.1 dev_pm_ops

```c
struct dev_pm_ops {
    // 系统级（suspend to RAM / hibernate）
    int (*suspend)(struct device *dev);
    int (*resume)(struct device *dev);
    int (*freeze)(struct device *dev);    // hibernate
    int (*thaw)(struct device *dev);

    // Runtime PM（运行时按需开关）
    int (*runtime_suspend)(struct device *dev);
    int (*runtime_resume)(struct device *dev);
    int (*runtime_idle)(struct device *dev);
};
```

### 7.2 Runtime PM 使用

```c
// 驱动使用模式
static int my_probe(struct platform_device *pdev)
{
    pm_runtime_enable(&pdev->dev);
    pm_runtime_set_autosuspend_delay(&pdev->dev, 500);  // 500ms 无操作后自动休眠
    pm_runtime_use_autosuspend(&pdev->dev);
}

// 访问硬件前
static int my_transfer(struct device *dev, ...)
{
    pm_runtime_get_sync(dev);   // 确保设备已唤醒
    // ... 访问寄存器 ...
    pm_runtime_mark_last_busy(dev);
    pm_runtime_put_autosuspend(dev);  // 标记空闲，500ms 后自动休眠
}
```

### 7.3 PM 与 probe 的关系

```c
// really_probe() 中
pm_runtime_get_suppliers(dev);      // 唤醒所有 supplier
if (dev->parent)
    pm_runtime_get_sync(dev->parent);  // 唤醒父设备

ret = call_driver_probe(dev, drv);      // probe

pm_request_idle(dev);
if (dev->parent)
    pm_runtime_put(dev->parent);
pm_runtime_put_suppliers(dev);
```

---

## 第八部分：完整实例——一个 I2C Sensor 驱动的生命周期

### 设备树

```dts
&i2c1 {
    imx678: sensor@1a {
        compatible = "sony,imx678";
        reg = <0x1a>;
        clocks = <&clk IMX93_CLK_CCM_24M>;
        reset-gpios = <&gpio1 5 GPIO_ACTIVE_LOW>;
        vana-supply = <&reg_2v8>;
    };
};
```

### 启动时序

```
1. of_platform_default_populate()
   → 创建 i2c-controller platform_device
   → i2c controller driver probe
     → i2c_add_adapter()
       → of_i2c_register_devices()
         → 遍历 i2c 节点子节点
         → i2c_new_client_device("sensor@1a")
           → device_register() → device_add()

2. device_add() 触发 probe:
   → bus_probe_device()
     → __device_attach()
       → i2c_bus.match(dev, drv)
         → of_driver_match_device()  ← compatible="sony,imx678" 匹配
       → driver_probe_device()
         → really_probe()
           → device_links_check_suppliers()
             → 检查 clk, gpio, regulator 的 supplier
             → 如果 supplier 没 probe → return -EPROBE_DEFER
           → call_driver_probe()
             → imx678_probe(client)

3. imx678_probe():
   → devm_clk_get()          // 获取时钟
   → devm_gpiod_get()        // 获取 reset GPIO
   → devm_regulator_get()    // 获取电源
   → pm_runtime_enable()
   → v4l2_subdev_init()      // 注册 V4L2 子设备
   → 返回 0（成功）

4. driver_bound():
   → 通知 consumers（如果有依赖此 sensor 的设备）
   → 触发 deferred_probe_trigger()
   → uevent → 用户空间感知
```

### 卸载时序

```
rmmod sensor_driver  (或 device_del)
    → device_release_driver()
        → __device_release_driver()
            → imx678_remove(client)
                → v4l2_subdev_cleanup()
                → pm_runtime_disable()
            → devres_release_all(dev)  ← 自动释放 clk/gpio/regulator
            → dev->driver = NULL
            → device_links_driver_cleanup(dev)
```

---

## 总结：核心对象关系全景图

```
                        ┌──────────────┐
                        │   bus_type   │
                        │ (platform,   │
                        │  i2c, spi..) │
                        └──────┬───────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                │                ▼
    ┌─────────────────┐       │      ┌─────────────────┐
    │     device      │       │      │  device_driver  │
    │                 │←──────┼─────→│                 │
    │ .bus            │  match()     │ .bus            │
    │ .driver ────────────────────→  │ .of_match_table │
    │ .of_node        │  probe()     │ .probe()       │
    │ .devres_head    │              │ .remove()      │
    │ .power          │              │ .pm            │
    └────────┬────────┘              └────────────────┘
             │
             ▼
    ┌─────────────────┐
    │    kobject       │ ← sysfs 表示
    │ .parent          │
    │ .kref            │ ← 生命周期
    │ .sd (kernfs)     │ ← /sys/devices/...
    └─────────────────┘
```

| 源码文件 | 作用 |
|----------|------|
| `drivers/base/core.c` | device_add/del, 设备层次管理 |
| `drivers/base/bus.c` | bus_register, 总线管理 |
| `drivers/base/dd.c` | 驱动绑定: match + probe + deferred probe |
| `drivers/base/driver.c` | driver_register/unregister |
| `drivers/base/platform.c` | platform_bus_type, platform_match |
| `drivers/base/devres.c` | devm_* 资源管理 |
| `drivers/base/power/` | 电源管理 (runtime PM, suspend/resume) |
| `drivers/of/platform.c` | 设备树 → platform_device 创建 |
| `lib/kobject.c` | kobject 核心操作 |
