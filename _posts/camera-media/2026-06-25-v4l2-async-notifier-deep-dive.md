---
layout: post
title: "V4L2 Async Notifier 深度解析 — 源码级剖析 Camera Pipeline 异步组装机制"
date: 2026-06-25 15:00:00 +0800
excerpt: "深入分析 V4L2 async notifier 的实现原理：为什么需要异步机制、全局链表 + 互相查找的设计、match/bound/complete 回调触发时机、fwnode 匹配逻辑、以 IMX500 + RPi5 CFE 为例的完整流程。基于 drivers/media/v4l2-core/v4l2-async.c。"
---

# V4L2 Async Notifier 深度解析

---

## 一、为什么需要 Async Notifier

V4L2 camera pipeline 涉及多个独立驱动（sensor、CSI bridge、ISP），它们各自是独立的内核模块/platform_device/i2c_device，probe 顺序不确定。

```
问题：
  CSI 驱动先 probe → 但 sensor 还没准备好 → 怎么建立连接？
  sensor 先 probe → CSI 还没注册 → 怎么通知 CSI？
```

传统方案是用 `defer probe`（-EPROBE_DEFER），但这只适合简单依赖，对于复杂的多模块 pipeline 不够灵活。

**Async Notifier 的解决方案：让 pipeline 各模块的连接不依赖 probe 顺序。谁先来都行，后来的自动去匹配。**

---

## 二、核心设计：不是"等待"，而是"挂上去就走"

### 2.1 关键事实：没有任何等待机制

| 问题 | 答案 |
|------|------|
| 用了内核线程？ | **没有**。纯同步，在调用者上下文执行 |
| 用了等待队列？ | **没有**。不 sleep，不 wake_up |
| 用了工作队列？ | **没有** |
| 用了定时器？ | **没有** |
| 那"异步"怎么实现的？ | **两个全局链表 + 互斥锁 + 后到者主动查找** |

### 2.2 全局数据结构

```c
// drivers/media/v4l2-core/v4l2-async.c

static LIST_HEAD(subdev_list);      // 所有已注册但还没匹配到的 subdev
static LIST_HEAD(notifier_list);    // 所有已注册的 notifier
static DEFINE_MUTEX(list_lock);     // 保护上面两个链表
```

整个机制就靠这三行。

### 2.3 工作原理

```
            subdev_list                    notifier_list
          (已注册的 subdev)               (已注册的 notifier)
         ┌───────────────┐              ┌───────────────────┐
         │  sd_A (imx500) │              │  notifier_1 (CFE)  │
         │  sd_B (imx219) │              │    waiting: [asc1] │
         └───────────────┘              └───────────────────┘

         谁后注册，谁就主动去对面链表里找匹配。
```

---

## 三、两条路径：谁先 probe 都行

### 3.1 路径 A：Notifier 先注册（CSI 先 probe）

```c
// CSI 驱动 probe 中
v4l2_async_nf_register(notifier)
{
    mutex_lock(&list_lock);

    // 遍历 subdev_list，看有没有已注册的 subdev 能匹配
    v4l2_async_nf_try_all_subdevs(notifier);  // 此时可能没人 → 什么都不做

    // 把自己挂到全局链表上
    list_add(&notifier->notifier_entry, &notifier_list);

    mutex_unlock(&list_lock);
    return 0;  // CSI probe 正常返回！不阻塞！
}
```

CSI 的 probe 正常结束。此时没有 `/dev/videoX`，但系统不报错，只是 camera 功能还不可用。

### 3.2 路径 B：Subdev 后注册（Sensor 后 probe）

```c
// Sensor 驱动 probe 中
__v4l2_async_register_subdev(sd)
{
    mutex_lock(&list_lock);

    // 遍历 notifier_list，看有没有 notifier 在等我
    list_for_each_entry(notifier, &notifier_list, notifier_entry) {
        asc = v4l2_async_find_match(notifier, sd);
        if (asc) {
            // 找到了！在 sensor 的 probe 上下文中执行：
            v4l2_async_match_notify(notifier, sd, asc);   // → bound()
            v4l2_async_nf_try_complete(notifier);          // → complete()
        }
    }

    // 没匹配到 → 挂到 subdev_list 等着
    if (没匹配到)
        list_add(&sd->async_list, &subdev_list);

    mutex_unlock(&list_lock);
    return 0;  // sensor probe 也正常返回
}
```

**如果 sensor 永远不加载？** 那 notifier 就永远挂在 `notifier_list` 上，complete 永远不被调用，`/dev/videoX` 永远不创建。系统不受影响。

### 3.3 时序图

```
CSI probe (先)                     Sensor probe (后)
    │                                    │
    │ nf_register()                      │
    │   lock                             │
    │   遍历 subdev_list → 没人          │
    │   加入 notifier_list               │
    │   unlock                           │
    │   probe 返回 ✓                     │
    │                                    │
    │   (系统正常运行，无camera)          │
    │                                    │
    │                                    │ register_subdev()
    │                                    │   lock
    │                                    │   遍历 notifier_list
    │                                    │     → 找到匹配！
    │                                    │   match_notify():
    │  ←── bound() ─────────────────────│     注册 subdev + 调 bound
    │  ←── complete() ──────────────────│     try_complete → 调 complete
    │                                    │   unlock
    │  在 complete 中：                   │   probe 返回 ✓
    │    创建 /dev/videoX                │
    │    创建 media links                │
    ▼                                    ▼
```

反过来（sensor 先 probe）也完全一样，只是角色互换。

---

## 四、匹配逻辑：v4l2_async_find_match()

```c
static struct v4l2_async_connection *
v4l2_async_find_match(struct v4l2_async_notifier *notifier,
                      struct v4l2_subdev *sd)
{
    struct v4l2_async_connection *asc;

    // 遍历 notifier 的 waiting_list
    list_for_each_entry(asc, &notifier->waiting_list, asc_entry) {
        switch (asc->match.type) {
        case V4L2_ASYNC_MATCH_TYPE_I2C:
            match = match_i2c;    break;
        case V4L2_ASYNC_MATCH_TYPE_FWNODE:
            match = match_fwnode; break;
        }

        if (match(notifier, sd, &asc->match))
            return asc;  // 匹配成功
    }
    return NULL;
}
```

### 4.1 fwnode 匹配（最常用）

```c
static bool match_fwnode(notifier, sd, match)
{
    // 方式1：subdev 注册了 endpoint list → 逐个比较 endpoint fwnode 指针
    if (!list_empty(&sd->async_subdev_endpoint_list)) {
        list_for_each_entry(ase, &sd->async_subdev_endpoint_list, ...) {
            if (ase->endpoint == match->fwnode)
                return true;
        }
        return false;
    }

    // 方式2：比较 sd->fwnode 和 match->fwnode 的设备节点
    return match_fwnode_one(notifier, sd, sd->fwnode, match);
}
```

本质：**比较设备树 fwnode 指针是否对应同一条 endpoint 连接。**

### 4.2 I2C 匹配

```c
static bool match_i2c(notifier, sd, match)
{
    // 比较 I2C adapter ID + 从机地址
    return match->i2c.adapter_id == client->adapter->nr &&
           match->i2c.address == client->addr;
}
```

---

## 五、匹配成功后：v4l2_async_match_notify()

```c
static int v4l2_async_match_notify(notifier, v4l2_dev, sd, asc)
{
    // ① 把 subdev 注册到 v4l2_device
    __v4l2_device_register_subdev(v4l2_dev, sd, sd->owner);

    // ② 调用 bound 回调
    v4l2_async_nf_call_bound(notifier, sd, asc);

    // ③ 为 lens/flash 创建 ancillary link
    v4l2_async_create_ancillary_links(notifier, sd);

    // ④ 记录匹配结果
    asc->sd = sd;

    // ⑤ 从 waiting_list 移到 done_list
    list_move(&asc->asc_entry, &notifier->done_list);
}
```

---

## 六、Complete 判定：v4l2_async_nf_try_complete()

```c
static int v4l2_async_nf_try_complete(notifier)
{
    // waiting_list 还有人没匹配？→ 不 complete
    if (!list_empty(&notifier->waiting_list))
        return 0;

    // 找到根 notifier（可能有 parent 链）
    while (notifier->parent)
        notifier = notifier->parent;

    // 检查整棵树：所有子 notifier 也必须完成
    if (!v4l2_async_nf_can_complete(notifier))
        return 0;

    // 全部就绪 → 调用 complete
    return v4l2_async_nf_call_complete(notifier);
}
```

递归检查：

```c
static bool v4l2_async_nf_can_complete(notifier)
{
    if (!list_empty(&notifier->waiting_list))
        return false;

    // 每个已 bound 的 subdev 如果自己也有子 notifier → 子 notifier 也必须完成
    list_for_each_entry(asc, &notifier->done_list, ...) {
        subdev_notifier = v4l2_async_find_subdev_notifier(asc->sd);
        if (subdev_notifier && !v4l2_async_nf_can_complete(subdev_notifier))
            return false;
    }
    return true;
}
```

---

## 七、子 Notifier（多级 pipeline）

复杂 pipeline 中，subdev 自己也可以注册 notifier 等待下游设备：

```
ISP 注册 notifier 等 CSI bridge
  └─ CSI bridge bound → CSI bridge 注册子 notifier 等 sensor
       └─ sensor bound → 整条链路 complete
```

```c
// v4l2_async_nf_try_subdev_notifier()
// 每个 subdev bound 后，检查它是否也有 notifier
subdev_notifier = v4l2_async_find_subdev_notifier(sd);
if (subdev_notifier) {
    subdev_notifier->parent = notifier;  // 建立父子关系
    v4l2_async_nf_try_all_subdevs(subdev_notifier);  // 递归匹配
}
```

---

## 八、实际案例：IMX500 + RPi5 CFE

### 8.1 CFE 注册 Notifier

```c
// drivers/media/platform/raspberrypi/rp1-cfe/cfe.c
static int cfe_register_async_nf(struct cfe_device *cfe)
{
    // 初始化
    v4l2_async_nf_init(&cfe->notifier, &cfe->v4l2_dev);
    cfe->notifier.ops = &cfe_async_ops;

    // 从 DTS endpoint 获取要等待的 fwnode
    local_ep_fwnode = fwnode_graph_get_endpoint_by_id(dev->fwnode, 0, 0, 0);

    // 添加异步连接描述："我在等连接到这个 endpoint 的设备"
    asd = v4l2_async_nf_add_fwnode_remote(&cfe->notifier, local_ep_fwnode, ...);

    // 注册并开始匹配
    v4l2_async_nf_register(&cfe->notifier);
}
```

### 8.2 IMX500 注册 Subdev

```c
// drivers/media/i2c/imx500.c probe 中
imx500->pad[IMAGE_PAD].flags = MEDIA_PAD_FL_SOURCE;
imx500->pad[METADATA_PAD].flags = MEDIA_PAD_FL_SOURCE;
media_entity_pads_init(&imx500->sd.entity, NUM_PADS, imx500->pad);

// 触发匹配
v4l2_async_register_subdev_sensor(&imx500->sd);
```

### 8.3 匹配成功 → 回调执行

```c
// bound：记录 sensor subdev
static int cfe_async_bound(struct v4l2_async_notifier *notifier,
                           struct v4l2_subdev *subdev, ...)
{
    cfe->source_sd = subdev;  // 拿到 IMX500 的 subdev 指针
}

// complete：组装 pipeline
static int cfe_async_complete(struct v4l2_async_notifier *notifier)
{
    return cfe_probe_complete(cfe);
    // → 注册 /dev/video0 ~ /dev/video7
    // → v4l2_create_fwnode_links_to_pad(): 为 IMX500 的 2 个 pad 创建 link
    // → media pipeline 拓扑完成
}
```

### 8.4 最终拓扑

```
IMX500                      CSI2 subdev                   Video nodes
┌─────────────┐            ┌──────────────────┐
│  pad[0]  ───┼──link──→──┤  pad[0] (SINK)   │
│  (IMAGE)    │            │                  │
│             │            │  pad[1] (SRC0) ──┼──→── /dev/video0
│  pad[1]  ───┼──link──→──┤  pad[2] (SRC1) ──┼──→── /dev/video1
│  (METADATA) │            │                  │
└─────────────┘            └──────────────────┘
```

---

## 九、数据结构总览

```c
struct v4l2_async_notifier {
    struct v4l2_device *v4l2_dev;            // 所属 v4l2 设备（根 notifier）
    struct v4l2_subdev *sd;                  // 所属 subdev（子 notifier）
    const struct v4l2_async_notifier_operations *ops;
    struct list_head waiting_list;           // 还在等的 asc
    struct list_head done_list;             // 已匹配的 asc
    struct list_head notifier_entry;        // 全局 notifier_list 链表节点
    struct v4l2_async_notifier *parent;     // 父 notifier
};

struct v4l2_async_connection {
    struct v4l2_async_match_desc match;     // 匹配描述（fwnode 或 i2c）
    struct v4l2_subdev *sd;                 // 匹配成功后指向 subdev
    struct list_head asc_entry;             // 链表节点（在 waiting/done list 中）
    struct list_head asc_subdev_entry;      // subdev 的 asc_list 中
};

struct v4l2_async_match_desc {
    enum v4l2_async_match_type type;        // FWNODE 或 I2C
    union {
        struct fwnode_handle *fwnode;
        struct { int adapter_id; unsigned short address; } i2c;
    };
};
```

---

## 十、总结

| 概念 | 说明 |
|------|------|
| "异步"的含义 | 不关心 probe 顺序，不是有线程在后台等 |
| 实现机制 | 两个全局链表 + mutex + 后到者主动查找 |
| 触发者 | 后注册的那一方（不管是 notifier 还是 subdev） |
| 执行上下文 | 后注册方的 probe 函数上下文（同步执行） |
| complete 条件 | 整棵 notifier 树的所有 waiting_list 都空 |
| 设计模式 | 观察者模式（Observer Pattern）的内核实现 |

**本质就是一句话：两个全局链表当"公告板"，谁后来谁去公告板上找对方。找到了就在当场执行回调。**
