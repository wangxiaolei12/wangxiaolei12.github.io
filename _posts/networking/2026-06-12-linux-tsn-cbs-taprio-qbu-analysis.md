---
layout: post
title: "Linux TSN 支持全景：802.1Qav CBS、802.1Qbv TAPRIO、802.1Qbu 帧抢占、ETF 精确发送"
date: 2026-06-12 13:40:00 +0800
excerpt: "深入分析 Linux 内核对 TSN (Time-Sensitive Networking) 协议族的实现：CBS 信用整形算法、TAPRIO 时间感知门控调度、ETF 精确发送时间、802.1Qbu MAC Merge 帧抢占，以及 PTP 时钟同步。以 NXP ENETC 硬件卸载为例。"
---

# Linux TSN 支持全景：从 CBS 到帧抢占

---

## 一、TSN 协议族与 Linux 实现的映射

TSN (Time-Sensitive Networking) 是 IEEE 802.1 的一组标准，Linux 通过 **tc qdisc** 和 **ethtool** 接口实现：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    IEEE TSN 标准 → Linux 实现                                 │
├────────────────────┬──────────────────────────┬─────────────────────────────┤
│ IEEE 标准          │ 功能                      │ Linux 实现                   │
├────────────────────┼──────────────────────────┼─────────────────────────────┤
│ 802.1Qav (QAV)     │ 信用整形 (Credit Based   │ tc qdisc cbs               │
│                    │ Shaper)                  │ net/sched/sch_cbs.c         │
├────────────────────┼──────────────────────────┼─────────────────────────────┤
│ 802.1Qbv (QBV)     │ 时间感知调度 (Time-Aware │ tc qdisc taprio            │
│                    │ Shaper, Gate Control)    │ net/sched/sch_taprio.c      │
├────────────────────┼──────────────────────────┼─────────────────────────────┤
│ 802.1Qbu + 802.3br │ 帧抢占 (Frame            │ ethtool --set-mm           │
│                    │ Preemption, MAC Merge)   │ drivers/net/.../ethtool.c   │
├────────────────────┼──────────────────────────┼─────────────────────────────┤
│ 802.1AS (gPTP)     │ 时钟同步                  │ drivers/ptp/ + linuxptp    │
│                    │                          │ (用户空间 ptp4l)            │
├────────────────────┼──────────────────────────┼─────────────────────────────┤
│ (LaunchTime)       │ 精确发送时间              │ tc qdisc etf               │
│                    │                          │ net/sched/sch_etf.c         │
├────────────────────┼──────────────────────────┼─────────────────────────────┤
│ 802.1Qci (PSFP)    │ 流过滤与管控              │ tc flower + gate action    │
│                    │                          │ net/sched/cls_flower.c      │
└────────────────────┴──────────────────────────┴─────────────────────────────┘
```

### 整体数据路径

```
应用层 (音视频/控制数据)
    │
    ├── SO_TXTIME socket option (设置精确发送时间)
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  TC (Traffic Control) 层                                  │
│                                                          │
│  ┌─────────┐                                             │
│  │ mqprio  │  多队列优先级映射 (traffic class → 硬件队列) │
│  └────┬────┘                                             │
│       │                                                  │
│  ┌────┼─────────────────────────────────────┐            │
│  │    ▼           ▼            ▼            │            │
│  │ ┌──────┐  ┌────────┐  ┌─────────┐       │            │
│  │ │ CBS  │  │ TAPRIO │  │  ETF    │       │            │
│  │ │(整形)│  │(门控)   │  │(精确时间)│       │            │
│  │ └──┬───┘  └───┬────┘  └────┬────┘       │            │
│  │    │           │            │            │            │
│  └────┼───────────┼────────────┼────────────┘            │
│       │           │            │                         │
│       └───────────┼────────────┘                         │
│                   ▼                                      │
│           网卡驱动 (ndo_start_xmit)                       │
│           或 硬件卸载 (ndo_setup_tc)                      │
└──────────────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  NIC 硬件 (如 NXP ENETC, Intel i210/i225)                │
│  ├── CBS 硬件整形引擎                                     │
│  ├── Time Gate (GCL 门控列表)                            │
│  ├── Launch Time 寄存器                                  │
│  ├── MAC Merge 帧抢占 (802.1Qbu)                         │
│  └── PTP 硬件时钟 (PHC)                                  │
└──────────────────────────────────────────────────────────┘
```

---

## 二、802.1Qav — CBS 信用整形 (sch_cbs.c)

### 算法原理

CBS 为时间敏感流量做**带宽整形**，防止突发占满链路。核心是**信用（credit）**机制：

```
credit (bytes)
  ▲
  │  hicredit ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  │          ╱╲
  │   等待  ╱  ╲  发送中
  │  (涨) ╱    ╲  (credit 下降，包不会中断)
  0 ─────╱──────╲──────────────────────────────── ← credit >= 0: 允许发下一个包
  │              ╲         ╱
  │               ╲ 等待  ╱
  │    (禁止发送)  ╲     ╱ (以 idleslope 恢复)
  │                 ╲   ╱
  │  locredit ─ ─ ─ ─╲╱─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ← 发完一帧后的最大欠债
  │
  ├── 等待 ──┤├── 发 ──┤├──── 等待(credit<0) ────┤├── 发 ──┤
```

**工作流程：**
1. dequeue 时检查 credit >= 0 → 取包发送（整个包发完不会中断）
2. 包发完后 credit 一次性扣减 → 可能变为负数（跌到 locredit 附近）
3. credit < 0 → 禁止发下一个包，以 idleslope 速率恢复信用
4. credit 恢复到 >= 0 → 允许发下一个包，回到第 1 步
5. 如果队列空了（无包可发），credit 以 idleslope 上涨，但最多到 hicredit 封顶

### 四个参数的计算

| 参数 | 含义 | 公式 | 说明 |
|------|------|------|------|
| `idleslope` | 分配给该流的带宽 (kbps) | 直接指定 | 空闲/等待时 credit 恢复速率 |
| `sendslope` | 发送时的净消耗速率 (kbps) | `idleslope - port_rate` | 一定是负数，因为发送占满整个链路 |
| `hicredit` | 信用上限 (bytes) | `max_interference_size × (idleslope / port_rate)` | 等别人最大帧发完期间能攒多少信用 |
| `locredit` | 信用下限 (bytes) | `max_frame_size × (sendslope / port_rate)` | 发完自己最大帧后最多欠多少（负值） |

**参数含义详解：**

- **port_rate**：网口物理链路速率（如 1Gbps = 1,000,000 kbps）
- **max_interference_size**：**其他流量**能发的最大帧（你的包可能要等它发完），通常 = MTU 1500 或含头 1522
- **max_frame_size**：**你这个 TC** 能发的最大帧

**实例推导 (1Gbps 端口，分配 20Mbps)：**

```
port_rate = 1,000,000 kbps
idleslope = 20,000 kbps (想分配 20Mbps)

sendslope = 20,000 - 1,000,000 = -980,000 kbps
  → 发送时每秒净消耗 980Mbps 的信用（因为占用 1G 链路但只配了 20M）

hicredit = 1500 × (20,000 / 1,000,000) = 1500 × 0.02 = 30 bytes
  → 等一个 1500B 干扰帧发完，期间以 2% 速率攒信用 = 最多攒 30B

locredit = 1500 × (-980,000 / 1,000,000) = 1500 × (-0.98) = -1470 bytes
  → 发完一个 1500B 帧，信用净消耗 = 1500 × 98% = 1470（2% 赚回来了）
```

**效果验证：**
```
发 1500B → credit 跌 1470 → 等待恢复到 0 需要 1470/2500 = 588μs
平均速率 = 1500×8 / 588μs ≈ 20 Mbps ✓ 正好等于 idleslope
```

### 实际多队列场景举例

**场景设定：**
```
端口: eth0, 物理速率 1Gbps
Q1 (TC7, 控制流): 最大包长 1500B, 分配 100Mbps
Q2 (TC6, 视频流): 最大包长 1800B, 分配 200Mbps
其余 (TC0-5): 尽力而为, 共享剩余 700Mbps
```

**Q1 的 CBS 参数（以 Q1 视角看）：**
```
credit (bytes)
  ▲
  │
180 ─ ─ hicredit ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  │              ╱╲                       队列空，信用
  │   等Q2的    ╱  ╲  Q1发送1500B包       攒到hicredit
  │   1800B包  ╱    ╲  (不中断)           就不再涨
  │   发完    ╱      ╲                          ────────
  0 ─────────╱────────╲────────────────────────────────── credit=0: 可发
  │                    ╲          ╱
  │                     ╲  等待  ╱ idleslope=100Mbps
  │   (禁止发送)         ╲     ╱  (以100Mbps速率恢复)
  │                       ╲   ╱
-1350 ─ ─ locredit ─ ─ ─ ─ ╲╱─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ 发完1500B欠1350
  │
  ├── 等Q2 ──┤├── Q1发 ──┤├──── 等待恢复 ─────────────┤

  hicredit=180: 等 Q2 的 1800B 大包发完，Q1 以 10% 速率攒信用
                180 = 1800 × (100,000/1,000,000)
                      ^^^^    ^^^^^^^^^^^^^^^
                      Q2包长    Q1带宽占比

  locredit=-1350: Q1 发完自己 1500B 包后的欠债
                  -1350 = 1500 × (-900,000/1,000,000)
                          ^^^^    ^^^^^^^^
                          Q1包长   Q1的sendslope/port_rate
```

**Q1 参数计算：**
```
idleslope  = 100,000 kbps (分配 100Mbps)
sendslope  = 100,000 - 1,000,000 = -900,000 kbps
hicredit   = 1800 × (100,000 / 1,000,000) = 180 bytes
               ↑ Q2的最大包(干扰源)
locredit   = 1500 × (-900,000 / 1,000,000) = -1350 bytes
               ↑ Q1自己的最大包
```

**Q2 的 CBS 参数（以 Q2 视角看）：**
```
credit (bytes)
  ▲
300 ─ ─ hicredit ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  │            ╱╲
  │  等Q1的   ╱  ╲ Q2发送1800B包
  │  1500B包 ╱    ╲
  0 ────────╱──────╲──────────────────────── credit=0
  │                 ╲        ╱
  │                  ╲等待  ╱ idleslope=200Mbps
  │                   ╲    ╱
-1440 ─ locredit ─ ─ ─ ╲╱─ ─ ─ ─ ─ ─ ─ ─ 发完1800B欠1440
  │
  hicredit=300: 等 Q1 的 1500B 包发完，Q2 以 20% 速率攒信用
                300 = 1500 × (200,000/1,000,000)
                      ^^^^    ^^^^^^^^^^^^^^^
                      Q1包长    Q2带宽占比

  locredit=-1440: Q2 发完自己 1800B 包后的欠债
                  -1440 = 1800 × (-800,000/1,000,000)
                          ^^^^
                          Q2自己包长
```

**Q2 参数计算：**
```
idleslope  = 200,000 kbps (分配 200Mbps)
sendslope  = 200,000 - 1,000,000 = -800,000 kbps
hicredit   = 1500 × (200,000 / 1,000,000) = 300 bytes
               ↑ Q1的最大包(干扰源)
locredit   = 1800 × (-800,000 / 1,000,000) = -1440 bytes
               ↑ Q2自己的最大包
```

**配置命令：**
```bash
# 多队列映射
tc qdisc replace dev eth0 parent root handle 100 mqprio \
    num_tc 3 map 0 0 0 0 0 0 1 2 queues 1@0 1@1 1@2

# Q1: 控制流 (TC7), 分配 100Mbps, 干扰源是 Q2 的 1800B
tc qdisc replace dev eth0 parent 100:3 cbs \
    idleslope 100000 sendslope -900000 \
    hicredit 180 locredit -1350 offload 1

# Q2: 视频流 (TC6), 分配 200Mbps, 干扰源是 Q1 的 1500B
tc qdisc replace dev eth0 parent 100:2 cbs \
    idleslope 200000 sendslope -800000 \
    hicredit 300 locredit -1440 offload 1
```

**参数对比总结：**

| | Q1 (控制, TC7, 100Mbps) | Q2 (视频, TC6, 200Mbps) |
|---|---|---|
| 自己最大包 | 1500B | 1800B |
| 干扰源(别人最大包) | Q2: 1800B | Q1: 1500B |
| idleslope | 100,000 | 200,000 |
| sendslope | -900,000 | -800,000 |
| hicredit | 180 (=1800×10%) | 300 (=1500×20%) |
| locredit | -1350 (=1500×90%) | -1440 (=1800×80%) |
| 发完一包等待时间 | 1350÷12500=108μs | 1440÷25000=57.6μs |
| 实际平均速率 | ≈100Mbps ✓ | ≈200Mbps ✓ |

**记忆口诀：**
- hicredit 用**别人的包长** × 自己带宽占比 → 等别人时能攒多少
- locredit 用**自己的包长** × (1 - 自己带宽占比) → 发自己包后欠多少（负数）

### 内核实现 (net/sched/sch_cbs.c)

```c
struct cbs_sched_data {
    bool offload;           // 是否硬件卸载
    s64 credits;            // 当前信用值 (bytes)
    s64 last;               // 上次更新时间 (ns)
    s32 locredit, hicredit; // 信用上下限
    s64 sendslope, idleslope; // 斜率 (bytes/s)
};

static struct sk_buff *cbs_dequeue_soft(struct Qdisc *sch)
{
    s64 now = ktime_get_ns();

    // 空闲期间累积信用
    if (q->credits < 0) {
        credits = timediff_to_credits(now - q->last, q->idleslope);
        q->credits = min(q->credits + credits, q->hicredit);

        if (q->credits < 0) {
            // 信用不足，设置定时器等待
            delay = delay_from_credits(q->credits, q->idleslope);
            qdisc_watchdog_schedule_ns(&q->watchdog, now + delay);
            return NULL;  // 不发送
        }
    }

    skb = dequeue_child();

    // 发送消耗信用 (sendslope 是负数)
    q->credits += credits_from_len(len, q->sendslope, port_rate);
    q->credits = max(q->credits, q->locredit);

    return skb;  // 发送
}
```

### 用户空间配置

```bash
# 为 eth0 的队列 3 配置 CBS，分配 75% 带宽 (1Gbps 链路)
tc qdisc replace dev eth0 parent root handle 100 mqprio \
    num_tc 4 map 0 0 0 1 2 3 3 3 queues 1@0 1@1 1@2 1@3

tc qdisc replace dev eth0 parent 100:4 cbs \
    idleslope 750000 sendslope -250000 \
    hicredit 15420 locredit -15420 offload 1
#                                       ^^^^^^^^
#                              offload=1: 卸载到硬件(NXP ENETC 支持)
```

---

## 三、802.1Qbv — TAPRIO 时间感知门控 (sch_taprio.c)

### 算法原理

TAPRIO 实现 **Gate Control List (GCL)**：按时间表周期性地开关各流量类别的"门"，确保时间敏感流量在确定的时间窗口独占链路：

```
时间 ──────────────────────────────────────────────────────────────▶

        ┌── cycle_time (如 1ms) ──┐
        │                         │
Gate 7: ████░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░...  (高优先级:开250μs)
Gate 6: ░░░░████░░░░░░░░░░░░░░░░░░░░░░████░░░░...
Gate 5: ░░░░░░░░████████████████░░░░░░░░░░████...  (尽力而为:开500μs)
Gate 0: ░░░░░░░░████████████████░░░░░░░░░░████...
        │                         │
        ├── entry[0] ──┤── entry[1] ──┤── entry[2] ─┤
        │ gate=0x80    │ gate=0x40    │ gate=0x3F   │
        │ interval=250μs│interval=250μs│interval=500μs│

█ = gate open (允许发送)    ░ = gate closed (禁止发送)
```

### 核心数据结构 (sch_taprio.c)

```c
struct sched_entry {
    u32 gate_mask;              // 哪些 TC 的门打开 (bitmap)
    u32 interval;               // 该条目持续时间 (ns)
    ktime_t end_time;           // 该条目结束时间
    atomic_t budget[TC_MAX_QUEUE]; // 每个 TC 剩余发送预算
};

struct sched_gate_list {
    struct list_head entries;    // GCL 条目链表
    s64 cycle_time;             // 周期时间
    s64 base_time;              // GCL 起始基准时间 (PTP 对齐)
    size_t num_entries;
};

// 发包时检查门状态：
static struct sk_buff *taprio_dequeue_from_txq(...)
{
    // 当前 TC 的门是否打开？
    if (!(gate_mask & BIT(tc)))
        return NULL;  // 门关闭，禁止发送

    // 帧是否能在门关闭前发完？
    if (packet_transmit_time > gate_close_time)
        return NULL;  // 来不及发完，不发（guard band）

    return skb;  // 门开且来得及 → 发送
}
```

### 用户空间配置

```bash
# 配置 TAPRIO：1ms 周期，TC7 独占前 250μs，其余 TC 共享后 750μs
tc qdisc replace dev eth0 parent root taprio \
    num_tc 4 \
    map 0 0 0 0 1 2 3 3 \
    queues 1@0 1@1 1@2 1@3 \
    base-time 1000000000 \
    sched-entry S 80 250000 \
    sched-entry S 7F 750000 \
    clockid CLOCK_TAI \
    flags 0x2
#   flags 0x2 = FULL_OFFLOAD (硬件执行 GCL)

# sched-entry S <gate_mask> <interval_ns>
# S 80 = 0b10000000 = 只开 TC7
# S 7F = 0b01111111 = 开 TC0-TC6
```

### 三种工作模式

| 模式 | flags | 实现 |
|------|-------|------|
| 软件模式 | 0x0 | 内核 qdisc 逻辑判断门状态，CPU 发包 |
| txtime-assist | 0x1 | taprio 计算 txtime，配合 ETF qdisc |
| 全硬件卸载 | 0x2 | GCL 下发到网卡硬件，硬件自动执行 |

---

## 四、ETF — 精确发送时间 (sch_etf.c)

### 功能

ETF (Earliest TxTime First) 让应用指定**精确的发送时间戳**，qdisc 按时间排序发送：

```
应用: sendmsg() with SO_TXTIME = T1
    │
    ▼
ETF qdisc (红黑树按 txtime 排序)
    │
    ├── T1 时刻到来 → 发送该包
    ├── 太早 → 等待 (watchdog)
    └── 太晚 (过了 deadline) → 丢弃 + 报错
```

### 内核实现

```c
struct etf_sched_data {
    struct rb_root_cached head;     // 红黑树，按 txtime 排序
    s32 delta;                      // 提前量 (ns)，补偿软件延迟
    ktime_t last;                   // 上次发送的 txtime
    int clockid;                    // CLOCK_TAI / CLOCK_REALTIME
    bool offload;                   // 硬件 LaunchTime 卸载
    bool deadline_mode;             // 超时是否丢包
};

// 入队：插入红黑树
static int etf_enqueue(skb) {
    txtime = skb->tstamp;  // 应用设置的发送时间
    // 插入红黑树，按 txtime 排序
    rb_add_cached(&head, node);
}

// 出队：取最早的
static struct sk_buff *etf_dequeue(sch) {
    skb = rb_first_cached(&head);  // 取 txtime 最早的包
    if (ktime_before(now, txtime - delta))
        schedule_watchdog(txtime - delta);  // 还没到时间，等
        return NULL;
    return skb;  // 时间到了，发
}
```

### 用户空间配置

```bash
# 在队列 2 上配置 ETF，使用 CLOCK_TAI，硬件卸载
tc qdisc add dev eth0 parent 100:3 etf \
    clockid CLOCK_TAI delta 200000 offload
#                     ^^^^^^^^^^^^
#                     提前 200μs 发给硬件（补偿队列延迟）

# 应用层:
setsockopt(fd, SOL_SOCKET, SO_TXTIME, &txtime_cfg, sizeof(txtime_cfg));
// sendmsg() 时在 cmsg 中携带 txtime
```

---

## 五、802.1Qbu — 帧抢占 / MAC Merge

### 原理

帧抢占允许**高优先级帧打断正在传输的低优先级帧**，将低优先级帧拆成片段，中间插入高优先级帧：

```
无帧抢占:
  ┌──── 低优先级大帧 (1500B, 12μs@1Gbps) ────┐  ┌── 高优先级 ──┐
  │                                           │  │             │
──┴───────────────────────────────────────────┴──┴─────────────┴──→ 时间
                                                  ↑
                                              最坏延迟 = 12μs

有帧抢占:
  ┌── 低优先级片段1 ──┐┌── 高优先级 ──┐┌── 低优先级片段2 (续) ──┐
  │                   ││             ││                        │
──┴───────────────────┴┴─────────────┴┴────────────────────────┴──→ 时间
                        ↑
                    最坏延迟 ≈ 片段最小大小 (64+4=68B ≈ 0.5μs)
```

### Linux 实现 — ethtool MM (MAC Merge)

802.1Qbu 通过 **ethtool** 配置，不是 tc qdisc：

```c
// NXP ENETC 实现 (enetc_ethtool.c):
static int enetc_set_mm(struct net_device *ndev, struct ethtool_mm_cfg *cfg,
                        struct netlink_ext_ack *extack)
{
    // 配置哪些 TC 是 express (可抢占) vs preemptable (被抢占)
    // 写 ENETC_PFPMR 寄存器
    // 使能 MAC Merge 验证流程
}

static int enetc_get_mm(struct net_device *ndev, struct ethtool_mm_state *state)
{
    // 读 ENETC_MMCSR 寄存器
    // 返回: verify_status, tx_active, pmac_enabled
    // tx_min_frag_size (最小片段 60~228 bytes)
}
```

### 用户空间配置

```bash
# 查看 MAC Merge 状态
ethtool --show-mm eth0

# 使能帧抢占，TC7 为 express，其余为 preemptable
ethtool --set-mm eth0 pmac-enabled on tx-enabled on \
    verify-enabled on tx-min-frag-size 60

# 设置哪些 TC 是 preemptable (配合 mqprio/taprio):
tc qdisc replace dev eth0 parent root taprio \
    ... fp T T T T T T T E
#       TC: 0 1 2 3 4 5 6 7
#       T=preemptable  E=express (不可被抢占)
```

---

## 六、PTP 时钟同步 (802.1AS / gPTP)

所有 TSN 功能都依赖**精确时钟同步**。Linux 通过 PTP 子系统提供硬件时钟 (PHC) 接口：

```
┌────────────────────────────────────────────────────────────────┐
│  用户空间: linuxptp (ptp4l + phc2sys)                           │
│                                                                │
│  ptp4l:   网络 PTP 协议，同步 PHC 到 GrandMaster              │
│  phc2sys: 将 PHC 同步到系统时钟 (CLOCK_REALTIME/TAI)           │
└────────────────────────┬───────────────────────────────────────┘
                         │ ioctl(/dev/ptp0)
┌────────────────────────┼───────────────────────────────────────┐
│  内核 PTP 子系统        │                                       │
│                        │                                       │
│  drivers/ptp/ptp_clock.c                                       │
│    ├── ptp_clock_register()      注册 PHC                      │
│    ├── .gettime64()              读取硬件时钟                   │
│    ├── .settime64()              设置硬件时钟                   │
│    └── .adjfine()                微调频率                      │
│                                                                │
│  NXP 实现:                                                     │
│    drivers/net/ethernet/freescale/enetc/enetc_ptp.c            │
│    drivers/ptp/ptp_qoriq.c (LS1028A/LS1088A)                  │
└────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────┐
│  NIC 硬件 PTP 时钟 (PHC)                                       │
│  ├── 纳秒级计数器                                              │
│  ├── TX/RX 时间戳寄存器 (记录帧进出时刻)                        │
│  └── 1PPS 输出引脚 (外部设备同步)                              │
└────────────────────────────────────────────────────────────────┘
```

---

## 七、NXP ENETC 硬件卸载实例

NXP LS1028A 的 ENETC 是完整支持 TSN 硬件卸载的网卡：

### 驱动入口 — ndo_setup_tc

```c
// drivers/net/ethernet/freescale/enetc/enetc_pf.c
static int enetc_pf_setup_tc(struct net_device *ndev,
                             enum tc_setup_type type, void *type_data)
{
    switch (type) {
    case TC_SETUP_QDISC_MQPRIO:
        return enetc_setup_tc_mqprio(ndev, type_data);
    case TC_SETUP_QDISC_TAPRIO:
        return enetc_setup_tc_taprio(ndev, type_data);   // QBV 卸载
    case TC_SETUP_QDISC_CBS:
        return enetc_setup_tc_cbs(ndev, type_data);      // QAV 卸载
    case TC_SETUP_QDISC_ETF:
        return enetc_setup_tc_txtime(ndev, type_data);   // LaunchTime
    case TC_SETUP_BLOCK:
        return enetc_setup_tc_psfp(ndev, type_data);     // Qci 流过滤
    }
}

static const struct net_device_ops enetc_ndev_ops = {
    .ndo_setup_tc = enetc_pf_setup_tc,
    ...
};
```

### CBS 硬件卸载 (enetc_qos.c)

```c
int enetc_setup_tc_cbs(struct net_device *ndev, void *type_data)
{
    struct tc_cbs_qopt_offload *cbs = type_data;

    // 计算带宽百分比
    bw = cbs->idleslope / (port_transmit_rate * 10UL);

    // 计算 hi_credit 寄存器值
    hi_credit_bit = port_frame_max_size * (bw + bw_sum);

    // 写 ENETC CBS 寄存器
    enetc_port_wr(hw, ENETC_PTCCBSR1(tc),
                  ENETC_CBSE | /* enable */
                  bw);         /* bandwidth fraction */
    enetc_port_wr(hw, ENETC_PTCCBSR0(tc), hi_credit_reg);
    // → 硬件自动执行信用整形，零 CPU 开销
}
```

### TAPRIO 硬件卸载 (enetc_qos.c)

```c
static int enetc_setup_taprio(struct enetc_ndev_priv *priv,
                              struct tc_taprio_qopt_offload *admin_conf)
{
    // 将 GCL 写入 ENETC 寄存器
    for (i = 0; i < admin_conf->num_entries; i++) {
        struct tc_taprio_sched_entry *e = &admin_conf->entries[i];

        // 写每个 GCL 条目：gate_mask + interval
        enetc_port_wr(hw, gate_reg, e->gate_mask);
        enetc_port_wr(hw, interval_reg, e->interval);
    }

    // 设置 base_time 和 cycle_time
    enetc_port_wr(hw, base_time_reg, admin_conf->base_time);
    enetc_port_wr(hw, cycle_time_reg, admin_conf->cycle_time);

    // 使能 QBV
    priv->active_offloads |= ENETC_F_QBV;
    // → 硬件按 GCL 时间表自动开关门
}
```

---

## 八、软件 vs 硬件卸载对比

```
┌──────────────────────────────────────────────────────────────────┐
│              软件实现 (offload=0)                                  │
│                                                                  │
│  tc qdisc → sch_cbs/taprio 内核代码判断 → CPU 控制发送时机        │
│  精度: ~微秒级 (受调度延迟影响)                                   │
│  CPU 开销: 高 (每包都要计算)                                      │
│  适用: 没有 TSN 硬件的网卡                                       │
├──────────────────────────────────────────────────────────────────┤
│              硬件卸载 (offload=1 / flags=0x2)                     │
│                                                                  │
│  tc qdisc → ndo_setup_tc → 驱动写寄存器 → 硬件自动执行           │
│  精度: ~纳秒级 (硬件时钟驱动)                                    │
│  CPU 开销: 零 (配置完后硬件自治)                                  │
│  适用: NXP ENETC, Intel i210/i225, TI AM65x CPSW                │
└──────────────────────────────────────────────────────────────────┘
```

---

## 九、典型 TSN 配置全流程

```bash
# 1. 时钟同步 (必须先做)
ptp4l -i eth0 -f gPTP.cfg --step_threshold=1 &
phc2sys -a -rr &

# 2. 多队列映射
tc qdisc replace dev eth0 parent root handle 100 mqprio \
    num_tc 4 map 0 0 1 1 2 2 3 3 \
    queues 1@0 1@1 1@2 1@3 hw 0

# 3. 门控调度 (QBV) — 1ms 周期
tc qdisc replace dev eth0 parent root taprio \
    num_tc 4 map 0 0 1 1 2 2 3 3 \
    queues 1@0 1@1 1@2 1@3 \
    base-time 200 \
    sched-entry S 0x80 125000 \
    sched-entry S 0x7F 875000 \
    clockid CLOCK_TAI \
    flags 0x2

# 4. CBS 整形 (QAV) — 为 TC3 分配 25% 带宽
tc qdisc replace dev eth0 parent 100:4 cbs \
    idleslope 250000 sendslope -750000 \
    hicredit 7692 locredit -7692 offload 1

# 5. 帧抢占 (Qbu)
ethtool --set-mm eth0 pmac-enabled on tx-enabled on verify-enabled on

# 6. 精确发送 (ETF)
tc qdisc add dev eth0 parent 100:1 etf \
    clockid CLOCK_TAI delta 500000 offload
```

---

## 十、源文件索引

| 文件 | 功能 |
|------|------|
| `net/sched/sch_cbs.c` | CBS 信用整形 qdisc |
| `net/sched/sch_taprio.c` | TAPRIO 时间感知门控 qdisc |
| `net/sched/sch_etf.c` | ETF 精确发送时间 qdisc |
| `net/sched/sch_mqprio.c` | 多队列优先级映射 |
| `include/net/pkt_sched.h` | TC 调度器公共定义 |
| `include/uapi/linux/pkt_sched.h` | 用户空间 API 定义 |
| `drivers/net/ethernet/freescale/enetc/enetc_qos.c` | NXP ENETC TSN 卸载 |
| `drivers/net/ethernet/freescale/enetc/enetc_ethtool.c` | ENETC MAC Merge (Qbu) |
| `drivers/net/ethernet/freescale/enetc/enetc_ptp.c` | ENETC PTP 时钟 |
| `drivers/ptp/ptp_clock.c` | PTP 子系统核心 |
| `drivers/ptp/ptp_qoriq.c` | NXP QorIQ PTP 驱动 |
| `net/core/filter.c` | SO_TXTIME socket 选项 |
