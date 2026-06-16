---
layout: post
title: "Linux Perf 深度解析：内核实现原理、使用方法与火焰图分析"
date: 2026-06-16 17:20:00 +0800
excerpt: "从源码分析 perf 的实现原理：perf_event_open 系统调用、PMU 硬件抽象、采样与计数模式、ring buffer 数据传输。附完整使用指南：perf stat/record/report/top、火焰图制作与分析方法。"
---

# Linux Perf 深度解析：内核实现与使用

---

## 一、Perf 是什么

Perf 利用 CPU 硬件性能计数器 (PMU) 和内核软件事件，采样或计数程序的行为：

```
┌─────────────────────────────────────────────────────────────────────┐
│ 用户空间                                                             │
│  perf record / perf stat / perf top                                 │
│      │                                                              │
│      │ perf_event_open() syscall                                    │
│      ▼                                                              │
├─────────────────────────────────────────────────────────────────────┤
│ 内核                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  perf_event 子系统 (kernel/events/core.c)                    │    │
│  │                                                             │    │
│  │  ┌────────────┐   ┌────────────┐   ┌────────────┐          │    │
│  │  │ Hardware   │   │ Software   │   │ Tracepoint │          │    │
│  │  │ PMU        │   │ Events     │   │ Events     │          │    │
│  │  │ cycles     │   │ cpu-clock  │   │ sched:*    │          │    │
│  │  │ instructions│   │ page-faults│   │ irq:*      │          │    │
│  │  │ cache-miss │   │ context-sw │   │ block:*    │          │    │
│  │  └─────┬──────┘   └─────┬──────┘   └─────┬──────┘          │    │
│  │        │                 │                 │                │    │
│  │        ▼                 ▼                 ▼                │    │
│  │  ┌──────────────────────────────────────────────────┐       │    │
│  │  │   Ring Buffer (perf_mmap)                        │       │    │
│  │  │   采样数据: IP, 调用栈, 时间戳, PID...            │       │    │
│  │  └───────────────────────┬──────────────────────────┘       │    │
│  └──────────────────────────┼──────────────────────────────────┘    │
│                             │ mmap 共享                              │
├─────────────────────────────┼───────────────────────────────────────┤
│ 用户空间                     ▼                                       │
│  perf 工具直接 mmap 读取 → 写入 perf.data → perf report 分析        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 二、内核实现原理

### 2.1 核心系统调用 — perf_event_open()

```c
// kernel/events/core.c
SYSCALL_DEFINE5(perf_event_open,
    struct perf_event_attr __user *, attr_uptr,  // 事件属性
    pid_t, pid,                                  // 目标进程 (-1=all)
    int, cpu,                                    // 目标 CPU (-1=all)
    int, group_fd,                               // 事件组
    unsigned long, flags)
{
    // 1. 拷贝用户空间的 attr
    perf_copy_attr(attr_uptr, &attr);

    // 2. 权限检查
    security_perf_event_open(PERF_SECURITY_OPEN);

    // 3. 找到对应的 PMU
    pmu = perf_init_event(event);
    //   根据 attr.type 选择:
    //   PERF_TYPE_HARDWARE → cpu_pmu (ARM PMU / Intel PMU)
    //   PERF_TYPE_SOFTWARE → perf_swevent
    //   PERF_TYPE_TRACEPOINT → perf_tracepoint

    // 4. 分配 perf_event 结构
    event = perf_event_alloc(&attr, cpu, task, ...);

    // 5. 安装到目标 context
    perf_install_in_context(ctx, event, event->cpu);

    // 6. 返回 fd（用户通过 fd 读数据、mmap ring buffer）
    fd_install(event_fd, event_file);
    return event_fd;
}
```

### 2.2 事件类型

```c
// include/uapi/linux/perf_event.h
enum perf_type_id {
    PERF_TYPE_HARDWARE   = 0,  // CPU 硬件计数器
    PERF_TYPE_SOFTWARE   = 1,  // 内核软件事件
    PERF_TYPE_TRACEPOINT = 2,  // 内核 tracepoint
    PERF_TYPE_HW_CACHE   = 3,  // 缓存事件
    PERF_TYPE_RAW        = 4,  // 原始 PMU 事件号
    PERF_TYPE_BREAKPOINT = 5,  // 硬件断点
};

// 硬件事件:
enum perf_hw_id {
    PERF_COUNT_HW_CPU_CYCLES         = 0,  // CPU 周期数
    PERF_COUNT_HW_INSTRUCTIONS       = 1,  // 执行指令数
    PERF_COUNT_HW_CACHE_REFERENCES   = 2,  // 缓存访问
    PERF_COUNT_HW_CACHE_MISSES       = 3,  // 缓存未命中
    PERF_COUNT_HW_BRANCH_INSTRUCTIONS= 4,  // 分支指令
    PERF_COUNT_HW_BRANCH_MISSES      = 5,  // 分支预测失败
};

// 软件事件:
enum perf_sw_ids {
    PERF_COUNT_SW_CPU_CLOCK       = 0,  // CPU 时钟 (hrtimer 采样)
    PERF_COUNT_SW_TASK_CLOCK      = 1,  // 任务时钟
    PERF_COUNT_SW_PAGE_FAULTS     = 2,  // 缺页次数
    PERF_COUNT_SW_CONTEXT_SWITCHES= 3,  // 上下文切换
    PERF_COUNT_SW_CPU_MIGRATIONS  = 4,  // CPU 迁移
};
```

### 2.3 两种工作模式

**计数模式 (perf stat)：**
```
PMU 计数器持续递增
    → perf_event_read() 读取当前值
    → 返回总计数（如执行了多少条指令）

不产生中断，开销极低
```

**采样模式 (perf record)：**
```
PMU 计数器每溢出一次（每 N 个事件）→ 触发 PMI 中断
    → perf_event_overflow()
        → perf_event_output()
            → 记录: IP(程序计数器), 调用栈, 时间戳, PID...
            → 写入 ring buffer
    → 用户空间 mmap 读取 ring buffer → 写 perf.data

N = sample_period (如每 4000 个 cycles 采样一次)
或 sample_freq (如 4000Hz，内核自动调整 period)
```

### 2.4 采样中断流程 (ARM64 PMU)

```
PMU 计数器溢出 → 硬件中断
    │
    ▼
armv8pmu_handle_irq()               [arch/arm64/kernel/perf_event.c]
    │
    ├── 遍历该 CPU 上所有活跃的 perf_event
    │
    └── for each event with overflow:
            perf_event_overflow(event, &data, regs)
                │
                ├── 记录采样数据:
                │     data.ip = instruction_pointer(regs)  // 被打断的 PC
                │     data.callchain = perf_callchain()     // 调用栈回溯
                │     data.time = local_clock()
                │     data.pid/tid = current->pid
                │
                └── perf_event_output(event, &data, regs)
                        → 写入 ring buffer (perf_mmap)
                        → 如果用户空间在 poll()，唤醒它
```

### 2.5 Ring Buffer 数据传输

```
内核态                              用户态 (perf 工具)
───────                             ─────────────────

perf_mmap:                          mmap(fd, ...):
┌─────────────────────────┐         ┌─────────────────────────┐
│ perf_event_mmap_page    │ ←共享→  │ 直接读取，零拷贝         │
│   data_head (写指针)    │         │                         │
│   data_tail (读指针)    │         │ while (head != tail)    │
├─────────────────────────┤         │   sample = read(head)   │
│ sample record 1         │         │   process(sample)       │
│ sample record 2         │         │   advance head          │
│ sample record 3         │         │                         │
│ ...                     │         └─────────────────────────┘
└─────────────────────────┘

无系统调用！用户态直接 mmap 读内核写的数据 → 极高性能
```

---

## 三、Perf 使用指南

### 3.1 perf stat — 计数（程序跑了多少事件）

```bash
# 统计 ls 命令的硬件事件:
perf stat ls

# 输出:
#  1,234,567  cycles                    # CPU 周期
#    456,789  instructions              # 指令数      IPC=0.37
#     12,345  cache-misses              # 缓存未命中
#      1,234  branch-misses             # 分支预测失败

# 指定事件:
perf stat -e cycles,instructions,cache-misses ./my_app

# 统计系统全局 5 秒:
perf stat -a -e context-switches,cpu-migrations sleep 5

# 统计特定进程:
perf stat -p <PID> sleep 10
```

**关键指标：**
- **IPC** (Instructions Per Cycle): >1 好，<0.5 说明 CPU 经常在等（cache miss / 内存延迟）
- **cache-miss rate**: >5% 需要优化数据布局
- **branch-miss rate**: >5% 考虑去掉不可预测分支

### 3.2 perf record — 采样（哪里花时间最多）

```bash
# 采样整个系统 10 秒:
perf record -a -g -- sleep 10
#           ^  ^
#           |  └── -g: 记录调用栈 (用于火焰图)
#           └── -a: 所有 CPU

# 采样特定程序:
perf record -g ./my_app

# 采样特定进程:
perf record -g -p <PID> -- sleep 30

# 指定采样频率:
perf record -F 4000 -g -a -- sleep 10
#            ^^^^^^ 每秒 4000 次采样

# 指定事件:
perf record -e cache-misses -g ./my_app
```

输出 `perf.data` 文件。

### 3.3 perf report — 分析采样结果

```bash
# 交互式查看:
perf report

# 输出:
# Overhead  Command   Shared Object      Symbol
#  35.20%   my_app    my_app             [.] hot_function
#  12.30%   my_app    libc.so.6          [.] memcpy
#   8.50%   my_app    [kernel]           [k] copy_page
#   5.20%   my_app    my_app             [.] parse_data

# 按调用链展开:
perf report --call-graph=callee

# 输出文本格式 (可以 grep):
perf report --stdio
```

### 3.4 perf top — 实时热点

```bash
# 系统级实时热点:
perf top

# 特定进程:
perf top -p <PID>

# 指定事件:
perf top -e cache-misses
```

---

## 四、火焰图制作与分析

### 4.1 制作步骤

```bash
# 1. 采样 (带调用栈):
perf record -F 99 -a -g -- sleep 30
#           ^^^^       ^^
#           99Hz避免   记录调用栈
#           锁步干扰

# 2. 生成折叠栈格式:
perf script | stackcollapse-perf.pl > out.folded
# 或用 FlameGraph 工具:
git clone https://github.com/brendangregg/FlameGraph
perf script | ./FlameGraph/stackcollapse-perf.pl > out.folded

# 3. 生成 SVG 火焰图:
./FlameGraph/flamegraph.pl out.folded > flamegraph.svg

# 一行搞定:
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

### 4.2 火焰图怎么读

```
         ┌─────── malloc ───────┐
    ┌────┴──── parse_data ──────┴────┐
  ┌─┴──────────── main ─────────────┴─┐
  ├────────────────────────────────────┤
  
  X 轴: 不是时间！是采样比例（宽度 = 该函数出现在采样中的次数占比）
  Y 轴: 调用栈深度（底部=入口函数，顶部=实际执行的函数）
  颜色: 随机，无意义

  读法:
  - 找最宽的"平台" → 那就是热点函数
  - 从上往下看 → 谁调用了热点
  - 越顶部的函数占比越高 → 优化它收益最大
```

### 4.3 常见模式分析

```
模式 1: 一个函数很宽（如 memcpy 占 40%）
  → 内存拷贝太多，考虑 zero-copy 或减少拷贝

模式 2: 内核 copy_to_user/copy_from_user 很宽
  → 用户/内核数据传输频繁，考虑 mmap 或批量操作

模式 3: lock_acquire / _raw_spin_lock 很宽
  → 锁竞争激烈，考虑减小临界区或换无锁结构

模式 4: page_fault / handle_mm_fault 很宽
  → 内存分配/映射频繁，考虑预分配或 hugepage

模式 5: schedule / finish_task_switch 很宽
  → 频繁上下文切换，考虑减少线程数或绑核
```

### 4.4 Off-CPU 火焰图（分析阻塞）

```bash
# 普通火焰图看 "CPU 上在干什么"
# Off-CPU 火焰图看 "为什么不在 CPU 上"（等什么）

# 方法1: 用 perf 的 sched 事件
perf record -e sched:sched_switch -a -g -- sleep 30
perf script | stackcollapse-perf.pl | flamegraph.pl \
    --color=io --title="Off-CPU" > offcpu.svg

# 方法2: bpftrace (更准确)
bpftrace -e 'kprobe:finish_task_switch { @[kstack] = count(); }' > offcpu.bt
```

---

## 五、高级用法

### 5.1 内核函数级追踪

```bash
# 追踪特定内核函数被调用的频率:
perf stat -e 'probe:schedule' -a -- sleep 5

# 动态添加内核探针:
perf probe --add 'tcp_sendmsg size'
perf record -e probe:tcp_sendmsg -a -- sleep 10
perf script  # 每次调用都记录

# 追踪 tracepoint:
perf record -e 'sched:sched_switch' -a -- sleep 5
perf script  # 每次上下文切换的详细信息
```

### 5.2 内存/缓存分析

```bash
# L1 cache miss 采样:
perf record -e L1-dcache-load-misses -g ./my_app
perf report

# 内存访问模式 (需要硬件支持):
perf mem record ./my_app
perf mem report

# NUMA 远端访问:
perf stat -e node-load-misses,node-store-misses ./my_app
```

### 5.3 锁竞争分析

```bash
perf lock record ./my_app
perf lock report

# 输出:
# Name         acquired  contended  avg wait  max wait
# &rq->lock    12345     234        1.2us     45us
```

---

## 六、内核关键数据结构

```c
struct perf_event {
    struct perf_event_attr    attr;       // 用户传入的配置
    struct pmu                *pmu;       // 对应的 PMU 驱动
    struct perf_event_context *ctx;       // 所属 context (per-task/per-cpu)

    u64                       count;      // 计数值
    u64                       total_time_enabled;
    u64                       total_time_running;

    struct perf_buffer        *rb;        // ring buffer (mmap 共享)
    struct list_head          event_entry; // context 的事件链表

    // 溢出处理:
    perf_overflow_handler_t   overflow_handler;
    void                      *overflow_handler_context;
};

struct pmu {
    const char    *name;              // "armv8_pmuv3", "software"
    int           (*event_init)(struct perf_event *event);
    void          (*start)(struct perf_event *event, int flags);
    void          (*stop)(struct perf_event *event, int flags);
    void          (*read)(struct perf_event *event);  // 读计数器
    int           (*add)(struct perf_event *event, int flags);
    void          (*del)(struct perf_event *event, int flags);
};
```

---

## 七、源文件索引

| 文件 | 内容 |
|------|------|
| `kernel/events/core.c` | perf_event_open, 采样/计数核心逻辑 |
| `kernel/events/ring_buffer.c` | ring buffer 管理 |
| `kernel/events/callchain.c` | 调用栈回溯 |
| `arch/arm64/kernel/perf_event.c` | ARM64 PMU 驱动 |
| `arch/x86/events/core.c` | x86 PMU 驱动 |
| `include/uapi/linux/perf_event.h` | 用户态 API 定义 |
| `include/linux/perf_event.h` | 内核 perf_event 结构体 |
| `tools/perf/` | perf 用户态工具源码 |
