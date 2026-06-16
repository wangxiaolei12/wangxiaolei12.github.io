---
layout: post
title: "Linux TC Qdisc 全解(1): 基础调度器 — FIFO/PRIO/TBF/HTB/HFSC/DRR"
date: 2026-06-16 21:30:00 +0800
excerpt: "Linux 流量控制基础 qdisc 详解：FIFO 先进先出、PRIO 严格优先级、TBF 令牌桶、HTB 层次令牌桶、HFSC 层次公平服务曲线、DRR 赤字轮转。原理、数据结构与配置。"
---

# Linux TC Qdisc 全解(1): 基础调度器

源码: `net/sched/sch_*.c`

---

## 概览：所有 qdisc 分类

```
Qdisc 分类:
┌─────────────────────────────────────────────────────────────────────┐
│ 无类 (Classless) — 不能挂子 qdisc                                    │
│   FIFO, TBF, SFQ, RED, NETEM, FQ, FQ_CODEL, CAKE, CBS, ETF, PIE   │
├─────────────────────────────────────────────────────────────────────┤
│ 有类 (Classful) — 可以挂子 qdisc，支持分类                           │
│   PRIO, HTB, HFSC, DRR, QFQ, MQPRIO, ETS, TAPRIO                  │
├─────────────────────────────────────────────────────────────────────┤
│ 特殊/基础设施                                                        │
│   MQ (多队列), INGRESS (入方向), BLACKHOLE (丢弃)                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 一、sch_fifo.c — FIFO (先进先出)

**最简单的 qdisc：按到达顺序排队，超过 limit 就丢包。**

```
算法: 入队直接追加尾部，出队取头部
参数: limit (最大队列长度，包数或字节数)
```

```c
// 两种变体:
pfifo: limit 以包数计 (默认 txqueuelen)
bfifo: limit 以字节计

// enqueue:
if (queue_length >= limit)
    drop(skb);  // 尾部丢弃 (tail drop)
else
    __skb_queue_tail(&q->queue, skb);

// dequeue:
return __skb_dequeue(&q->queue);
```

```bash
tc qdisc add dev eth0 root pfifo limit 1000    # 最多 1000 包
tc qdisc add dev eth0 root bfifo limit 100000  # 最多 100KB
```

**问题：** 尾部丢弃会导致 TCP 全局同步（多条流同时丢包→同时降速→同时恢复→又同时丢包）。

---

## 二、sch_prio.c — PRIO (严格优先级)

**有类 qdisc：高优先级 band 不空就不看低优先级。**

```
结构 (默认 3 个 band):
┌───────────────────────────────────────────┐
│  Band 0 (最高优先级) → 只要有包就先发它    │
│  Band 1 (中优先级)   → Band 0 空了才发     │
│  Band 2 (最低优先级) → Band 0,1 都空才发   │
└───────────────────────────────────────────┘

分类: 根据 skb->priority (由 TOS/DSCP 映射到 band)
      priomap[16] 定义映射规则
```

```c
// dequeue: 从高到低扫描
static struct sk_buff *prio_dequeue(struct Qdisc *sch)
{
    for (int prio = 0; prio < q->bands; prio++) {
        struct Qdisc *qdisc = q->queues[prio];
        skb = qdisc->dequeue(qdisc);
        if (skb)
            return skb;  // 高优先级有包就返回
    }
    return NULL;
}
```

```bash
tc qdisc add dev eth0 root handle 1: prio bands 3 \
    priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1
# TOS → band 映射
```

**问题：** 低优先级可能被饿死。实际用 HTB/HFSC 更好。

---

## 三、sch_tbf.c — TBF (令牌桶过滤器)

**限速 qdisc：按固定速率发送，允许小突发。**

```
算法:
┌─────────────────────────────────────────┐
│ 令牌桶:                                  │
│   rate: 令牌填充速率 (如 1Mbps)          │
│   burst: 桶大小 (最大突发，如 10KB)      │
│                                         │
│ 包到来时:                                │
│   if (桶中令牌 >= 包大小)                │
│       消耗令牌，发送                     │
│   else                                  │
│       等待(延迟发送) 或 丢弃             │
└─────────────────────────────────────────┘

效果: 平均速率 = rate, 瞬间突发 ≤ burst
```

```c
// dequeue:
static struct sk_buff *tbf_dequeue(struct Qdisc *sch)
{
    skb = q->qdisc->peek(q->qdisc);
    toks = min(q->toks + elapsed * rate, burst);  // 令牌累积
    
    if (toks >= qdisc_pkt_len(skb)) {
        skb = q->qdisc->dequeue(q->qdisc);
        q->toks -= qdisc_pkt_len(skb);  // 消耗令牌
        return skb;
    }
    // 令牌不够 → 计算等待时间，设置 watchdog
    qdisc_watchdog_schedule_ns(&q->watchdog, next_time);
    return NULL;
}
```

```bash
# 限速 10Mbps, 突发 32KB:
tc qdisc add dev eth0 root tbf rate 10mbit burst 32kbit latency 50ms
```

---

## 四、sch_htb.c — HTB (层次令牌桶)

**最常用的有类 qdisc：分层限速+带宽共享+保证最低带宽。**

```
算法: 每个 class 有两个参数:
  rate:  保证带宽 (guaranteed)
  ceil:  最大带宽 (借用上限)

层次结构:
┌─────────────────────────────────────┐
│ root class: rate=100mbit ceil=100mbit│
│ ├── class A: rate=30mbit ceil=100mbit│ ← 保证 30M，最多借到 100M
│ │   ├── leaf A1: rate=10mbit        │
│ │   └── leaf A2: rate=20mbit        │
│ └── class B: rate=70mbit ceil=100mbit│ ← 保证 70M
│     ├── leaf B1: rate=50mbit        │
│     └── leaf B2: rate=20mbit        │
└─────────────────────────────────────┘

核心机制:
  - 每个 class 有自己的令牌桶 (rate 桶 + ceil 桶)
  - rate 桶有令牌 → 可以发 (不消耗父级额度)
  - rate 桶空了但 ceil 桶有令牌 → 可以借用父级空闲带宽
  - ceil 桶也空了 → 等待

class 三种状态:
  CAN_SEND:    rate 桶有令牌 (自己的带宽)
  MAY_BORROW:  rate 桶空，但 ceil 未满 (借用)
  CANT_SEND:   ceil 也空了 (等待)
```

```bash
# 创建 HTB root:
tc qdisc add dev eth0 root handle 1: htb default 30

# 根 class:
tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit

# 子 class:
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 30mbit ceil 100mbit
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 70mbit ceil 100mbit

# 过滤器 (按 IP 分类):
tc filter add dev eth0 parent 1: protocol ip u32 \
    match ip dst 192.168.1.0/24 flowid 1:10
```

---

## 五、sch_hfsc.c — HFSC (层次公平服务曲线)

**比 HTB 更精确的延迟保证：用服务曲线而不是简单速率。**

```
每个 class 有三条曲线:
  rt (real-time):  实时保证 — 严格延迟保证
  ls (link-share): 链路共享 — 带宽比例分配
  ul (upper-limit): 上限 — 最大速率

曲线格式: (m1, d, m2)
  m1: 初始突发速率
  d:  突发持续时间
  m2: 稳态速率

              速率
               ▲
          m1 ──┤────┐
               │    │
          m2 ──┤    └──────────
               │
               └──────┬───────→ 时间
                      d

优势: 可以保证 "前 10ms 以 10Mbps 突发，之后 1Mbps 稳态"
      适合实时语音/视频的延迟需求
```

```bash
tc qdisc add dev eth0 root handle 1: hfsc
tc class add dev eth0 parent 1: classid 1:1 hfsc \
    rt m1 10mbit d 10ms m2 1mbit \
    ls m2 5mbit
```

---

## 六、sch_drr.c — DRR (赤字轮转)

**按权重公平轮转各 class。**

```
算法:
  每个 class 有 quantum (权重，单位字节)
  每个 class 有 deficit (赤字计数器)

  轮转时:
    deficit += quantum         // 补充赤字
    while (deficit >= 包大小):
        发送该 class 的一个包
        deficit -= 包大小
    // deficit 不够发下一个 → 轮到下一个 class

效果: 各 class 按 quantum 比例分享带宽
      quantum=1000 vs quantum=2000 → 带宽比 1:2
      
优势: O(1) 每包开销（比 WFQ/WRR 简单）
```

```bash
tc qdisc add dev eth0 root handle 1: drr
tc class add dev eth0 parent 1: classid 1:1 drr quantum 1500
tc class add dev eth0 parent 1: classid 1:2 drr quantum 3000  # 2倍带宽
```

---

## 七、sch_mqprio.c / sch_mq.c — 多队列映射

```
MQ:     内核默认 qdisc，为每个硬件 TX queue 创建独立子 qdisc
MQPRIO: 将 traffic class (TC) 映射到硬件队列

┌─────────────────────────────────────────┐
│ MQPRIO                                  │
│ TC 0 (Best Effort) → HW Queue 0        │
│ TC 1 (Video)       → HW Queue 1        │
│ TC 2 (Voice)       → HW Queue 2        │
│ TC 3 (Control)     → HW Queue 3        │
└─────────────────────────────────────────┘

用于: TSN 场景，配合 CBS/TAPRIO
```

```bash
tc qdisc replace dev eth0 root handle 100 mqprio \
    num_tc 4 map 0 0 1 1 2 2 3 3 queues 1@0 1@1 1@2 1@3 hw 0
```

---

## 八、源文件索引

| 文件 | qdisc | 算法 |
|------|-------|------|
| `sch_fifo.c` | pfifo/bfifo | 先进先出 + 尾部丢弃 |
| `sch_prio.c` | prio | 严格优先级 (多 band) |
| `sch_tbf.c` | tbf | 单级令牌桶限速 |
| `sch_htb.c` | htb | 层次令牌桶 (rate/ceil/借用) |
| `sch_hfsc.c` | hfsc | 层次公平服务曲线 (rt/ls/ul) |
| `sch_drr.c` | drr | 赤字轮转 (quantum 权重) |
| `sch_qfq.c` | qfq | 快速公平排队 |
| `sch_ets.c` | ets | Enhanced Transmission Selection (802.1Qaz) |
| `sch_multiq.c` | multiq | 多队列 |
| `sch_mqprio.c` | mqprio | TC→硬件队列映射 |
| `sch_mq.c` | mq | per-TX-queue 默认 qdisc |
| `sch_skbprio.c` | skbprio | SKB 优先级队列 |
| `sch_plug.c` | plug | 暂停/恢复队列 (用于快照) |
| `sch_teql.c` | teql | 链路均衡 |
