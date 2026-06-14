---
layout: post
title: "Linux 进程调度（五）：CFS Bandwidth Control"
date: 2026-06-14 21:00:00 +0800
excerpt: "分析 CFS 带宽控制机制：如何限制一组进程的 CPU 使用量（quota/period），throttle/unthrottle 流程，以及与 cgroup 的配合。典型应用场景：容器 CPU 限制。"
---

# Linux 进程调度（五）：CFS Bandwidth Control

---

## 一、CFS Bandwidth 解决什么问题

CFS 保证"公平"，但不能"限制"。假设你有一个容器：
- CFS 保证它和其他进程公平竞争
- 但如果系统空闲，容器能用完 100% CPU

**CFS Bandwidth Control** 允许你说："不管系统多空闲，这组进程每 100ms 最多只能用 50ms CPU"。

这是 **容器 CPU 限制** 的核心机制（Docker `--cpus=0.5` 底层就靠它）。

---

## 二、核心概念：quota 和 period

```
period = 100ms（统计周期）
quota  = 50ms （该组每个 period 内最多使用的 CPU 时间）

效果：CPU 使用率上限 = quota / period = 50%
```

### 配置方式（cgroup v2）

```bash
# 限制 cgroup 每 100ms 最多用 50ms CPU
echo "50000 100000" > /sys/fs/cgroup/my_group/cpu.max
#       quota  period（单位：微秒）
```

### cgroup v1

```bash
echo 100000 > /sys/fs/cgroup/cpu/my_group/cpu.cfs_period_us
echo 50000  > /sys/fs/cgroup/cpu/my_group/cpu.cfs_quota_us
```

---

## 三、工作原理

### 3.1 全局 bandwidth 池

每个 task_group 有一个全局的 bandwidth 结构：

```c
struct cfs_bandwidth {
    ktime_t period;          // 统计周期（默认 100ms）
    u64 quota;               // 每周期分配的 CPU 时间
    u64 runtime;             // 当前周期剩余可用时间
    int nr_throttled;        // 被 throttle 的 cfs_rq 数量
    struct hrtimer period_timer;  // 周期性补充定时器
};
```

### 3.2 Per-CPU 的 runtime slice

全局 quota 被分片到各 CPU 的 cfs_rq：

```
全局 quota = 50ms

CPU0 的 cfs_rq: 分到 5ms slice
CPU1 的 cfs_rq: 分到 5ms slice
...

用完本地 slice 后向全局池申请更多
全局池也用完 → throttle！
```

### 3.3 Throttle 流程

```
update_curr() 
  → account_cfs_rq_runtime(cfs_rq, delta_exec)
    → cfs_rq->runtime_remaining -= delta_exec
    → if (runtime_remaining <= 0)
      → assign_cfs_rq_runtime()  // 尝试从全局池补充
        → if (全局 runtime 也用完了)
          → throttle_cfs_rq(cfs_rq)  // Throttle!
            → 将该 cfs_rq 从调度树上摘除
            → 进程无法被选中运行
```

### 3.4 Unthrottle 流程

全局 period_timer 到期时（每个 period 一次）：

```
period_timer 回调:
  → __refill_cfs_bandwidth_runtime()
    → bw->runtime = bw->quota  // 补充全局 quota
  → distribute_cfs_runtime()
    → 遍历所有被 throttle 的 cfs_rq
    → 给它们分配 runtime
    → unthrottle_cfs_rq()
      → 重新入队，可以再次被调度
```

---

## 四、举例：完整的 throttle/unthrottle 过程

设置：period=100ms, quota=20ms，只有 1 个 CPU。

```
时间线:

0ms                  20ms                                100ms
├─── 进程运行 ────────┤── throttled（不能运行）────────────┤
                      ↑                                   ↑
               quota 用完                          period_timer 到期
               throttle_cfs_rq()                  refill runtime=20ms
                                                  unthrottle_cfs_rq()
                                                  进程恢复运行
├─── 进程运行 ────────┤── throttled ──────────────────────┤
100ms               120ms                               200ms
```

**结果**：进程每 100ms 只能运行 20ms，实际 CPU 利用率 = 20%。

---

## 五、burst 机制（Linux 5.14+）

### 5.1 问题

严格的 quota 限制会导致延迟尖刺：进程在 20ms 时被 throttle，必须等到 100ms 才能恢复——等待 80ms！

### 5.2 解决：允许 burst

```bash
# 允许临时 burst 额外 10ms
echo "20000 100000 10000" > /sys/fs/cgroup/my_group/cpu.max
#     quota  period  burst
```

burst 允许进程在某个 period 内超用 quota（从"存款"中借），只要长期平均不超标。就像手机流量的"结转"。

---

## 六、多 CPU 场景

quota=50ms, period=100ms, 4 个 CPU：

```
不是说只能用 50ms 的"一个 CPU 时间"！
而是 4 个 CPU 上总共最多 50ms。

如果进程只跑在 1 个 CPU 上：最多 50% 利用率
如果进程分布在 4 个 CPU 上：每个 CPU 最多 12.5%
```

如果想限制为 2 个 CPU 的等价算力：
```bash
echo "200000 100000" > cpu.max  # quota=200ms，相当于 2 个 CPU
```

---

## 七、与 Docker/K8s 的关系

```yaml
# Docker
docker run --cpus=1.5 my_image
# → period=100ms, quota=150ms（1.5 个 CPU）

# Kubernetes
resources:
  limits:
    cpu: "500m"  # 0.5 CPU
# → period=100ms, quota=50ms
```

当容器内进程 quota 用完被 throttle 时：
- 容器表现为"CPU 被限制"
- `cat /sys/fs/cgroup/.../cpu.stat` 能看到 `nr_throttled` 和 `throttled_time`

---

## 八、调试：如何知道是否被 throttle

```bash
# cgroup v2
cat /sys/fs/cgroup/my_group/cpu.stat
# usage_usec 12345678
# nr_periods 1000
# nr_throttled 200       ← 被 throttle 了 200 次
# throttled_usec 8000000 ← 总共被 throttle 了 8 秒

# cgroup v1
cat /sys/fs/cgroup/cpu/my_group/cpu.stat
```

如果 `nr_throttled` 持续增长，说明 quota 给少了，进程在挨饿。

---

## 九、源码关键函数

| 函数 | 作用 |
|------|------|
| `account_cfs_rq_runtime()` | 每次 update_curr 时扣减本地 runtime |
| `assign_cfs_rq_runtime()` | 本地用完后从全局池补充 |
| `throttle_cfs_rq()` | 将 cfs_rq 从调度树摘除 |
| `unthrottle_cfs_rq()` | 恢复 cfs_rq 到调度树 |
| `sched_cfs_period_timer()` | 周期定时器，补充 quota |
| `distribute_cfs_runtime()` | 将补充的 quota 分发到各 CPU |

---

## 十、总结

| 概念 | 说明 |
|------|------|
| period | 统计周期，默认 100ms |
| quota | 每周期允许的 CPU 时间 |
| throttle | quota 用完后暂停该组进程 |
| unthrottle | 下个 period 开始时恢复 |
| burst | 允许临时超用，长期不超标 |
| 典型用户 | Docker/K8s 的 CPU 限制 |

**CFS Bandwidth = CFS 公平调度之上的"硬限制"层。CFS 决定组内谁先跑，Bandwidth 决定组总共能跑多少。**

---

下一篇：[Linux 进程调度（六）：sched sysctl 参数]
