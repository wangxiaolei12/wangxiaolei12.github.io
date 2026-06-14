---
layout: post
title: "Linux 进程调度（六）：sched sysctl 参数详解"
date: 2026-06-14 21:30:00 +0800
excerpt: "详解 Linux 调度器可调参数：CFS/EEVDF 的 base_slice、RT 的 period/runtime/timeslice、负载均衡相关参数，以及如何根据场景调优。"
---

# Linux 进程调度（六）：sched sysctl 参数详解

所有参数位于 `/proc/sys/kernel/` 下。

---

## 一、CFS/EEVDF 相关参数

### 1.1 sched_base_slice_ns（新内核 EEVDF）

```bash
cat /proc/sys/kernel/sched_base_slice_ns
# 默认: 700000 (0.7ms)
```

| 项目 | 说明 |
|------|------|
| 含义 | 每个进程的基础时间片（虚拟时间） |
| 值大 | 进程每次运行更久，切换少，吞吐高，延迟大 |
| 值小 | 切换频繁，延迟低，吞吐略降 |
| 典型调优 | 服务器调大(3ms)，低延迟场景调小(0.3ms) |

### 1.2 老 CFS 参数（仍可能存在于某些内核版本）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `sched_latency_ns` | 6ms | 调度周期（所有进程跑一轮的目标时间） |
| `sched_min_granularity_ns` | 0.75ms | 最小时间片（进程数多时不会低于此值） |
| `sched_wakeup_granularity_ns` | 1ms | 唤醒抢占门槛（vruntime 差值超过此值才抢占） |
| `sched_nr_latency` | 8 | 当进程数 > 此值时，调度周期 = nr × min_granularity |

### 1.3 举例：sched_latency 的效果

```
sched_latency = 6ms, 3 个相同权重的进程：
  每个进程时间片 = 6ms / 3 = 2ms
  → 每个进程每 6ms 能跑 2ms

sched_latency = 24ms：
  每个进程时间片 = 24ms / 3 = 8ms
  → 每个进程运行更久，切换更少
  → 吞吐更好，但交互响应更慢
```

---

## 二、RT 调度相关参数

### 2.1 sched_rt_period_us

```bash
cat /proc/sys/kernel/sched_rt_period_us
# 默认: 1000000 (1秒)
```

RT 带宽统计的周期。

### 2.2 sched_rt_runtime_us

```bash
cat /proc/sys/kernel/sched_rt_runtime_us
# 默认: 950000 (0.95秒)
```

| 值 | 效果 |
|---|------|
| 950000 | RT 每秒最多跑 950ms，CFS 保证 50ms |
| -1 | 无限制（RT 可以饿死 CFS，危险！） |
| 0 | RT 完全不允许运行（测试用） |

### 2.3 sched_rr_timeslice_ms

```bash
cat /proc/sys/kernel/sched_rr_timeslice_ms
# 默认: 100
```

SCHED_RR 进程的时间片。设为 0 则使用 `RR_TIMESLICE` 默认值。

### 2.4 举例：调整 RT throttling

```bash
# 场景：音频系统需要更多 RT 时间，但仍保留 CFS 余量
echo 980000 > /proc/sys/kernel/sched_rt_runtime_us
# RT 每秒可用 980ms，CFS 保留 20ms

# 场景：嵌入式实时系统，确信 RT 不会有 bug
echo -1 > /proc/sys/kernel/sched_rt_runtime_us
# 完全禁用 throttling
```

---

## 三、负载均衡相关参数

### 3.1 sched_migration_cost_ns

```bash
cat /proc/sys/kernel/sched_migration_cost_ns
# 默认: 500000 (0.5ms)
```

| 说明 | 效果 |
|------|------|
| 如果进程上次运行的时间 < 此值，认为它的 cache 还是热的 | 不迁移 |
| 值大 | 减少迁移，cache 友好，但负载可能不均衡 |
| 值小 | 更积极迁移，均衡好，但 cache miss 多 |

### 3.2 sched_nr_migrate

```bash
cat /proc/sys/kernel/sched_nr_migrate
# 默认: 32
```

每次负载均衡最多迁移多少个进程。值大均衡更快但中断延迟大。

### 3.3 sched_autogroup_enabled

```bash
cat /proc/sys/kernel/sched_autogroup_enabled
# 默认: 1
```

自动将同一 session 的进程分组。效果：在终端编译内核时，桌面交互不卡。

---

## 四、调试/统计相关

### 4.1 sched_debug

```bash
cat /proc/sys/kernel/sched_debug
# 或
cat /proc/sched_debug
```

输出所有 CPU 的 rq 状态、每个进程的调度信息。

### 4.2 sched_schedstats

```bash
echo 1 > /proc/sys/kernel/sched_schedstats
cat /proc/schedstat
```

开启后可看到每个 CPU 的调度统计（上下文切换次数、等待时间等）。

---

## 五、参数调优速查表

| 场景 | 调整 |
|------|------|
| 服务器（吞吐优先） | `sched_base_slice_ns` 调大、`sched_migration_cost_ns` 调大 |
| 桌面（交互优先） | `sched_base_slice_ns` 调小、开启 `sched_autogroup_enabled` |
| 实时嵌入式 | `sched_rt_runtime_us=-1`、使用 PREEMPT_RT |
| 容器/云 | 通过 cgroup `cpu.max` 控制，不改全局参数 |
| 大量短任务 | `sched_nr_migrate` 调大、`sched_migration_cost_ns` 调小 |
| HPC 计算密集 | `sched_base_slice_ns` 调大(5ms+)、绑核（taskset） |

---

## 六、查看当前进程的调度信息

```bash
# 查看某进程的调度详情
cat /proc/<pid>/sched

# 输出示例：
# se.vruntime          : 12345.678
# se.slice             : 0.700
# nr_switches          : 4567
# nr_voluntary_switches: 3000
# nr_involuntary_switches: 1567
# policy               : 0 (SCHED_NORMAL)
# prio                 : 120 (nice=0)
```

---

## 七、总结

```
/proc/sys/kernel/
├── sched_base_slice_ns          ← EEVDF 时间片
├── sched_rt_period_us           ← RT 带宽周期
├── sched_rt_runtime_us          ← RT 每周期最大运行时间
├── sched_rr_timeslice_ms        ← RR 时间片
├── sched_migration_cost_ns      ← 迁移代价门槛
├── sched_nr_migrate             ← 每次均衡最大迁移数
├── sched_autogroup_enabled      ← 自动分组
└── sched_schedstats             ← 调度统计开关
```

---

下一篇：[Linux 进程调度（七）：CPU 占用率统计]
