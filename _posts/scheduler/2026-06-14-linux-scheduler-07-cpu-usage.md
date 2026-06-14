---
layout: post
title: "Linux 进程调度（七）：CPU 占用率统计"
date: 2026-06-14 22:00:00 +0800
excerpt: "分析 Linux 内核如何统计 CPU 占用率：采样式统计 (top/proc/stat) vs 精确式统计 (PELT/schedstat)，以及 /proc/stat、/proc/pid/stat 中各字段的含义。"
---

# Linux 进程调度（七）：CPU 占用率统计

---

## 一、两种统计方式

| 方式 | 精度 | 用在哪 |
|------|------|--------|
| 采样式（tick 采样） | 粗（1 tick 粒度） | `/proc/stat`、`top`、`htop` |
| 精确式（事件驱动） | 纳秒级 | schedstat、PELT 负载追踪 |

---

## 二、采样式统计：/proc/stat

### 2.1 原理

每个 tick（如 4ms），内核看当前 CPU 在干什么，给对应计数器 +1：

```c
// kernel/sched/cputime.c
void account_process_tick(struct task_struct *p, int user_tick)
{
    if (user_tick) {
        // 当前在用户态
        account_user_time(p, cputime);     // user +1
    } else if (p != rq->idle) {
        // 当前在内核态（非idle）
        account_system_time(p, cputime);   // system +1
    } else {
        // idle 进程
        account_idle_time(cputime);        // idle +1
    }
}
```

### 2.2 /proc/stat 字段

```bash
cat /proc/stat
cpu  10132 25 3042 851222 3151 0 127 0 0 0
#    user  nice sys  idle  iowait irq softirq steal guest guest_nice
```

| 字段 | 含义 |
|------|------|
| user | 用户态时间（不含 nice） |
| nice | nice>0 的用户态时间 |
| system | 内核态时间 |
| idle | 空闲时间 |
| iowait | 等待 IO 的空闲时间 |
| irq | 硬中断时间 |
| softirq | 软中断时间 |
| steal | 虚拟机被宿主机偷走的时间 |

### 2.3 top 怎么算 CPU 利用率

```
CPU% = (total - idle) / total × 100%

其中 total = user + nice + system + idle + iowait + irq + softirq + steal
```

top 每隔几秒读一次 /proc/stat，算两次之间的差值。

### 2.4 缺点

采样式精度低——如果一个进程恰好在每个 tick 时都没在运行，即使它实际跑了很多时间，也可能被统计为 0%。对于运行时间远小于 1 tick 的短进程，这个误差很大。

---

## 三、Per-进程统计：/proc/pid/stat

```bash
cat /proc/1234/stat
# ... 14th field: utime  (用户态 tick 数)
# ... 15th field: stime  (内核态 tick 数)
```

### 3.1 计算进程 CPU 利用率

```
进程 CPU% = (utime + stime) 的增量 / (total time 增量) × 100%

或者用时间：
进程 CPU% = (utime + stime) / (HZ × elapsed_seconds) × 100%
```

### 3.2 /proc/pid/schedstat（精确统计）

```bash
cat /proc/1234/schedstat
# run_time  wait_time  nr_switches
# 123456789 456789     2000
```

| 字段 | 含义 |
|------|------|
| run_time | 实际运行时间（纳秒） |
| wait_time | 在 rq 上等待的时间（纳秒） |
| nr_switches | 上下文切换次数 |

这个是纳秒级精确的，不依赖 tick 采样。

---

## 四、PELT：Per-Entity Load Tracking

### 4.1 什么是 PELT

PELT 是调度器内部用来追踪每个进程（和每个 cfs_rq）负载的机制。它不是给用户看的，而是给 **负载均衡** 用的。

### 4.2 原理

将时间分成 1ms（1024μs）的窗口，每个窗口中进程是否在 running/runnable：

```
时间窗口:  [1] [2] [3] [4] [5] [6] [7] [8] ...
进程运行:   ✓   ✓   ✗   ✓   ✗   ✗   ✓   ✓

负载 = 加权衰减的历史之和
     = 当前窗口 + 上一窗口×衰减系数 + 上上窗口×衰减系数² + ...
```

衰减公式：
```
load = Σ (contribution_i × decay^i)
decay = (2^32 - 1) / 2^32 per 32ms ≈ 半衰期 32ms
```

### 4.3 PELT 追踪的指标

每个 sched_entity 追踪：

| 指标 | 含义 |
|------|------|
| `load_avg` | 负载贡献（考虑权重） |
| `runnable_avg` | 可运行占比 |
| `util_avg` | 实际 CPU 利用率（0~1024） |

```c
struct sched_avg {
    u64 last_update_time;
    u64 load_sum;
    u64 runnable_sum;
    u64 util_sum;
    u32 load_avg;      // 加权负载
    u32 runnable_avg;  // 可运行占比
    u32 util_avg;      // CPU 利用率 (0~1024 对应 0~100%)
};
```

### 4.4 举例

进程持续运行不睡眠：
```
util_avg 逐渐趋近 1024（100%）
经过几百毫秒稳定在 1024
```

进程运行 50% 睡眠 50%：
```
util_avg 稳定在 ~512（50%）
```

### 4.5 PELT 的用途

- **负载均衡**：决定把进程迁到哪个 CPU
- **DVFS (频率调节)**：`schedutil` 调频策略直接用 `util_avg` 决定 CPU 频率
- **EAS (Energy Aware Scheduling)**：决定放大核还是小核

---

## 五、各工具使用的数据源

| 工具 | 数据源 | 精度 |
|------|--------|------|
| top / htop | /proc/stat + /proc/pid/stat | tick 级 |
| perf | 硬件 PMU 计数器 | 精确 |
| schedstat | /proc/pid/schedstat | 纳秒 |
| sar | /proc/stat 定期采样 | tick 级 |
| cgroup cpu.stat | CFS bandwidth 统计 | 精确 |
| schedutil (DVFS) | PELT util_avg | 1ms 窗口 |

---

## 六、实战：判断进程是 CPU 受限还是等待受限

```bash
cat /proc/1234/schedstat
# run_time=5000000000  wait_time=3000000000  switches=10000

# run_time = 5s，wait_time = 3s
# 说明进程 8s 中有 5s 在运行，3s 在 rq 上等待
# → 存在 CPU 竞争，可能需要提高优先级或迁移到空闲 CPU
```

```bash
cat /proc/1234/sched | grep wait
# se.statistics.wait_sum : 3000000000
# se.statistics.wait_max : 50000000  (最大一次等待 50ms)
# se.statistics.wait_count : 10000
```

---

## 七、总结

| 统计方式 | 精度 | 开销 | 用途 |
|----------|------|------|------|
| tick 采样 (/proc/stat) | 粗 (ms) | 极低 | 系统概览 |
| schedstat | 精确 (ns) | 低 | 调试单进程延迟 |
| PELT | 1ms 窗口+衰减 | 调度器内部 | 负载均衡、DVFS |
| perf/PMU | 精确 | 中 | 性能分析 |

---

下一篇：[Linux 进程调度（八）：SMP 负载均衡]
