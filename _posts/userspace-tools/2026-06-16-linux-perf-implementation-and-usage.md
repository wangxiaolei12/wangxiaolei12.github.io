---
layout: post
title: "Linux Perf 深度解析：PMU 原理、内核实现与火焰图实战"
date: 2026-06-16 17:20:00 +0800
excerpt: "从 PMU 硬件原理讲起：CPU 计数器如何工作、溢出中断如何采样、perf_event 内核框架如何抽象、用户态工具如何使用、火焰图如何制作与分析。"
---

# Linux Perf 深度解析

---

## 一、先搞清楚 PMU 硬件 — Perf 的根基

### 1.1 PMU 是什么

PMU (Performance Monitoring Unit) 是 **CPU 芯片内部的硬件单元**，每个核心都有。它包含几个**计数器寄存器**（ARM64 通常 6 个，x86 通常 4-8 个），可以配置为监听不同的微架构事件：

```
CPU 核心内部:
┌────────────────────────────────────────────────────────────┐
│                                                            │
│  流水线: 取指 → 解码 → 执行 → 访存 → 写回                  │
│           │       │       │      │                         │
│           │       │       │      │ 每个阶段产生             │
│           ▼       ▼       ▼      ▼ "事件信号线"            │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  PMU 硬件单元                                         │  │
│  │                                                      │  │
│  │  Counter 0: 配置监听 "cpu-cycles"    值: 1,234,567   │  │
│  │  Counter 1: 配置监听 "instructions"  值: 456,789     │  │
│  │  Counter 2: 配置监听 "cache-misses"  值: 12,345      │  │
│  │  Counter 3: 配置监听 "branch-misses" 值: 1,234       │  │
│  │  Counter 4: (空闲)                                   │  │
│  │  Counter 5: (空闲)                                   │  │
│  │                                                      │  │
│  │  特性:                                               │  │
│  │  ├── 硬件自动递增，零 CPU 开销（不占流水线）          │  │
│  │  ├── 可配置溢出阈值 → 溢出时产生 PMI 中断            │  │
│  │  └── 可配置监听哪种事件（写配置寄存器选择）          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

**关键：PMU 计数是纯硬件行为，不需要软件参与，对程序性能几乎零影响。**

### 1.2 PMU 支持监听哪些事件

```
硬件事件 (来自 CPU 微架构信号线):
  cpu-cycles        每个时钟周期 +1
  instructions      每执行一条指令 +1
  cache-references  每次访问 L1/L2/L3 cache +1
  cache-misses      cache 未命中 +1
  branch-misses     分支预测失败 +1
  bus-cycles        总线周期 +1
  ...

这些事件是 CPU 流水线运行时 "自然产生的副产品"，
PMU 只是把信号线连到计数器上，不会干扰程序执行。
```

### 1.3 PMU 的两种工作模式

**模式 A：纯计数（perf stat 用）**

```
配置: Counter 0 = 监听 cycles
      开始计数

... 程序跑了 5 秒 ...

停止，读 Counter 0 = 5,000,000,000
→ "跑了 50 亿个 cycle"

特点: 精确总数，零开销
缺点: 只知道总数，不知道哪个函数花的
```

**模式 B：溢出采样（perf record 用）— 这才是核心！**

```
配置: Counter 0 = 监听 cycles, 溢出阈值 = 100,000

程序运行中:
  counter: 0 → 1 → 2 → ... → 99,999 → 100,000 → ★ 溢出!

  ★ PMU 硬件产生中断 (PMI = Performance Monitor Interrupt)
      │
      ▼
  CPU 被打断，跳到中断处理程序:
      "此刻 PC (程序计数器) = 0x4012a8"
      "查符号表: 0x4012a8 = hot_function + 0x28"
      "调用栈: main → process → hot_function"
      → 记录这条采样，写入 ring buffer

  counter 清零，继续计数...
  又过 100,000 cycles → 又溢出 → 又记录...
  又过 100,000 cycles → 又溢出 → 又记录...

采样 10 秒，收集 50,000 条采样。统计:
  hot_function: 出现 17,500 次 (35%) ← 热点！
  memcpy:       出现  6,000 次 (12%)
  parse_data:   出现  4,000 次 (8%)
  ...

原理: 哪个函数花的 cycles 多，PMU 溢出时刚好在它里面的概率就高
      采样足够多次 → 统计结果趋近真实分布
```

### 1.4 为什么这种方式有效？

```
假设 hot_function 占 35% 的 CPU 时间:

  时间轴: ████ hot_function ████  ░░ other ░░  ████ hot_function ████  ░░░
          ↑                    ↑             ↑                    ↑
        采样1                采样2          采样3                采样4
        命中!               没命中          命中!               没命中

  10000 次采样中约 3500 次命中 hot_function ≈ 35% ✓

  采样越多越准确（统计学大数定律）
  每秒 4000 次采样 × 10 秒 = 40000 次 → 足够准确
```

---

## 二、软件事件 — 没有硬件支持怎么办

不是所有事件都有 PMU 计数器。内核用软件模拟：

```
cpu-clock (最常用的软件采样事件):
  → 内核设一个 hrtimer，每 1/freq 秒触发中断
  → 中断时记录 PC 和调用栈
  → 效果类似 PMU 采样，但精度稍低（受调度影响）
  → 适用于没有 PMU 或 PMU counter 用完的情况

page-faults:
  → 每次缺页异常时 count++
  → 不是采样，是精确计数

context-switches:
  → 每次 schedule() 时 count++

cpu-migrations:
  → 每次任务迁移 CPU 时 count++
```

---

## 三、内核 perf_event 框架 — 统一抽象

### 3.1 分层架构

```
┌─────────────────────────────────────────────────────────┐
│ 用户态: perf 工具                                        │
│   perf_event_open(attr={type=HW, config=CYCLES, freq=4000}) │
└────────────────────────┬────────────────────────────────┘
                         │ syscall
┌────────────────────────┼────────────────────────────────┐
│ 内核: perf_event 框架 (kernel/events/core.c)             │
│                                                         │
│   struct perf_event:                                    │
│     attr    → 用户配置 (哪种事件, 采样频率)              │
│     pmu     → 指向具体的 PMU 驱动                       │
│     rb      → ring buffer (采样数据写这里)              │
│     overflow_handler → 溢出时的回调函数                  │
│                                                         │
│   struct pmu (抽象接口):                                │
│     .event_init()  → 检查事件是否支持                   │
│     .add()         → 把事件加到 PMU 计数器              │
│     .del()         → 从 PMU 移除                        │
│     .start()       → 开始计数                           │
│     .stop()        → 停止计数                           │
│     .read()        → 读计数器当前值                     │
└────────┬──────────────────┬──────────────┬──────────────┘
         │                  │              │
   ┌─────▼──────┐    ┌─────▼──────┐  ┌───▼────────────┐
   │ HW PMU     │    │ SW Events  │  │ Tracepoints    │
   │ armv8_pmu  │    │ hrtimer    │  │ sched:*        │
   │ intel_pmu  │    │ 计数器递增  │  │ irq:*          │
   └─────┬──────┘    └────────────┘  └────────────────┘
         │
   ┌─────▼──────────────────────────────────────┐
   │ CPU PMU 硬件寄存器                          │
   │ PMCR, PMCNTENSET, PMEVCNTRn, PMINTENSET   │ (ARM64)
   │ IA32_PERFEVTSELx, IA32_PMCx               │ (x86)
   └────────────────────────────────────────────┘
```

### 3.2 perf_event_open 系统调用

```c
// kernel/events/core.c
SYSCALL_DEFINE5(perf_event_open,
    struct perf_event_attr __user *, attr_uptr,  // 配置
    pid_t, pid,      // 目标进程 (-1=所有进程)
    int, cpu,        // 目标 CPU (-1=所有 CPU)
    int, group_fd,   // 事件组 (-1=独立)
    unsigned long, flags)
{
    // 1. 拷贝用户配置
    perf_copy_attr(attr_uptr, &attr);

    // 2. 根据 attr.type 找对应的 PMU 驱动
    pmu = perf_init_event(event);
    //   type=HARDWARE → arm_pmu / intel_pmu
    //   type=SOFTWARE → perf_swevent (hrtimer)
    //   type=TRACEPOINT → perf_tracepoint

    // 3. 分配 perf_event，关联 PMU
    event = perf_event_alloc(&attr, cpu, task, pmu, ...);

    // 4. 安装到目标 context（per-task 或 per-cpu）
    perf_install_in_context(ctx, event, cpu);
    //   → 配置 PMU 计数器寄存器
    //   → 使能计数/中断

    // 5. 返回 fd
    return event_fd;
    // 用户通过 fd: mmap 得到 ring buffer, poll 等待数据
}
```

### 3.3 采样中断处理 (ARM64 PMU 为例)

```c
// arch/arm64/kernel/perf_event.c
static irqreturn_t armv8pmu_handle_irq(struct arm_pmu *cpu_pmu)
{
    // PMU 计数器溢出 → 硬件产生此中断

    for (idx = 0; idx < cpu_pmu->num_events; idx++) {
        event = cpuc->events[idx];
        if (!event || !armv8pmu_counter_overflowed(idx))
            continue;

        // ★ 调用 perf 核心的溢出处理
        perf_event_overflow(event, &data, regs);
    }
}

// kernel/events/core.c
int perf_event_overflow(struct perf_event *event, struct perf_sample_data *data,
                        struct pt_regs *regs)
{
    // 记录采样数据:
    data->ip = instruction_pointer(regs);  // 当前 PC → 哪个函数
    data->callchain = perf_callchain(event, regs);  // 调用栈
    data->time = local_clock();
    data->pid = current->pid;

    // 写入 ring buffer
    perf_event_output(event, data, regs);
    //  → 写入 mmap 共享的 ring buffer
    //  → 用户态 perf 工具直接读取（零拷贝）

    // 重置计数器，继续采样
    return 0;
}
```

### 3.4 Ring Buffer 数据传输（零拷贝）

```
内核态                              用户态 (perf 工具)
───────                             ─────────────────

ring buffer (perf_mmap):            用户 mmap(fd):
┌─────────────────────────┐         ┌─────────────────────────┐
│ perf_event_mmap_page    │ ← 共享 →│ 直接读，不需要 syscall   │
│   data_head (内核写指针) │         │                         │
│   data_tail (用户读指针) │         │ while (head != tail) {  │
├─────────────────────────┤         │   sample = read(head);  │
│ sample: IP=0x4012a8     │         │   // hot_function+0x28  │
│ sample: IP=0x401100     │         │   advance(head);        │
│ sample: IP=0x4012b0     │         │ }                       │
│ ...                     │         │ → 写入 perf.data 文件   │
└─────────────────────────┘         └─────────────────────────┘

优势: 内核写、用户读，通过共享内存，没有 read() syscall 开销
```

---

## 四、Perf 使用指南

### 4.1 perf stat — 计数模式（总共多少）

```bash
# 默认事件统计:
perf stat ./my_app

# 输出:
# 1,234,567,890  cycles                  # 总周期数
#   456,789,012  instructions            # 总指令数     IPC: 0.37
#    12,345,678  cache-misses            # 缓存未命中
#     1,234,567  branch-misses           # 分支预测失败
#         0.312  seconds time elapsed

# 关键指标:
# IPC > 1: 好（超标量执行）
# IPC < 0.5: 差（在等内存/cache miss 多）
# cache-miss > 5%: 数据局部性差
# branch-miss > 5%: 分支不可预测

# 指定事件:
perf stat -e cycles,instructions,L1-dcache-load-misses ./my_app

# 监控系统全局:
perf stat -a sleep 10

# 监控特定进程:
perf stat -p <PID> sleep 10
```

### 4.2 perf record — 采样模式（谁花的时间多）

```bash
# 采样程序（默认事件 cycles）:
perf record -g ./my_app
#           ^^ -g: 记录调用栈（火焰图必须）

# 采样系统全局:
perf record -a -g -- sleep 10

# 指定频率:
perf record -F 4000 -a -g -- sleep 10
#           ^^^^^^ 每秒 4000 次 (默认 4000)

# 指定事件:
perf record -e cache-misses -g ./my_app

# 指定进程:
perf record -g -p <PID> -- sleep 30
```

### 4.3 perf report — 分析结果

```bash
perf report

# 输出:
# Overhead  Command   Shared Object      Symbol
#  35.20%   my_app    my_app             [.] hot_function    ← 热点!
#  12.30%   my_app    libc.so.6          [.] memcpy
#   8.50%   my_app    [kernel]           [k] copy_page
#   5.20%   my_app    my_app             [.] parse_data

# [.] = 用户态函数
# [k] = 内核函数
# Overhead = 该函数在所有采样中出现的占比

# 展开调用链看谁调用了热点:
perf report --call-graph=callee
```

### 4.4 perf top — 实时热点

```bash
perf top        # 类似 top，但看函数级 CPU 消耗
perf top -p <PID>
perf top -e cache-misses
```

---

## 五、火焰图制作与分析

### 5.1 制作三步

```bash
# 1. 采样（必须 -g 记录调用栈）
perf record -F 99 -a -g -- sleep 30

# 2. 导出 + 折叠调用栈
perf script | ./FlameGraph/stackcollapse-perf.pl > out.folded

# 3. 生成 SVG
./FlameGraph/flamegraph.pl out.folded > flame.svg

# FlameGraph 工具:
git clone https://github.com/brendangregg/FlameGraph
```

### 5.2 火焰图怎么读

```
              ┌── malloc ──┐
         ┌────┴─ parse ────┴────┐
    ┌────┴────── process ───────┴────┐
  ┌─┴──────────── main ─────────────┴─┐
  └────────────────────────────────────┘

  Y 轴 (从下到上): 调用栈深度
    底部 = 程序入口 (main)
    顶部 = 实际消耗 CPU 的叶子函数

  X 轴: 不是时间！是采样占比
    宽度 = 该函数（包含它调用的所有子函数）的采样次数占比

  颜色: 随机，无含义

  怎么找问题:
    → 找最宽的"平顶"（顶部的宽函数 = CPU 真正消耗的地方）
    → 从顶部往下看 = 谁调用了热点
```

### 5.3 常见问题模式

| 火焰图特征 | 含义 | 优化方向 |
|-----------|------|---------|
| `memcpy/memmove` 很宽 | 数据拷贝太多 | zero-copy, 减少拷贝 |
| `_raw_spin_lock` 很宽 | 锁竞争 | 减小临界区, 无锁结构 |
| `page_fault` 很宽 | 内存分配频繁 | 预分配, hugepage |
| `copy_to_user` 很宽 | 内核↔用户频繁 | mmap, 批量 IO |
| `schedule` 很宽 | 频繁切换 | 减少线程, 绑核 |
| `default_idle_call` 占 95% | 系统空闲 | 没有性能问题 |

---

## 六、高级用法

### 6.1 锁竞争分析

```bash
perf lock record ./my_app
perf lock report
# Name           acquired  contended  avg wait   max wait
# &rq->lock      12345     234        1.2us      45us
```

### 6.2 缓存分析

```bash
perf stat -e L1-dcache-load-misses,LLC-load-misses ./my_app
perf record -e L1-dcache-load-misses -g ./my_app
perf report  # 看哪个函数 cache miss 最多
```

### 6.3 追踪内核事件

```bash
# 上下文切换详情:
perf record -e sched:sched_switch -a -- sleep 5
perf script

# 中断延迟:
perf record -e irq:irq_handler_entry -a -- sleep 5
perf script
```

---

## 七、源文件索引

| 文件 | 内容 |
|------|------|
| `kernel/events/core.c` | perf_event_open, 溢出处理, context 管理 |
| `kernel/events/ring_buffer.c` | ring buffer 管理 |
| `kernel/events/callchain.c` | 调用栈回溯 |
| `arch/arm64/kernel/perf_event.c` | ARM64 PMU 驱动 |
| `arch/x86/events/core.c` | x86 PMU 驱动 |
| `include/uapi/linux/perf_event.h` | perf_event_attr, 事件类型定义 |
| `include/linux/perf_event.h` | struct perf_event, struct pmu |
| `tools/perf/` | perf 用户态工具源码 |
