---
layout: post
title: "Linux TC Qdisc 全解(3): TSN/特殊用途 + 分类器(cls) + Action"
date: 2026-06-16 21:32:00 +0800
excerpt: "TSN 时间敏感调度器 CBS/ETF/TAPRIO、网络模拟器 NETEM、分类器 cls_u32/flower/bpf、TC Action 动作链。完整的 TC 流量控制体系。"
---

# Linux TC Qdisc 全解(3): TSN + 分类器 + Action

---

## 一、TSN 相关 Qdisc

### 1.1 sch_cbs.c — CBS (Credit Based Shaper, 802.1Qav)

```
算法: 信用整形（详见 TSN 专题文章）
  credit >= 0 时允许发送
  发送时消耗信用 (sendslope)
  空闲时恢复信用 (idleslope)

用途: 为时间敏感流量做带宽限速，防止突发
```

```bash
tc qdisc add dev eth0 parent 100:4 cbs \
    idleslope 20000 sendslope -980000 hicredit 30 locredit -1470 offload 1
```

### 1.2 sch_etf.c — ETF (Earliest TxTime First)

```
算法:
  每个包携带精确发送时间 (SO_TXTIME)
  用红黑树按 txtime 排序
  到时间就发，过时间就丢

用途: 精确控制每个包的发送时刻
```

```bash
tc qdisc add dev eth0 parent 100:1 etf clockid CLOCK_TAI delta 200000 offload
```

### 1.3 sch_taprio.c — TAPRIO (Time-Aware Priority, 802.1Qbv)

```
算法: 时间门控
  Gate Control List (GCL): 按时间表周期性开关各 TC 的"门"
  门开 → 该 TC 可以发包
  门关 → 该 TC 禁止发包

用途: 确保时间敏感流量在确定时间窗口独占链路
```

```bash
tc qdisc replace dev eth0 parent root taprio \
    num_tc 2 map 0 0 0 0 0 0 0 1 queues 1@0 1@1 \
    base-time 200 \
    sched-entry S 80 250000 \
    sched-entry S 7F 750000 \
    clockid CLOCK_TAI flags 0x2
```

---

## 二、网络模拟器

### 2.1 sch_netem.c — NETEM (Network Emulator)

**模拟网络异常：延迟、丢包、重排序、重复、损坏。用于测试。**

```
功能:
  delay:       添加固定/随机延迟
  loss:        模拟丢包 (随机/Gilbert-Elliott 模型)
  duplicate:   随机重复包
  corrupt:     随机损坏包内容
  reorder:     随机打乱包顺序
  rate:        模拟低速链路
  slot:        模拟时隙发送

实现: 用 rbtree 按 "到达时间+延迟" 排序，timer 到期时 dequeue
```

```bash
# 添加 100ms 延迟 ± 10ms 抖动:
tc qdisc add dev eth0 root netem delay 100ms 10ms

# 1% 随机丢包:
tc qdisc add dev eth0 root netem loss 1%

# 组合: 100ms 延迟 + 0.5% 丢包 + 25% 重排序:
tc qdisc add dev eth0 root netem delay 100ms loss 0.5% reorder 25%

# 模拟 1Mbps 慢速链路:
tc qdisc add dev eth0 root netem rate 1mbit

# 模拟 Gilbert 突发丢包模型:
tc qdisc add dev eth0 root netem loss gemodel 1% 10% 70% 0.1%
```

---

## 三、特殊 Qdisc

### 3.1 sch_ingress.c — INGRESS (入方向)

```
不是真正的调度器，是入方向流量的"挂载点"
  用于在入方向做分类和动作 (cls + act)
  典型: 入方向限速、流量策略 (policing)
```

```bash
tc qdisc add dev eth0 ingress
tc filter add dev eth0 ingress protocol ip u32 \
    match ip src 10.0.0.0/8 action police rate 1mbit burst 100k
```

### 3.2 sch_blackhole.c — BLACKHOLE

```
丢弃所有包。用于调试或临时关闭接口流量。
```

### 3.3 sch_generic.c — 基础框架

```
不是用户可选的 qdisc，而是 TC 子系统的核心框架代码:
  - noqueue_qdisc: 无队列模式 (loopback 用)
  - noop_qdisc: 占位用
  - __dev_queue_xmit(): 发包入口 → qdisc->enqueue()
  - net_tx_action(): softirq 中处理发包完成
```

---

## 四、分类器 (cls_*.c)

分类器把包分配到不同的 class（配合有类 qdisc 使用）：

### 4.1 cls_u32.c — U32 分类器

```
最灵活的分类器: 按包头任意偏移处的值匹配

原理: 指定 offset 和 mask，与包内容做 AND 比较
```

```bash
# 匹配目的 IP 192.168.1.0/24:
tc filter add dev eth0 parent 1:0 protocol ip u32 \
    match ip dst 192.168.1.0/24 flowid 1:10

# 匹配目的端口 80:
tc filter add dev eth0 parent 1:0 protocol ip u32 \
    match ip dport 80 0xffff flowid 1:20

# 匹配 TOS 字段:
tc filter add dev eth0 parent 1:0 protocol ip u32 \
    match ip tos 0x10 0xff flowid 1:30
```

### 4.2 cls_flower.c — Flower 分类器

```
现代分类器: 类似流表 (flow table) 的匹配方式
支持: 5-tuple, VLAN, MPLS, 隧道, MAC 地址等
可以硬件卸载 (TC offload → NIC 硬件做分类)
```

```bash
# 匹配源 IP + 目的端口:
tc filter add dev eth0 protocol ip parent 1: \
    flower src_ip 10.0.0.1 ip_proto tcp dst_port 80 \
    action mirred egress redirect dev eth1

# 带 VLAN:
tc filter add dev eth0 protocol 802.1Q parent 1: \
    flower vlan_id 100 vlan_prio 5 \
    action pass
```

### 4.3 cls_bpf.c — BPF 分类器

```
用 eBPF 程序做分类: 最灵活，可以做任何逻辑
```

```bash
tc filter add dev eth0 parent 1: bpf obj my_classifier.o section classifier
```

### 4.4 cls_fw.c — FW (Firewall Mark)

```
根据 iptables/nftables 设置的 fwmark 分类
```

```bash
iptables -t mangle -A OUTPUT -p tcp --dport 80 -j MARK --set-mark 10
tc filter add dev eth0 parent 1: protocol ip handle 10 fw flowid 1:10
```

### 4.5 cls_matchall.c — 匹配所有

```
匹配所有包，通常配合 action 使用
```

```bash
tc filter add dev eth0 parent 1: matchall action police rate 100mbit burst 1m
```

---

## 五、Action (act_*.c)

Action 定义匹配后"做什么"：

| 文件 | Action | 功能 |
|------|--------|------|
| `act_police.c` | police | 限速 (令牌桶) |
| `act_mirred.c` | mirred | 重定向/镜像到另一接口 |
| `act_gact.c` | gact | 通用动作: pass/drop/continue |
| `act_skbedit.c` | skbedit | 修改 skb 字段 (priority, queue, mark) |
| `act_vlan.c` | vlan | 添加/删除/修改 VLAN tag |
| `act_nat.c` | nat | NAT |
| `act_pedit.c` | pedit | 修改包头任意字段 |
| `act_csum.c` | csum | 重新计算 checksum |
| `act_ct.c` | ct | 连接跟踪 (conntrack) |
| `act_gate.c` | gate | 时间门控 (802.1Qci) |
| `act_mpls.c` | mpls | MPLS 标签操作 |
| `act_tunnel_key.c` | tunnel_key | 隧道封装/解封装 |
| `act_bpf.c` | bpf | 运行 eBPF 程序 |
| `act_sample.c` | sample | 采样到 psample |

```bash
# 限速:
tc filter add dev eth0 parent 1: matchall \
    action police rate 10mbit burst 100k conform-exceed drop/continue

# 镜像到另一个接口:
tc filter add dev eth0 ingress flower src_ip 10.0.0.1 \
    action mirred egress mirror dev eth1

# 修改 VLAN:
tc filter add dev eth0 ingress protocol 802.1q flower vlan_id 100 \
    action vlan modify id 200
```

---

## 六、TC 完整流量控制体系

```
发包路径:
  应用 → socket → IP 层 → dev_queue_xmit()
                                │
                                ▼
                          ┌──────────────┐
                          │ root qdisc   │ (如 HTB)
                          │              │
                          │ ┌──────────┐ │
                          │ │ 分类器   │ │ (cls_flower/u32/bpf)
                          │ │ cls_*    │ │
                          │ └────┬─────┘ │
                          │      │       │
                          │ ┌────▼────┐  │
                          │ │ class 1 │  │ → 子 qdisc (如 fq_codel)
                          │ │ class 2 │  │ → 子 qdisc (如 netem)
                          │ │ class 3 │  │ → 子 qdisc (如 tbf)
                          │ └─────────┘  │
                          └──────┬───────┘
                                 │
                                 ▼
                          硬件 TX queue → 网线

收包路径:
  网线 → 硬件 RX → driver → ingress qdisc
                                │
                          ┌─────▼─────┐
                          │ cls + act │ (过滤+动作)
                          └─────┬─────┘
                                │
                                ▼
                          网络协议栈 → 应用
```

---

## 七、源文件分类总结

### Qdisc 调度器 (sch_*.c)

| 类别 | 文件 | 说明 |
|------|------|------|
| **基础** | sch_fifo, sch_prio, sch_tbf | FIFO/优先级/令牌桶 |
| **层次化** | sch_htb, sch_hfsc, sch_drr, sch_qfq | 层次限速/公平 |
| **AQM** | sch_red, sch_gred, sch_codel, sch_pie | 主动队列管理 |
| **公平** | sch_fq, sch_fq_codel, sch_cake, sch_sfq | 流隔离+公平 |
| **TSN** | sch_cbs, sch_etf, sch_taprio | 时间敏感网络 |
| **模拟** | sch_netem | 网络故障模拟 |
| **多队列** | sch_mq, sch_mqprio, sch_multiq | 硬件队列映射 |
| **其他** | sch_plug, sch_teql, sch_ingress, sch_blackhole | 特殊用途 |

### 分类器 (cls_*.c)

| 文件 | 匹配方式 |
|------|---------|
| cls_u32 | 包头偏移+mask |
| cls_flower | 流表式 (5-tuple, VLAN, tunnel) |
| cls_bpf | eBPF 程序 |
| cls_fw | iptables fwmark |
| cls_basic | 简单匹配 |
| cls_matchall | 匹配所有 |
| cls_route | 路由表 |
| cls_cgroup | cgroup |

### Action (act_*.c)

| 文件 | 动作 |
|------|------|
| act_police | 限速 |
| act_mirred | 重定向/镜像 |
| act_gact | pass/drop |
| act_skbedit | 修改 skb |
| act_vlan | VLAN 操作 |
| act_ct | conntrack |
| act_gate | 时间门控 |
| act_bpf | eBPF |
