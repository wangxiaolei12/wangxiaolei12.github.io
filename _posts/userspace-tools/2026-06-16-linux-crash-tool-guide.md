---
layout: post
title: "Linux Crash 工具深度解析：实现原理与使用指南"
date: 2026-06-16 17:50:00 +0800
excerpt: "crash 工具如何实现内核 dump 分析：基于 GDB 的符号解析、通过 vmcore/kdump 读取内存、虚拟地址翻译（页表遍历）。附完整命令使用指南：bt/ps/struct/rd/kmem/log 等。"
---

# Linux Crash 工具深度解析

---

## 一、Crash 是什么

Crash 是一个**离线内核调试器**：分析 kdump 生成的 vmcore 文件（或在线分析 /proc/kcore），还原崩溃现场。

```
系统 panic → kdump 抓 vmcore → crash 分析 vmcore
                                    │
                                    ├── 看崩溃调用栈
                                    ├── 看所有进程状态
                                    ├── 读内核数据结构
                                    ├── 看内存内容
                                    └── 找出 root cause
```

---

## 二、实现原理

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│  crash 工具                                                      │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  命令解析层                                                │  │
│  │  bt, ps, struct, rd, kmem, log, files, net, mod...        │  │
│  └────────────────────────┬──────────────────────────────────┘  │
│                           │                                     │
│  ┌────────────────────────┼──────────────────────────────────┐  │
│  │  GDB 引擎 (嵌入)       │                                  │  │
│  │  ├── 符号解析: vmlinux 的 DWARF 调试信息                   │  │
│  │  ├── 类型系统: struct 成员偏移、大小                       │  │
│  │  └── 反汇编                                               │  │
│  └────────────────────────┼──────────────────────────────────┘  │
│                           │                                     │
│  ┌────────────────────────┼──────────────────────────────────┐  │
│  │  内存访问层             │                                  │  │
│  │  readmem(vaddr/paddr) → 从 vmcore/kcore 读内存内容        │  │
│  │  ├── kvtop(): 内核虚拟地址 → 物理地址 (遍历页表)          │  │
│  │  └── 从 vmcore 的对应物理偏移处读数据                     │  │
│  └────────────────────────┼──────────────────────────────────┘  │
│                           │                                     │
│  ┌────────────────────────┼──────────────────────────────────┐  │
│  │  Dump 文件后端          │                                  │  │
│  │  ├── ELF vmcore (/proc/vmcore 格式)                       │  │
│  │  ├── makedumpfile 压缩格式 (kdump)                        │  │
│  │  ├── /proc/kcore (在线分析运行中内核)                     │  │
│  │  └── /dev/mem (老方式)                                    │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 核心机制：怎么读"死内核"的内存

crash 要做的事：**给一个内核虚拟地址，读出那个地址的内容。**

但内核已经 crash 了，MMU 也不工作了。所以 crash 自己**用软件模拟页表遍历**：

```
crash 想读 vaddr = 0xffff800012345678 的内容:

Step 1: 找到崩溃内核的 PGD (swapper_pg_dir 的物理地址，从 vmcoreinfo 获取)

Step 2: 软件模拟四级页表遍历:
  pgd_index = (vaddr >> 39) & 0x1FF → 查 PGD 表
  pud_index = (vaddr >> 30) & 0x1FF → 查 PUD 表
  pmd_index = (vaddr >> 21) & 0x1FF → 查 PMD 表
  pte_index = (vaddr >> 12) & 0x1FF → 查 PTE 表
  → 得到物理地址 paddr

Step 3: 在 vmcore 文件中找 paddr 对应的偏移:
  vmcore 是 ELF core dump，PT_LOAD 段记录了物理地址范围
  → 从文件中读出该物理地址处的内容

Step 4: 返回数据给命令层
```

源码：

```c
// crash-utility/crash: defs.h
struct program_context {
    ...
    int (*readmem)(int, void *, int, ulong, physaddr_t);
    //  读内存: fd, buffer, size, vaddr, paddr
    ...
};

#define READMEM  pc->readmem  // 全局宏调用

// 地址翻译: machdep->kvtop()
struct machdep_table {
    int (*kvtop)(struct task_context *, ulong vaddr, physaddr_t *paddr, int verbose);
    int (*uvtop)(struct task_context *, ulong vaddr, physaddr_t *paddr, int verbose);
    // kvtop: 内核虚拟地址 → 物理地址 (遍历内核页表)
    // uvtop: 用户虚拟地址 → 物理地址 (遍历进程页表)
};
```

### 2.3 怎么知道内核符号和结构体？

crash 启动时加载 **vmlinux**（带 DWARF 调试信息的内核 ELF）：

```bash
crash vmlinux vmcore
#     ^^^^^^^ ^^^^^^
#     符号+类型  内存内容

# vmlinux 提供: 
#   - 所有符号地址 (init_task, jiffies, runqueues...)
#   - 所有 struct 的成员偏移和大小 (DWARF)
#   - 函数地址范围 (用于栈回溯)
#
# vmcore 提供:
#   - 崩溃时所有物理内存的内容
#   - 每个 CPU 的寄存器 (ELF NOTE)
```

crash 内部嵌入了一个**修改版的 GDB**，用它来做符号查找和 DWARF 类型解析，但内存读取走 crash 自己的 readmem 而不是 GDB 的 ptrace。

### 2.4 vmcore 的结构 (ELF core dump)

```
vmcore 文件:
┌──────────────────────────────────────────────┐
│ ELF Header                                   │
├──────────────────────────────────────────────┤
│ PT_NOTE: CPU0 寄存器 (prstatus)              │ ← crash 用来恢复崩溃 CPU 的栈
│ PT_NOTE: CPU1 寄存器                         │
│ PT_NOTE: vmcoreinfo (内核版本/符号偏移/布局) │ ← crash 用来初始化
├──────────────────────────────────────────────┤
│ PT_LOAD: 物理地址 0x40000000~0x7FFFFFFF      │ ← 物理内存内容
│ PT_LOAD: 物理地址 0x80000000~0xBFFFFFFF      │
│ ...                                          │
└──────────────────────────────────────────────┘

crash readmem(paddr):
  → 遍历 PT_LOAD 段，找到包含 paddr 的段
  → 计算文件偏移 = segment_offset + (paddr - segment_phys_start)
  → lseek + read
```

---

## 三、使用方法

### 3.1 启动 crash

```bash
# 分析 kdump vmcore:
crash /path/to/vmlinux /path/to/vmcore

# 分析运行中的内核 (需要 root):
crash /path/to/vmlinux

# 输出:
#   KERNEL: vmlinux
#   DUMPFILE: vmcore
#   CPUS: 4
#   DATE: Mon Jun 16 10:30:00 2026
#   UPTIME: 3 days, 12:34:56
#   TASKS: 234
#   NODENAME: my-board
#   RELEASE: 6.12.0
#   PANIC: "kernel BUG at drivers/gpu/drm/xxx.c:123!"
#
# crash>    ← 交互式命令行
```

### 3.2 查看崩溃原因

```bash
# 崩溃时的调用栈:
crash> bt
PID: 1234  TASK: ffff800012340000  CPU: 2  COMMAND: "my_app"
 #0 [ffff80001234fa00] die at ffffffc0080a1234
 #1 [ffff80001234fa40] bug_handler at ffffffc0080a5678
 #2 [ffff80001234fa80] drm_atomic_commit at ffffffc008567890
 #3 [ffff80001234fac0] my_driver_update at ffffffc00890abcd
 #4 [ffff80001234fb00] ...

# 查看特定进程的栈:
crash> bt <PID>
crash> bt -a     # 所有 CPU 的栈
crash> bt -l     # 带行号
```

### 3.3 查看进程信息

```bash
# 所有进程:
crash> ps
   PID  PPID  CPU  TASK              ST  %MEM  COMMAND
      1     0   0  ffff800010000000  IN   0.1  systemd
    234   1    1  ffff800011000000  RU   2.3  my_app
>  1234  234   2  ffff800012340000  PA   0.5  my_thread   ← > = 崩溃的

# PA = panic, RU = running, IN = interruptible, UN = uninterruptible

# 查看特定进程详情:
crash> task <PID>

# 查看进程打开的文件:
crash> files <PID>

# 查看进程的内存映射:
crash> vm <PID>
```

### 3.4 读取数据结构

```bash
# 查看结构体定义:
crash> struct task_struct
struct task_struct {
    [0] struct thread_info thread_info;
    [16] unsigned int __state;
    ...
    [2048] char comm[16];
}
SIZE: 7616

# 查看特定地址处的结构体内容:
crash> struct task_struct ffff800012340000
  thread_info.flags = 0,
  __state = 0,
  ...
  comm = "my_thread\000..."

# 只看某个成员:
crash> struct task_struct.comm ffff800012340000
  comm = "my_thread"

# 查看链表:
crash> list task_struct.tasks -s task_struct.comm,pid -H init_task.tasks
ffff800010000000  comm=systemd       pid=1
ffff800011000000  comm=my_app        pid=234
...
```

### 3.5 读写内存

```bash
# 读虚拟地址处的内存 (hex dump):
crash> rd ffff800012345678 32
ffff800012345678: 0000000000000001 ffff80001234abcd

# 读物理地址:
crash> rd -p 0x80012345 16

# 按类型读:
crash> rd -32 ffff800012345678 8    # 8 个 32-bit 值
crash> rd -64 ffff800012345678 4    # 4 个 64-bit 值

# 读符号地址:
crash> rd jiffies_64
ffffffc010c12000: 00000000012345678

# 看符号值:
crash> p jiffies_64
jiffies_64 = 305419896
```

### 3.6 内核日志

```bash
# 等同 dmesg:
crash> log
[  123.456] BUG: unable to handle kernel NULL pointer dereference
[  123.456] IP: my_function+0x28/0x100
[  123.456] Call Trace:
[  123.456]  drm_atomic_commit+0x1a4/0x200
...

# 只看最后几行:
crash> log | tail -20
```

### 3.7 内存使用分析

```bash
# 内存统计:
crash> kmem -i
                 PAGES    TOTAL    PERCENTAGE
    TOTAL MEM    262144   1 GB
         FREE    120000   468 MB    45%
         USED    142144   555 MB    54%

# slab 使用:
crash> kmem -s
CACHE             OBJSIZE  ALLOCATED  TOTAL  SLABS
task_struct       7616     234        540    135
dentry            192      12453      12510  596
inode_cache       680      8234       8370   697

# 查看特定 slab cache:
crash> kmem -S task_struct
```

### 3.8 中断和锁

```bash
# 查看中断信息:
crash> irq -a
 IRQ   AFFINITY
  30   00000001  (CPU 0)
  72   00000004  (CPU 2)

# 查看 spinlock 状态:
crash> struct rq.lock <rq地址>
```

### 3.9 内核模块

```bash
# 已加载模块:
crash> mod
MODULE        NAME         SIZE    OBJECT FILE
ffff800020000 my_driver    65536   /lib/modules/.../my_driver.ko

# 加载模块符号 (如果有 .ko 文件):
crash> mod -s my_driver /path/to/my_driver.ko
```

---

## 四、实战：分析一个 NULL 指针崩溃

```bash
# 1. 看崩溃信息
crash> log | grep "BUG\|Oops\|Unable"
[123.456] BUG: kernel NULL pointer dereference, address: 0000000000000028
[123.456] IP: drm_connector_get_modes+0x18/0x50

# 2. 看崩溃栈
crash> bt
 #0 die
 #1 do_page_fault           ← 缺页异常
 #2 drm_connector_get_modes ← 这里出的问题
 #3 drm_helper_probe_single_connector_modes
 #4 ...

# 3. 看崩溃时的寄存器
crash> bt -f
 #2 drm_connector_get_modes
    x0 = 0000000000000000    ← connector 指针是 NULL！
    x1 = ffff80001234abcd

# 4. 看那个函数在做什么
crash> dis drm_connector_get_modes
0xffffffc008567890:  ldr x2, [x0, #0x28]   ← 访问 x0+0x28，但 x0=NULL！

# 5. 确认 offset 0x28 是什么
crash> struct drm_connector
    [0x28] const struct drm_connector_helper_funcs *helper_private;

# 结论: connector->helper_private 访问时 connector 为 NULL
```

---

## 五、常用命令速查

| 命令 | 用途 |
|------|------|
| `bt` | 崩溃/指定进程的调用栈 |
| `bt -a` | 所有 CPU 的调用栈 |
| `ps` | 进程列表 |
| `struct <type> <addr>` | 读结构体 |
| `p <symbol>` | 读符号值 |
| `rd <addr> <count>` | hex dump |
| `log` | 内核日志 (dmesg) |
| `kmem -i` | 内存统计 |
| `kmem -s` | slab 统计 |
| `files <PID>` | 进程打开的文件 |
| `vm <PID>` | 进程虚拟内存映射 |
| `irq` | 中断信息 |
| `mod` | 已加载模块 |
| `dis <func>` | 反汇编 |
| `sym <addr>` | 地址→符号名 |
| `list` | 遍历链表 |
| `search` | 在内存中搜索 |
| `foreach <cmd>` | 对所有进程执行命令 |
| `set <PID>` | 切换当前进程上下文 |

---

## 六、源码结构

| 文件 | 功能 |
|------|------|
| `main.c` | 启动入口、命令循环 |
| `kernel.c` | 内核版本检测、初始化 |
| `task.c` | 进程相关: ps, bt, files |
| `memory.c` | 内存读取: readmem, kmem |
| `arm64.c` | ARM64 页表遍历 (kvtop/uvtop) |
| `x86_64.c` | x86_64 页表遍历 |
| `symbols.c` | 符号管理 (基于嵌入 GDB) |
| `gdb_interface.c` | GDB 集成接口 |
| `diskdump.c` | makedumpfile 格式读取 |
| `netdump.c` | ELF vmcore 格式读取 |
| `defs.h` | 核心结构体定义 |
