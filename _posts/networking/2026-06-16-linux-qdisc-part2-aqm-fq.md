---
layout: post
title: "Linux TC Qdisc 全解(2): AQM 与公平队列 — RED/FQ/FQ_CODEL/CAKE/PIE/SFQ"
date: 2026-06-16 21:31:00 +0800
excerpt: "主动队列管理 (AQM) 和公平队列调度器详解：RED 随机早期检测、CoDel 延迟控制、FQ 公平队列+pacing、FQ_CoDel 组合、CAKE 一站式方案、PIE 比例积分、SFQ 随机公平。"
---

# Linux TC Qdisc 全解(2): AQM 与公平队列

---

## 一、sch_red.c — RED (随机早期检测)

**在队列满之前就随机丢包，避免 TCP 全局同步。**

```
算法:
  维护 avg_queue_length (指数加权移动平均)

  if (avg < min_th):
      不丢包，正常入队
  elif (min_th <= avg < max_th):
      概率丢包: p = (avg - min_th) / (max_th - min_th) * max_p
      avg 越接近 max_th，丢包概率越高
  elif (avg >= max_th):
      全部丢包

概率丢弃示意:
  丢包概率
  ▲
  │        ╱────── 100%
  │       ╱
  │      ╱  (线性增长)
max_p ──╱
  │    ╱
  │   ╱
  0 ──┴─────┬──────┬───→ 平均队列长度
         min_th  max_th
```

```bash
tc qdisc add dev eth0 root red limit 200000 min 10000 max 60000 \
    avpkt 1500 burst 20 probability 0.02 bandwidth 10mbit
```

**GRED (sch_gred.c):** Generic RED，支持多个虚拟队列（不同 DP = Drop Precedence）。

---

## 二、sch_codel.c — CoDel (Controlled Delay)

**控制队列延迟而不是长度。解决 bufferbloat。**

```
核心思想: 丢包的依据不是队列长度，而是包在队列中停留的时间

算法:
  每次 dequeue 时:
    sojourn_time = now - skb->enqueue_time  // 包在队列中待了多久

    if (sojourn_time < target):    // target 默认 5ms
        正常状态，不丢包
        
    elif (持续超过 interval):       // interval 默认 100ms
        进入 dropping 状态
        按 1/sqrt(count) 间隔丢包
        count 每次丢包 +1 → 丢包间隔越来越短
        
    回到 target 以下 → 退出 dropping 状态

为什么好:
  - 空闲链路: 队列短 → sojourn_time 小 → 不丢包 ✓
  - 满载链路: 包在队列排久了 → sojourn_time 大 → 开始丢包
  - 不需要调参! target=5ms, interval=100ms 几乎适合所有场景
```

```bash
tc qdisc add dev eth0 root codel target 5ms interval 100ms
```

---

## 三、sch_fq.c — FQ (公平队列 + Pacing)

**per-flow 公平队列 + TCP pacing（配合 BBR 等拥塞控制）。**

```
结构:
  1024+ 个 RB 树 (hash bucket)
  每个 flow = 一个 socket (skb->sk 区分)
  两个 Round-Robin 列表: new_flows / old_flows

算法:
  enqueue:
    flow = hash(skb->sk) → 找到或创建 flow
    将 skb 挂到 flow 的 FIFO 尾部
    如果 flow 是新的 → 加入 new_flows 列表

  dequeue (Round Robin):
    先服务 new_flows (公平给新流一个机会)
    再服务 old_flows
    每个 flow 每轮最多发 quantum 字节 (默认=MTU)

  Pacing (核心特性!):
    if (sk->sk_pacing_rate > 0):
        计算该 flow 下一个包的 earliest_txtime
        如果还没到时间 → 不发，设 watchdog
    效果: TCP BBR 设好 pacing_rate，FQ 负责按时间均匀发包
          避免突发，减少 bufferbloat

flow 生命周期:
  新包到来 → 创建 flow → new_flows → 发完 quantum → old_flows
  → flow 空了 → 延迟删除 (SLAB 缓存复用)
```

```bash
# 默认 qdisc (很多发行版默认):
tc qdisc add dev eth0 root fq
# 配合 BBR:
sysctl -w net.ipv4.tcp_congestion_control=bbr
# BBR 设置 sk_pacing_rate → FQ 执行 pacing
```

**FQ 是 BBR 的最佳搭档！** BBR 算出速率，FQ 按速率均匀发包。

---

## 四、sch_fq_codel.c — FQ_CoDel (公平队列 + CoDel)

**FQ + CoDel 的组合：公平隔离各流 + 延迟控制。Linux 默认 qdisc。**

```
结构:
  1024 个队列 (hash bucket)
  每个流 hash 到一个队列
  每个队列独立做 CoDel AQM

算法:
  enqueue:
    flow_idx = hash(src, dst, sport, dport, proto) % 1024
    入队到 flows[flow_idx]
    如果队列从空变非空 → 加入 new_flows/old_flows

  dequeue (DRR + CoDel):
    Round-Robin 各活跃流 (quantum=1514)
    每个流 dequeue 时做 CoDel 延迟检测
    延迟超标的流 → 丢包

效果:
  - 一个大流不能挤占小流 (FQ 公平)
  - 所有流的延迟都被控制在 target 以内 (CoDel)
  - 无需配置! 开箱即用
```

```bash
# 通常已是默认:
tc qdisc add dev eth0 root fq_codel
# 查看:
tc qdisc show dev eth0
# qdisc fq_codel 0: root ... target 5000us interval 100000us quantum 1514
```

---

## 五、sch_cake.c — CAKE (Common Applications Kept Enhanced)

**一站式解决方案：整形 + AQM + FQ + 流隔离 + Diffserv + NAT 感知。**

```
CAKE = TBF(整形) + FQ_CoDel(公平+AQM) + 更多智能

特性:
  1. 带宽整形: deficit mode (类似 FQ)，无需设 burst
  2. AQM: 改进的 CoDel (BLUE 辅助)
  3. 流隔离: 8-way set-associative hash (比 FQ_CoDel 更精确)
  4. Diffserv 感知: 8 个 tin (优先级层)，自动映射 DSCP
  5. NAT 感知: 能正确区分 NAT 后面的不同主机
  6. 双向: 支持 ingress 整形 (配合 IFB)

Tin (优先级层):
  Tin 0: Voice      (最高优先级，低延迟)
  Tin 1: Video
  Tin 2: Best Effort (默认)
  Tin 3: Bulk        (后台下载)
  ...

每个 Tin 内部: 独立的 FQ + CoDel
```

```bash
# 最简配置 (家用路由器最佳选择):
tc qdisc replace dev eth0 root cake bandwidth 50mbit

# 完整配置:
tc qdisc replace dev eth0 root cake \
    bandwidth 50mbit \
    diffserv4 \        # 4 个优先级 tin
    nat \              # NAT 感知
    wash \             # 清除入站 DSCP
    split-gso          # GSO 拆包后独立计算
```

**CAKE 是家用路由器/OpenWrt 的首选 qdisc。** 一行命令解决 bufferbloat。

---

## 六、sch_pie.c — PIE (Proportional Integral controller Enhanced)

**另一种 AQM：用 PI 控制器控制延迟。**

```
算法:
  与 CoDel 目标相同 (控制延迟)，但方法不同:
  
  CoDel: 在 dequeue 时测量延迟，按时间间隔丢包
  PIE:   用 PI 控制器计算丢包概率

  p = p + alpha * (delay - target) + beta * (delay - old_delay)
      ^         ^                         ^
      当前概率   比例项(当前偏差)           积分项(变化趋势)

  enqueue 时以概率 p 丢包

效果: 类似 CoDel，但实现方式不同
```

```bash
tc qdisc add dev eth0 root pie target 15ms tupdate 15ms alpha 2 beta 20
```

**FQ_PIE (sch_fq_pie.c):** FQ + PIE 的组合，类似 FQ_CoDel 但用 PIE 做 AQM。

---

## 七、sch_sfq.c — SFQ (随机公平队列)

**轻量级公平队列：hash 分流 + Round-Robin。**

```
算法:
  1024 个桶 (hash bucket)
  每个 flow hash 到一个桶
  Round-Robin 各桶，每桶每轮发一个包

  特点: 定期 rehash (perturb, 默认 10s) 防止 hash 冲突固化

  比 FQ_CoDel 简单，但没有 AQM（不控制延迟）
```

```bash
tc qdisc add dev eth0 root sfq perturb 10 quantum 1500
```

---

## 八、sch_sfb.c — SFB (Stochastic Fair Blue)

```
算法: 多级 hash + BLUE AQM
  用多级 bloom filter 检测"不公平"的流
  对行为不好的流增加丢包概率
  对正常流几乎不丢包
  
优势: 不需要 per-flow 状态，内存占用极低
```

---

## 九、sch_choke.c — CHOke (CHOose and Keep/Kill)

```
算法: RED 变体
  入队时随机抽一个队列中的包
  如果新包和随机包属于同一流 → 两个都丢
  惩罚发送过快的流

效果: 流量多的流被丢包概率更高 → 隐式公平
```

---

## 十、sch_hhf.c — HHF (Heavy-Hitter Filter)

```
算法:
  检测 "heavy hitter" (大流量流)
  heavy hitter 走单独的 FIFO (可能被限速/丢包)
  正常流走公平队列

用途: 数据中心，隔离 elephant flow
```

---

## 十一、sch_dualpi2.c — DualPI2

```
算法: 双队列 PI2
  Classic queue: 经典 TCP (Reno/CUBIC) 走这里，PI AQM
  L4S queue:     可扩展拥塞控制 (DCTCP/Prague) 走这里，ECN 标记

  两个队列联合用一个 PI 控制器
  
用途: 支持 L4S (Low Latency Low Loss Scalable Throughput) 架构
```

---

## 十二、对比总结

| qdisc | 类型 | 核心算法 | 典型场景 |
|-------|------|---------|---------|
| `red` | AQM | 随机早期检测 | 简单防全局同步 |
| `codel` | AQM | 延迟控制 | 控制 bufferbloat |
| `pie` | AQM | PI 控制器 | 类似 codel |
| `fq` | 公平+Pacing | per-flow RR + pacing | BBR 配合 |
| `fq_codel` | 公平+AQM | FQ + CoDel | **Linux 默认** |
| `cake` | 全功能 | 整形+FQ+CoDel+Diffserv | **家用路由器首选** |
| `sfq` | 公平 | hash + RR | 轻量级公平 |
| `sfb` | AQM | bloom filter + BLUE | 低内存 |
| `hhf` | 公平 | heavy hitter 隔离 | 数据中心 |
| `dualpi2` | AQM | 双队列 PI2 | L4S |

---

## 十三、源文件索引

| 文件 | 算法 |
|------|------|
| `sch_red.c` | Random Early Detection |
| `sch_gred.c` | Generic RED (多级 DP) |
| `sch_codel.c` | Controlled Delay |
| `sch_fq.c` | Fair Queue + Pacing |
| `sch_fq_codel.c` | FQ + CoDel |
| `sch_cake.c` | CAKE (全功能) |
| `sch_pie.c` | Proportional Integral Enhanced |
| `sch_fq_pie.c` | FQ + PIE |
| `sch_sfq.c` | Stochastic Fairness Queueing |
| `sch_sfb.c` | Stochastic Fair Blue |
| `sch_choke.c` | CHOose and Keep/Kill |
| `sch_hhf.c` | Heavy-Hitter Filter |
| `sch_dualpi2.c` | Dual PI Improved with a Square |
