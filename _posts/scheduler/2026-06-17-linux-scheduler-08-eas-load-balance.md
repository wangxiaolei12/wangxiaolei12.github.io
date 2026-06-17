---
layout: post
title: "Linux 进程调度（八）：EAS 能效感知调度与负载均衡"
date: 2026-06-17 11:00:00 +0800
excerpt: "深入分析 Energy Aware Scheduling (EAS) 的设计原理与源码实现：为什么需要 EAS、Performance Domain 与 Energy Model、find_energy_efficient_cpu() 逐行解读、能耗公式的物理推导、关键魔数 1024/1280 的含义，以及 EAS 与传统负载均衡的切换机制。基于 mainline kernel/sched/fair.c 源码。"
---

# Linux 进程调度（八）：EAS 能效感知调度与负载均衡

基于 mainline `kernel/sched/fair.c`、`kernel/sched/topology.c`、`include/linux/energy_model.h` 源码分析

---

## 一、为什么需要 EAS？

传统 CFS 负载均衡的目标是**公平分配负载**——让每个 CPU 尽量均匀地分担任务。但在 ARM big.LITTLE 异构系统上，这个策略存在盲区：

```
小核 (LITTLE): 算力低，功耗低
大核 (big):    算力高，功耗高
```

一个轻量任务（比如 `util=100`）放到大核上能跑，放到小核上也能跑。传统负载均衡可能把它放到大核上（因为大核更空闲），但这会白白浪费能量。

**EAS 的核心思想：在"任务能跑得动"的前提下，选一个让整个系统能耗最小的 CPU。**

EAS 的能量节约主要来源于系统的**非对称性**（asymmetry），而不是在相同 CPU 之间打破平衡。这也是为什么 EAS 只在设置了 `SD_ASYM_CPUCAPACITY` 的异构系统上启用。

---

## 二、EAS 启用条件

源码位于 `kernel/sched/topology.c`：

```c
/*
 * EAS can be used on a root domain if it meets all the following conditions:
 *    1. an Energy Model (EM) is available;
 *    2. the SD_ASYM_CPUCAPACITY flag is set in the sched_domain hierarchy.
 *    3. no SMT is detected.
 *    4. schedutil is driving the frequency of all CPUs of the rd;
 *    5. frequency invariance support is present;
 */
static bool build_perf_domains(const struct cpumask *cpu_map)
```

| 条件 | 含义 | 为什么需要 |
|------|------|------------|
| Energy Model | DTS/ACPI 提供各频点功耗数据 | 没有功耗数据就无法计算能耗 |
| SD_ASYM_CPUCAPACITY | 异构 CPU 拓扑（大小核） | 同构系统放哪个 CPU 能耗一样，EAS 没意义 |
| 无 SMT | 不支持超线程 | SMT 共享执行资源，能耗模型不适用 |
| schedutil | 必须用 schedutil 调频策略 | EAS 假设频率跟随利用率，其他 governor 不保证 |
| freq invariant | 架构支持频率不变性追踪 | 利用率需要被频率归一化，否则数值没有可比性 |

---

## 三、核心概念：SCHED_CAPACITY_SCALE = 1024

```c
// include/linux/sched.h
#define SCHED_FIXEDPOINT_SHIFT  10
#define SCHED_CAPACITY_SCALE    (1L << SCHED_FIXEDPOINT_SHIFT)  // = 1024
```

### 为什么是 1024？

调度器需要表示"百分比"概念（0%~100%），但内核不用浮点数。所以采用**定点数**表示：

- **1024** 代表 100%（CPU 满容量）
- **512** 代表 50%
- **0** 代表 0%

选 1024（= 2^10）的原因：
1. **效率**：2 的幂次方，乘除可用移位操作，比通用除法快得多
2. **精度**：1/1024 ≈ 0.1%，足够调度器使用

所以在代码中看到 `p_util_max = 1024`，意思就是"任务不受任何容量限制（上限为 100%）"。

---

## 四、Performance Domain 与 Energy Model

### 4.1 Performance Domain (PD)

```c
// kernel/sched/sched.h
struct perf_domain {
    struct em_perf_domain *em_pd;
    struct perf_domain *next;    // 链表，连接所有 PD
    struct rcu_head rcu;
};
```

**相同微架构**的 CPU 组成一个 Performance Domain，同一 PD 内所有 CPU **共享频点**。

```
  PD0 (小核 LITTLE)           PD1 (大核 big)
  ┌─────┬─────┬─────┬─────┐ ┌─────┬─────┬─────┬─────┐
  │CPU0 │CPU1 │CPU2 │CPU3 │ │CPU4 │CPU5 │CPU6 │CPU7 │
  │cap:  │cap:  │cap:  │cap:  │ │cap:  │cap:  │cap:  │cap:  │
  │512  │512  │512  │512  │ │1024 │1024 │1024 │1024 │
  └─────┴─────┴─────┴─────┘ └─────┴─────┴─────┴─────┘
     共享频率: 1GHz              共享频率: 2.2GHz
     power: low                  power: high
```

**关键特性：同一 PD 内的频点由最忙的那个 CPU 决定。** 这是理解 EAS 所有启发式策略的基础。

### 4.2 Energy Model (EM)

EM 将每个 PD 的频点-容量-功耗关系组织为一张表：

```
小核 PD 的 EM 表：
  ┌──────────┬────────────┬────────┬──────────────────────┐
  │ 频点(MHz) │ capacity  │ power  │ cost (预计算)         │
  ├──────────┼────────────┼────────┼──────────────────────┤
  │ 600      │ 307       │ 50mW   │ 50×1000/(600×512)=163│
  │ 800      │ 410       │ 100mW  │ 100×1000/(800×512)=244│
  │ 1000     │ 512       │ 200mW  │ 200×1000/(1000×512)=391│
  └──────────┴────────────┴────────┴──────────────────────┘
```

`cost` 的含义后面详细推导。

---

## 五、EAS 入口：何时进入能效路径？

```c
// kernel/sched/fair.c:8850 select_task_rq_fair()
if (!is_rd_overutilized(this_rq()->rd)) {
    new_cpu = find_energy_efficient_cpu(p, prev_cpu);
    if (new_cpu >= 0)
        return new_cpu;
    new_cpu = prev_cpu;
}
```

### is_rd_overutilized() —— EAS 的门控开关

```c
static inline bool is_rd_overutilized(struct root_domain *rd)
{
    return !sched_energy_enabled() || READ_ONCE(rd->overutilized);
}
```

- EAS 未启用 → 返回 true → 走传统负载均衡
- 系统过载 → 返回 true → 走传统负载均衡
- **只有系统未过载时，才走 EAS 路径**

### 为什么超载时要退出 EAS？

```c
static inline bool cpu_overutilized(int cpu)
{
    unsigned long rq_util_max = uclamp_rq_get(cpu_rq(cpu), UCLAMP_MAX);
    return !util_fits_cpu(cpu_util_cfs(cpu), 0, rq_util_max, cpu);
}
```

底层判断宏：

```c
#define fits_capacity(cap, max)  ((cap) * 1280 < (max) * 1024)
```

**数学含义：**

```
cap × 1280 < max × 1024
等价于: cap < max × (1024/1280) = max × 0.8
```

即：**利用率必须低于容量的 80% 才认为"fit"（不超载）。**

```
   CPU capacity
   ┌───────────────────────────┐ 1024 (100%)
   │     headroom (20%)        │
   ├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤ ~819 (80%)
   │                           │
   │    利用率在这里才算 "fit"   │
   │                           │
   └───────────────────────────┘ 0
```

**为什么是 80% 阈值（20% 余量）？**

PELT（Per-Entity Load Tracking）追踪的是利用率的**指数加权平均值**，任务实际运行中会有突发（burst）。如果 CPU 用到 100% 才算超载，任何一个小突发就会导致跑不完，产生调度延迟。20% 是内核社区的经验值。

**为什么用 1280 和 1024 而不是直接除以 1.25？**

`1280 = 1024 × 1.25`，用整数乘法替代浮点除法：
- 内核禁止浮点运算
- 整数乘法在所有架构上都极快
- 无精度损失

**为什么超载时 EAS 策略失效？**

假设小核 cluster 中 CPU3 已经超载（跑满），那无论把新任务放到哪个小核上，小核 cluster 都必须维持**最高频点**。此时 EAS 的核心策略——"通过选择不同 CPU 来改变频点从而省电"——就**完全失效**了。放哪里频点都一样高，能耗估算不公平。所以超载时回退到传统负载均衡，追求性能和公平。

---

## 六、find_energy_efficient_cpu() 核心逻辑

### 6.1 整体流程

```
find_energy_efficient_cpu(p, prev_cpu)
│
├── 1. 检查 perf_domain 链表是否存在
├── 2. 找到覆盖 prev_cpu 的 sd_asym_cpucapacity 调度域
├── 3. task_util_est==0 且无 uclamp_min → 直接返回 prev_cpu
├── 4. 计算 task_busy_time（任务自身的忙碌时间）
│
├── 5. 遍历每个 Performance Domain (PD):
│   ├── 对 PD 中每个 CPU:
│   │   ├── 跳过不在调度域范围的 CPU
│   │   ├── 跳过不在 cpus_allowed 的 CPU
│   │   ├── util_fits_cpu() 检查能否放下
│   │   ├── 记录 prev_cpu 的 spare_cap
│   │   └── 找到 max_spare_cap_cpu
│   │
│   ├── compute_energy(dst=-1): 基准能耗
│   ├── compute_energy(dst=prev_cpu): prev 能耗增量
│   └── compute_energy(dst=best_cpu): best 能耗增量
│
└── 6. 最终比较，选能耗最低的 CPU 返回
```

### 6.2 为什么 util 为 0 的任务直接返回 prev_cpu？

```c
sync_entity_load_avg(&p->se);
if (!task_util_est(p) && p_util_min == 0)
    return target;  // target = prev_cpu
```

如果任务的利用率估计为 0（比如刚创建或者长时间睡眠刚醒），放到哪个 CPU 上对能耗的影响几乎为零。与其花大量时间遍历所有 PD 计算能耗，不如直接留在原 CPU——**零成本决策，避免无谓的唤醒延迟**。

### 6.3 为什么选"最大剩余容量"的 CPU 作为候选？

```c
for_each_cpu(cpu, cpus) {
    util = cpu_util(cpu, p, cpu, 0);
    cpu_cap = capacity_of(cpu);

    fits = util_fits_cpu(util, util_min, util_max, cpu);
    if (!fits)
        continue;

    lsub_positive(&cpu_cap, util);  // spare_cap = capacity - util

    if ((fits > max_fits) ||
        ((fits == max_fits) && ((long)cpu_cap > max_spare_cap))) {
        max_spare_cap = cpu_cap;
        max_spare_cap_cpu = cpu;
        max_fits = fits;
    }
}
```

**核心原因：同一 PD 的频点由最忙的 CPU 决定。**

举例说明：

```
小核 PD，capacity=512:
  CPU0: util=400 (最忙)
  CPU1: util=200
  CPU2: util=100 ← 最闲（max_spare_cap）
  CPU3: util=300

当前频点由 CPU0 的 util=400 决定 → 选 800MHz
```

如果把新任务（util=150）放到 CPU0 → util 变成 550 > 512 → 必须升频到 1GHz → 整个 cluster 功耗大增！

如果放到 CPU2 → util 变成 250，max_util 仍然是 CPU0 的 400 → **频点不变** → 功耗增量极小。

**这就是"选最大剩余容量 CPU"的直觉：避免成为 PD 中最忙的 CPU，避免触发升频。**

**为什么不对每个 CPU 都做精确能耗计算？**

因为 `compute_energy()` 需要遍历 PD 中所有 CPU 累加利用率，调用 EM 查表等——开销不小。一个 PD 有 4 个 CPU，系统有 3 个 PD 就是 12 次计算，在唤醒热路径上不可接受。所以用**启发式预筛选**：每个 PD 只选一个最佳候选，再对少数几个候选做精确能耗比较。

### 6.4 eenv_task_busy_time —— 为什么要做 IRQ 缩放？

```c
static inline void eenv_task_busy_time(struct energy_env *eenv,
                       struct task_struct *p, int prev_cpu)
{
    unsigned long busy_time, max_cap = arch_scale_cpu_capacity(prev_cpu);
    unsigned long irq = cpu_util_irq(cpu_rq(prev_cpu));

    if (unlikely(irq >= max_cap))
        busy_time = max_cap;
    else
        busy_time = scale_irq_capacity(task_util_est(p), irq, max_cap);

    eenv->task_busy_time = busy_time;
}
```

CPU 的一部分时间被中断（IRQ）占用，这段时间是"不可调度"的。相当于 CPU 的有效容量被缩减了。

```
  CPU 总时间
  ┌────────────────────────────────┐
  │  IRQ 时间  │   可调度时间       │
  └────────────────────────────────┘
               ↑
         任务只能在这部分运行
```

任务的 `task_util_est` 是在"可调度时间"中度量的，但能耗计算需要在"CPU 总时间"的尺度上。因此需要缩放：

```
                        max_cap - irq
real_busy_time = util × ─────────────
                            max_cap
```

### 6.5 eenv_pd_busy_time —— 为什么要排除任务 p？

```c
static inline void eenv_pd_busy_time(struct energy_env *eenv,
                     struct cpumask *pd_cpus, struct task_struct *p)
{
    unsigned long busy_time = 0;
    int cpu;

    for_each_cpu(cpu, pd_cpus) {
        unsigned long util = cpu_util(cpu, p, -1, 0);  // 排除 p 的贡献
        busy_time += effective_cpu_util(cpu, util, NULL, NULL);
    }
    eenv->pd_busy_time = min(eenv->pd_cap, busy_time);
}
```

`cpu_util(cpu, p, -1, 0)` 中参数 `p` 的作用是**从 cpu 的利用率中减去任务 p 的贡献**。

**为什么要这样做？** 因为我们要计算的是：

```
base_energy = 不含任务 p 时 PD 的能耗
delta       = 把 p 放到某个 CPU 后的能耗 - base_energy
```

如果 base 里已经包含了 p 的负载（p 之前就在 prev_cpu 上运行过），再通过 `task_busy_time` 加回去就重复计算了。把 p 摘出来再单独加回，保证了**不同候选 CPU 之间的公平比较**——无论 p 之前在哪个 CPU，base_energy 都是一样的。

---

## 七、能耗计算公式的物理推导

这是 EAS 最核心的部分。源码位于 `include/linux/energy_model.h` 的 `em_cpu_energy()`。

### 7.1 从物理出发

**问题：** 一个 CPU 在频点 f 下，利用率为 util，它消耗多少能量？

**第一步：确定运行时间比例**

CPU 不是 100% 时间都在跑任务（超载时 EAS 不使能），它有 idle 时间。运行比例（busy ratio）是：

```
                 cpu_util
busy_ratio = ─────────────────
              performance(f)
```

其中 `performance(f)` 是该频点下的 CPU 算力（capacity）。

**为什么是这个比值？** `util` 代表"任务需要的计算量"，`performance` 代表"CPU 每单位时间能提供的计算量"。二者之比就是 CPU 被占用的时间比例。

**第二步：单个 CPU 能耗**

忽略 idle 功耗（EM 不包含 idle 功耗数据），能耗 = 功率 × 运行时间：

```
                      cpu_util
cpu_energy = power(f) × ─────────────────
                      performance(f)
```

**第三步：展开 performance**

`performance(f)` 是归一化的 capacity：

```
                   freq(f) × scale_cpu
performance(f) = ─────────────────────────
                       cpu_max_freq
```

`scale_cpu` = 该 CPU 类型的最大归一化容量（相对全系统最强核），`cpu_max_freq` = 该 CPU 的最高频率。

**第四步：代入整理**

```
               power(f) × cpu_max_freq
cpu_energy = ─────────────────────────── × cpu_util
                freq(f) × scale_cpu
```

前面这一大坨对于给定频点 f 和给定 CPU 类型是**常量**，内核在 EM 初始化时预计算好，存为 `ps->cost`：

```c
// 预计算值
ps->cost = power × cpu_max_freq / (freq × scale_cpu)
```

**第五步：整个 PD 的能耗**

同一 PD 内所有 CPU 微架构相同、运行在相同频点，所以 `ps->cost` 完全一样。整个 PD 的能耗就是各 CPU 能耗之和：

```
pd_energy = ps->cost × (util_cpu0 + util_cpu1 + ... + util_cpuN)
          = ps->cost × sum_util
```

### 7.2 源码实现

```c
// include/linux/energy_model.h
static inline unsigned long em_cpu_energy(struct em_perf_domain *pd,
            unsigned long max_util, unsigned long sum_util,
            unsigned long allowed_cpu_cap)
{
    // ... 省略 lockdep 检查 ...
    if (!sum_util)
        return 0;

    // 限制 max_util 不超过允许的容量（如热限制）
    max_util = min(max_util, allowed_cpu_cap);

    // 根据 max_util 找到满足需求的最低频点
    em_table = rcu_dereference_all(pd->em_table);
    i = em_pd_get_efficient_state(em_table->state, pd, max_util);
    ps = &em_table->state[i];

    // 最终公式
    return ps->cost * sum_util;
}
```

### 7.3 max_util 的作用

`max_util` 不参与最终乘法，它用来**选择频点**。

为什么？因为同一 PD 的所有 CPU 共享一个频率，这个频率必须满足**最忙那个 CPU** 的算力需求。所以用 PD 中各 CPU 的最大利用率去查 EM 表，找到刚好能满足该利用率的最低频点。

频点越低 → `ps->cost` 越小 → 能耗越低。**这正是 EAS 省电的核心机制：通过合理放置任务，让 PD 能用更低的频点。**

### 7.4 直觉总结

```
PD 能耗 = 选定频点的单位能耗系数 × 所有 CPU 利用率之和
           ─────────────────────     ─────────────────────
           由最忙 CPU (max_util)     所有 CPU 的忙碌程度总量
           决定选哪个频点             决定总工作量
```

---

## 八、compute_energy() —— 把公式应用到实际场景

```c
static inline unsigned long
compute_energy(struct energy_env *eenv, struct perf_domain *pd,
           struct cpumask *pd_cpus, struct task_struct *p, int dst_cpu)
{
    unsigned long max_util = eenv_pd_max_util(eenv, pd_cpus, p, dst_cpu);
    unsigned long busy_time = eenv->pd_busy_time;

    if (dst_cpu >= 0)
        busy_time = min(eenv->pd_cap, busy_time + eenv->task_busy_time);

    energy = em_cpu_energy(pd->em_pd, max_util, busy_time, eenv->cpu_cap);
    return energy;
}
```

**参数含义：**

| 参数 | 含义 |
|------|------|
| `dst_cpu = -1` | 不放置任务 p，计算 PD 的基准能耗 |
| `dst_cpu >= 0` | 假设把任务 p 放到 dst_cpu，计算新能耗 |
| `eenv->pd_busy_time` | PD 所有 CPU 的总利用率（已排除 p） |
| `eenv->task_busy_time` | 任务 p 自身的忙碌时间 |
| `eenv->pd_cap` | PD 的总容量（nr_cpus × cpu_cap），用作 sum_util 的上界 |

**流程：**
1. 当 `dst_cpu = -1`：sum_util = pd_busy_time（不含 p）→ 得到 base_energy
2. 当 `dst_cpu >= 0`：sum_util = pd_busy_time + task_busy_time → 得到放置后的能耗
3. delta = 放置后能耗 - base_energy → **任务 p 带来的额外能耗增量**

---

## 九、最终决策逻辑

```c
// 遍历完所有 PD 后
if ((best_fits > prev_fits) ||
    ((best_fits > 0) && (best_delta < prev_delta)) ||
    ((best_fits < 0) && (best_actual_cap > prev_actual_cap)))
    target = best_energy_cpu;

return target;
```

三个条件代表三种优先级从高到低的决策：

| 条件 | 场景 | 策略 |
|------|------|------|
| `best_fits > prev_fits` | best_cpu 比 prev_cpu 更满足 uclamp 性能需求 | **性能优先**：迁移过去 |
| `best_fits > 0 && best_delta < prev_delta` | 两者都满足性能，比能耗 | **能效优先**：选增量更小的 |
| `best_fits < 0 && best_actual_cap > prev_actual_cap` | 两者都不完全满足性能 | **退而求其次**：选容量更大的 |

### prev_cpu 的特殊地位

注意代码中 prev_cpu 始终作为候选保留。这是因为任务留在原 CPU 有 **cache 热度** 的优势——L1/L2 cache 中可能还有该任务的数据。EAS 选择迁移，**必须在能耗上确实更优**才值得。

---

## 十、util_fits_cpu() —— 三种返回值的含义

```c
static inline int util_fits_cpu(unsigned long util,
        unsigned long uclamp_min, unsigned long uclamp_max, int cpu)
{
    unsigned long capacity = capacity_of(cpu);
    unsigned long capacity_orig;
    bool fits, uclamp_max_fits;

    // 基本判断：利用率是否 fit（含 20% margin）
    fits = fits_capacity(util, capacity);

    if (!uclamp_is_used())
        return fits;

    capacity_orig = arch_scale_cpu_capacity(cpu);

    // uclamp_max 的处理（见下面详解）
    uclamp_max_fits = (capacity_orig == SCHED_CAPACITY_SCALE) &&
                      (uclamp_max == SCHED_CAPACITY_SCALE);
    uclamp_max_fits = !uclamp_max_fits && (uclamp_max <= capacity_orig);
    fits = fits || uclamp_max_fits;

    // uclamp_min 的处理
    uclamp_min = min(uclamp_min, uclamp_max);
    if (fits && (util < uclamp_min) &&
        (uclamp_min > get_actual_cpu_capacity(cpu)))
        return -1;

    return fits;
}
```

| 返回值 | 含义 | 举例 |
|--------|------|------|
| `1` | 完全适合 | util=200, capacity=512, uclamp 都满足 |
| `0` | 不适合，CPU 容量不够 | util=500, capacity=446（含 margin） |
| `-1` | 利用率能跑，但 uclamp_min 无法满足 | util=100 能跑, 但 uclamp_min=800 > 小核 cap=446 |

**返回 -1 的场景：** 任务设了一个很高的性能下限（比如通过 Android 的 uclamp 接口），告诉调度器"我至少需要这么多算力"。小核虽然 util 低跑得动，但无法提供承诺的最低性能。这种情况 EAS 会**倾向于选大核**，除非所有大核也 fit 不了。

---

## 十一、完整数值示例

### 系统配置

```
PD0 (小核): CPU0~CPU3, max_capacity=512
  EM 表:
  ┌──────────┬────────────┬────────┬───────┐
  │ freq(MHz)│ capacity   │ power  │ cost  │
  ├──────────┼────────────┼────────┼───────┤
  │ 600      │ 307        │ 50     │ 163   │
  │ 800      │ 410        │ 100    │ 244   │
  │ 1000     │ 512        │ 200    │ 391   │
  └──────────┴────────────┴────────┴───────┘

PD1 (大核): CPU4~CPU7, max_capacity=1024
  EM 表:
  ┌──────────┬────────────┬────────┬───────┐
  │ freq(MHz)│ capacity   │ power  │ cost  │
  ├──────────┼────────────┼────────┼───────┤
  │ 1000     │ 512        │ 300    │ 293   │
  │ 1800     │ 921        │ 800    │ 434   │
  │ 2200     │ 1024       │ 1200   │ 534   │
  └──────────┴────────────┴────────┴───────┘
```

### 当前状态

```
CPU0: util=200    CPU4: util=400
CPU1: util=300    CPU5: util=100
CPU2: util=100    CPU6: util=50
CPU3: util=250    CPU7: util=200
```

任务 p: `util=150`，之前运行在 CPU1 (`prev_cpu=CPU1`)

### Step 1: PD0 找候选

每个 CPU 放入 p 后的 util：
- CPU0: 200+150=350, spare=512-350=162
- CPU1: 300+150=450, spare=512-450=62  (prev_cpu)
- CPU2: 100+150=250, spare=512-250=262  ← **max_spare_cap_cpu**
- CPU3: 250+150=400, spare=512-400=112

候选：CPU2 (max_spare) 和 CPU1 (prev)

### Step 2: PD0 能耗计算

**base_energy (不含 p):**
- max_util = max(200, 300, 100, 250) = 300 → 查表找 ≥300 的最低 capacity → 410 (800MHz, cost=244)
- sum_util = 200+300+100+250 = 850
- base_energy = 244 × 850 = **207,400**

**把 p 放到 CPU1 (prev_cpu):**
- max_util = max(200, **450**, 100, 250) = 450 → 查表 → 512 (1000MHz, cost=391)
- sum_util = 850 + 150 = 1000
- energy = 391 × 1000 = 391,000
- **prev_delta = 391,000 - 207,400 = 183,600**

**把 p 放到 CPU2 (best_cpu):**
- max_util = max(200, 300, **250**, 250) = 300 → 还是 410 (800MHz, cost=244)！
- sum_util = 850 + 150 = 1000
- energy = 244 × 1000 = 244,000
- **cur_delta = 244,000 - 207,400 = 36,600**

### Step 3: PD1 能耗计算（简略）

- PD1 的 max_spare_cap_cpu = CPU6 (spare=1024-50=974)
- 放 p 到 CPU6: max_util = max(400, 100, 200, 200) = 400 → 512 (1000MHz, cost=293)
- sum_util = (400+100+50+200) + 150 = 900
- energy_with_p = 293 × 900 = 263,700
- base_energy_pd1 = 293 × 750 = 219,750
- cur_delta_pd1 = 263,700 - 219,750 = **43,950**

### Step 4: 最终比较

| 候选 CPU | delta |
|----------|-------|
| CPU1 (prev, 小核) | 183,600 |
| CPU2 (best, 小核) | 36,600  ← **最小！** |
| CPU6 (best, 大核) | 43,950 |

**选择 CPU2！**

### 为什么 CPU2 的 delta 这么小？

关键在于：放任务到 CPU2 后，PD0 的 max_util 仍然是 CPU1 的 300（没有变化），频点维持 800MHz 不变！而放到 CPU1，max_util 从 300 跳到 450，**触发升频到 1GHz**，cost 从 244 飙升到 391。

**这就是 EAS 的精髓：通过智能放置，避免不必要的升频，从而节省能量。**

---

## 十二、EAS 与传统负载均衡的关系

```
                    ┌──────────────────┐
                    │  任务唤醒 / wakeup │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │ is_rd_overutilized?│
                    └────────┬─────────┘
                   No        │        Yes
            ┌────────────────┼────────────────┐
            │                                 │
   ┌────────▼────────┐              ┌────────▼─────────┐
   │  EAS 路径        │              │  传统路径         │
   │  能效最优        │              │  负载公平         │
   │                  │              │                   │
   │  find_energy_    │              │  wake_affine?     │
   │  efficient_cpu() │              │   ├─ Yes: 快速路径│
   │                  │              │   │  select_idle_ │
   │  考虑频点变化    │              │   │  sibling()    │
   │  考虑功耗模型    │              │   │               │
   │  考虑 uclamp    │              │   └─ No: 慢速路径 │
   │                  │              │      find_idlest_ │
   └──────────────────┘              │      cpu()       │
                                     └──────────────────┘
```

**三条路径总结：**

| 路径 | 入口条件 | 策略 |
|------|----------|------|
| EAS: `find_energy_efficient_cpu()` | 唤醒 + 未超载 + EAS 使能 | 选能耗增量最小的 CPU |
| 快速路径: `select_idle_sibling()` | 唤醒 + wake affine 任务 | 找 cache 共享的 idle CPU |
| 慢速路径: `find_idlest_cpu()` | fork/exec 或非 affine 任务 | 找系统中最空闲的 CPU |

---

## 十三、关键设计决策总结

| 设计选择 | 为什么这样做 |
|----------|-------------|
| 超载时退出 EAS | 超载 → 频点锁最高 → 选 CPU 无法影响频点 → EAS 假设失效 |
| 80% 阈值 (1280/1024) | PELT 是均值，留 20% 余量应对利用率突发 |
| 1024 = 满容量 | 定点数，2^10 移位比除法快，精度 0.1% |
| 选 max_spare_cap_cpu | 避免成为 PD 最忙 CPU，避免拉高频点 |
| 每 PD 只选一个候选 | 减少 compute_energy 调用，控制唤醒延迟 |
| `ps->cost × sum_util` | 物理推导简化：单位能耗系数 × 总工作量 |
| 排除 p 再单独加回 | 保证不同候选 CPU 比较时基准一致 |
| IRQ 缩放 task busy_time | IRQ 挤占可调度时间，需修正忙碌比例 |
| prev_cpu 始终参与比较 | cache 热度有价值，除非迁移确实更省 |
| fits 返回 -1 | 区分"跑得动但性能打折"和"完全跑不动" |

---

## 参考

- `kernel/sched/fair.c` — EAS 核心实现
- `kernel/sched/topology.c` — PD 构建与 EAS 使能判断
- `include/linux/energy_model.h` — EM 能耗计算
- `include/linux/sched.h` — SCHED_CAPACITY_SCALE 定义
- [LWN: Energy-aware scheduling](https://lwn.net/Articles/749653/)
- [内核文档: Documentation/scheduler/sched-energy.rst](https://www.kernel.org/doc/Documentation/scheduler/sched-energy.rst)
