---
layout: post
title: "ARM64 体系架构与 Linux 中断处理全路径分析"
date: 2026-05-26 20:00:00 +0800
excerpt: "详解 ARM64 异常级别、MMU 页表、Cache 体系、GIC 中断控制器，以及 Linux 内核从异常向量表到驱动 handler 的完整中断处理代码路径。"
---

# ARM64 体系架构与 Linux 中断处理全路径分析

## 一、异常级别与寄存器

### 1.1 异常级别

```
┌─────────────────────────────────────────┐
│  EL3 - Secure Monitor (ATF/TF-A)       │  ← 最高特权，安全世界切换
├─────────────────────────────────────────┤
│  EL2 - Hypervisor (KVM)                │  ← 虚拟化
├─────────────────────────────────────────┤
│  EL1 - OS Kernel (Linux)               │  ← 内核态
├─────────────────────────────────────────┤
│  EL0 - User Application                │  ← 用户态
└─────────────────────────────────────────┘
```

**各级别的职责与特权：**

| 级别 | 特权 | 典型软件 | 可访问的寄存器 |
|------|------|----------|---------------|
| EL0 | 最低，只能访问自己的虚拟地址空间 | 用户程序 | 少量（TPIDR_EL0 等） |
| EL1 | 管理 MMU/中断/异常，控制 EL0 | Linux 内核 | `*_EL1` 系列 |
| EL2 | 虚拟化控制，拦截 EL1 操作 | KVM/Xen | `*_EL2` 系列 |
| EL3 | 安全状态切换，最高特权 | ARM Trusted Firmware | `*_EL3` 系列 |

**异常级别切换规则：**

```
向上切换（异常进入）: 只能同级或升级，不能降级
  EL0 → EL1 : SVC（系统调用）、中断、缺页
  EL1 → EL2 : HVC（Hypervisor Call）
  EL1 → EL3 : SMC（Secure Monitor Call）

向下切换（异常返回）: ERET 指令，恢复到 SPSR 记录的级别
  EL1 → EL0 : 系统调用返回、中断返回
  EL2 → EL1 : Hypervisor 返回
  EL3 → EL1 : Secure Monitor 返回
```

**每个 EL 有独立的栈指针：**

```
SP_EL0 : 用户态栈（EL0 使用）/ 内核线程栈（EL1 可选使用）
SP_EL1 : 内核态栈
SP_EL2 : Hypervisor 栈
SP_EL3 : Secure Monitor 栈

SPSel 寄存器控制 EL1 使用 SP_EL0 还是 SP_EL1
Linux 内核在 EL1 使用 SP_EL1（即 SP_ELx 模式）
```

**AArch64 vs AArch32 执行状态：**

ARM64 CPU 支持两种执行状态。高 EL 可以控制低 EL 的执行状态：
- EL1 运行 AArch64（Linux 内核）
- EL0 可以运行 AArch64 或 AArch32（兼容 32-bit 应用）

### 1.2 关键系统寄存器

| 寄存器 | 功能 |
|--------|------|
| `SCTLR_EL1` | 系统控制（MMU/Cache 使能） |
| `TCR_EL1` | 翻译控制（页大小、地址宽度） |
| `TTBR0_EL1` | 用户空间页表基地址 |
| `TTBR1_EL1` | 内核空间页表基地址 |
| `MAIR_EL1` | 内存属性索引 |
| `ESR_EL1` | 异常综合寄存器（异常原因） |
| `FAR_EL1` | 故障地址寄存器 |
| `VBAR_EL1` | 异常向量表基地址 |
| `DAIF` | 中断屏蔽位 |
| `SPSR_EL1` | 保存的程序状态 |
| `ELR_EL1` | 异常返回地址 |

### 1.3 系统寄存器详解

#### SCTLR_EL1 — 系统控制寄存器

CPU 核心功能的总开关：

```
关键位:
  M   (bit 0)  : MMU 使能。0=关闭地址翻译，1=开启
  C   (bit 2)  : Data Cache 使能
  I   (bit 12) : Instruction Cache 使能
  WXN (bit 19) : Write 权限隐含 eXecute Never（W^X 安全加固）
  EE  (bit 25) : 大小端选择
```

内核启动早期 MMU 还没开，设置好页表后写 `SCTLR_EL1.M=1` 才正式开启虚拟地址翻译。

#### TCR_EL1 — 翻译控制寄存器

配置 MMU 的翻译规则：

```
关键字段:
  T0SZ (bit 5:0)   : TTBR0 管理的地址空间大小。VA 宽度 = 64 - T0SZ
  T1SZ (bit 21:16) : TTBR1 管理的地址空间大小
  TG0  (bit 15:14) : TTBR0 的页粒度（4KB/16KB/64KB）
  TG1  (bit 31:30) : TTBR1 的页粒度
  IPS  (bit 34:32) : 物理地址宽度（32/36/40/48/52 bit）
  AS   (bit 36)    : ASID 大小（0=8bit, 1=16bit）
```

例如 Linux 默认 `T0SZ=16`，VA 宽度 = 48 bit，用户空间范围 0x0000_0000_0000_0000 ~ 0x0000_FFFF_FFFF_FFFF。

#### TTBR0_EL1 / TTBR1_EL1 — 页表基地址寄存器

```
TTBR0_EL1 (64-bit):
┌─────────────────┬──────────────────────────────────────────┐
│ ASID (bit 63:48)│ 页表物理基地址 BADDR (bit 47:1)          │
└─────────────────┴──────────────────────────────────────────┘
```

- TTBR0: 指向当前进程的用户空间页表（PGD），进程切换时更新
- TTBR1: 指向内核页表，所有进程共享，进程切换时不变

CPU 根据虚拟地址最高位选择使用哪个：bit[63]=0 用 TTBR0，bit[63]=1 用 TTBR1。

#### MAIR_EL1 — 内存属性索引寄存器

定义 8 种内存属性（每种 8 bit），页表条目通过 AttrIndx[2:0] 索引：

```
MAIR_EL1 = [Attr7 | Attr6 | ... | Attr1 | Attr0]  (64-bit, 每段8bit)

常见配置:
  Attr0 = 0x00 : Device-nGnRnE（严格设备内存，如 MMIO 寄存器）
  Attr1 = 0x04 : Device-nGnRE（设备内存，允许 Early Write Ack）
  Attr2 = 0xFF : Normal, Write-Back Cacheable（普通 RAM）
  Attr3 = 0x44 : Normal, Non-Cacheable（DMA 缓冲区）
```

页表条目里写 `AttrIndx=2` 就表示这页用 Attr2 的属性（可缓存普通内存）。

#### ESR_EL1 — 异常综合寄存器

发生异常时 CPU 自动填写异常原因：

```
关键字段:
  EC (bit 31:26) : 异常类别
    0b100100 = Data Abort from lower EL
    0b100101 = Data Abort from same EL
    0b100000 = Instruction Abort from lower EL
    0b010101 = SVC（系统调用）
    0b111100 = BRK（断点）
  ISS (bit 24:0) : 异常具体信息
    对于 Data Abort: DFSC 字段说明是 translation fault / permission fault / alignment fault
```

内核异常处理函数第一件事就是读 ESR_EL1 判断发生了什么。

#### FAR_EL1 — 故障地址寄存器

发生地址相关异常时，记录触发异常的虚拟地址：

```
例如: 进程访问 0x0000_DEAD_BEEF → page fault
  FAR_EL1 = 0x0000_DEAD_BEEF
  ESR_EL1.EC = Data Abort
  内核据此查页表，决定是 demand paging 还是 segfault
```

#### VBAR_EL1 — 异常向量表基地址

指向异常向量表起始地址。CPU 发生异常时根据类型跳转到 `VBAR_EL1 + offset`：

```
偏移量（每个入口 128 字节）:
  +0x000 : Synchronous, 当前 EL, SP_EL0
  +0x080 : IRQ, 当前 EL, SP_EL0
  +0x100 : FIQ, 当前 EL, SP_EL0
  +0x180 : SError, 当前 EL, SP_EL0
  +0x200 : Synchronous, 当前 EL, SP_ELx    ← 内核态同步异常
  +0x280 : IRQ, 当前 EL, SP_ELx            ← 内核态 IRQ
  +0x400 : Synchronous, 低 EL, AArch64     ← 用户态系统调用
  +0x480 : IRQ, 低 EL, AArch64             ← 用户态 IRQ
```

Linux 内核启动时设置 `VBAR_EL1 = vectors`（定义在 `arch/arm64/kernel/entry.S`）。

#### DAIF — 中断屏蔽位

```
D (bit 9): Debug 异常屏蔽
A (bit 8): SError（异步异常）屏蔽
I (bit 7): IRQ 屏蔽
F (bit 6): FIQ 屏蔽
```

```asm
msr daifset, #2    // 设置 I 位，屏蔽 IRQ（local_irq_disable）
msr daifclr, #2    // 清除 I 位，允许 IRQ（local_irq_enable）
```

#### SPSR_EL1 — 保存的程序状态

异常发生时 CPU 自动把当前 PSTATE 保存到 SPSR_EL1：

```
保存内容:
  N/Z/C/V   : 条件标志
  DAIF      : 中断屏蔽状态
  CurrentEL : 异常前的 EL
  SP        : 使用的 SP 选择
  nRW       : AArch64 还是 AArch32
```

异常返回（`eret`）时从 SPSR_EL1 恢复 PSTATE。

#### ELR_EL1 — 异常返回地址

异常发生时 CPU 自动保存返回地址：

- 同步异常（SVC）: ELR_EL1 = 触发异常的指令地址
- IRQ: ELR_EL1 = 被打断的下一条指令地址

`eret` 执行时 PC 跳转到 ELR_EL1，回到异常前的执行点。

#### 寄存器协作示例

```
用户态系统调用:
  1. SVC 指令触发同步异常
  2. CPU 自动: SPSR_EL1=PSTATE, ELR_EL1=PC+4, ESR_EL1.EC=SVC
  3. PC 跳转到 VBAR_EL1 + 0x400
  4. 内核读 ESR_EL1 确认是 SVC，读 x8 得到系统调用号
  5. 处理完毕，eret → SPSR→PSTATE, ELR→PC

缺页异常:
  1. 访问未映射地址 → Data Abort
  2. CPU 自动: ESR_EL1=原因, FAR_EL1=故障地址
  3. 内核用 FAR_EL1 查 TTBR0_EL1 指向的页表
  4. 分配物理页，填页表，eret 返回重新执行
```


## 二、MMU

### 2.1 虚拟地址空间划分

```
0x0000_0000_0000_0000 ┌──────────────────┐
                      │  用户空间 (256TB) │  ← TTBR0_EL1
0x0000_FFFF_FFFF_FFFF ├──────────────────┤
                      │  非规范地址空洞    │
0xFFFF_0000_0000_0000 ├──────────────────┤
                      │  内核空间 (256TB) │  ← TTBR1_EL1
0xFFFF_FFFF_FFFF_FFFF └──────────────────┘

bit[63]=0 → TTBR0    bit[63]=1 → TTBR1
```

### 2.2 4级页表（4KB粒度）

```
虚拟地址 (48-bit):
┌────────┬────────┬────────┬────────┬────────────┐
│L0[8:0] │L1[8:0] │L2[8:0] │L3[8:0] │Offset[11:0]│
│ 9 bits │ 9 bits │ 9 bits │ 9 bits │  12 bits   │
└────┬───┴────┬───┴────┬───┴────┬───┴────────────┘
     ▼        ▼        ▼        ▼
   PGD      PUD      PMD      PTE → 物理页(4KB)
```

映射粒度：L1=1GB Block, L2=2MB Block, L3=4KB Page

### 2.3 页表项格式

```
┌─────────────────────────────────────────────────────────┐
│63  59│58 55│54 52│51    12│11        2│1│0│
├──────┼─────┼─────┼────────┼───────────┼─┼─┤
│ PBHA │ SW  │UXN  │输出地址 │  属性位    │T│V│
│      │     │PXN  │[51:12] │           │ │ │
└──────┴─────┴─────┴────────┴───────────┴─┴─┘
属性位: AttrIndx[2:0], AP[2:1], SH[1:0], AF, nG
```

### 2.4 ASID（Address Space Identifier）

#### 为什么需要 ASID

没有 ASID 时，每次进程切换都必须 flush 整个 TLB——因为不同进程的相同虚拟地址映射到不同物理地址，TLB 中残留的旧映射会导致错误访问。flush TLB 后所有内存访问都要重新 page table walk，性能严重下降。

#### ASID 的原理

给每个 TLB 条目打上"属于哪个进程"的标签：

```
TLB 条目:
┌──────┬────────────────┬────────────────┬───────┐
│ ASID │ 虚拟地址 (VA)  │ 物理地址 (PA)  │ 属性  │
└──────┴────────────────┴────────────────┴───────┘

查找规则: VA 匹配 AND ASID 匹配 → TLB Hit
```

不同进程即使用相同虚拟地址，ASID 不同就不会互相干扰。

#### ASID 在 TTBR0_EL1 中的位置

```
TTBR0_EL1:
┌─────────────────┬──────────────────────────────────────────┐
│ ASID (bit 63:48)│ 页表物理基地址 (bit 47:1)                │
└─────────────────┴──────────────────────────────────────────┘
```

进程切换时内核只需写一次 TTBR0_EL1，同时更新页表基地址和 ASID。

#### ASID 位宽

由 `TCR_EL1.AS` 控制：
- AS=0: 8-bit，最多 256 个
- AS=1: 16-bit，最多 65536 个

Linux ARM64 通常使用 16-bit ASID。

#### Linux 内核的 ASID 管理 — Generation 机制

ASID 数量有限，但进程可能更多。Linux 采用 generation 计数：

```
64-bit context.id (每个 mm_struct):
┌──────────────────────┬────────────────────────┐
│ generation (高位)     │ ASID value (低16位)    │
└──────────────────────┴────────────────────────┘
```

**进程切换时的判断逻辑：**

```c
// arch/arm64/mm/context.c
void check_and_switch_context(struct mm_struct *mm)
{
    unsigned long asid = atomic64_read(&mm->context.id);

    // 快速路径：generation 匹配，ASID 仍然有效
    if ((asid ^ atomic64_read(&asid_generation)) >> asid_bits == 0) {
        cpu_switch_mm(mm->pgd, mm);  // 只写 TTBR0_EL1，无需 flush
        return;
    }

    // 慢速路径：ASID 已过期，需要分配新的
    asid = new_context(mm);
    cpu_switch_mm(mm->pgd, mm);
}
```

**ASID 耗尽时（rollover）：**

```
所有 65536 个 ASID 都分配完了
    ↓
generation + 1
    ↓
flush 所有 CPU 的 TLB（全局一次性代价）
    ↓
重新从 1 开始分配 ASID
```

实际系统中 rollover 很少发生。

#### Global 页 vs Non-Global 页

页表条目中的 nG 位决定 TLB 条目是否受 ASID 约束：

```
nG=0（Global）  : 内核映射，TLB 查找时忽略 ASID，所有进程共享
nG=1（Non-Global）: 用户空间映射，TLB 查找时必须 ASID 匹配
```

这就是为什么内核页表（TTBR1）不需要 ASID——内核映射的 TLB 条目是 Global 的，进程切换后仍然有效。

#### ASID 带来的性能提升

| 场景 | 无 ASID | 有 ASID |
|------|---------|---------|
| 进程切换 | flush 整个 TLB | 只写 TTBR0_EL1 |
| 切换后首次访问 | 必然 TLB miss | 可能 TLB hit（旧条目仍在） |
| TLB 利用率 | 低（频繁失效） | 高（多进程条目共存） |
| 代价 | 每次切换都慢 | 仅 rollover 时全局 flush |

## 三、Cache 体系

### 3.1 层次结构

```
┌───────┐     ┌───────┐
│ Core 0│     │ Core 1│
│┌─────┐│     │┌─────┐│
││L1-I ││     ││L1-I ││  ← 32-64KB
│├─────┤│     │├─────┤│
││L1-D ││     ││L1-D ││  ← 32-64KB
│└──┬──┘│     │└──┬──┘│
│┌──▼──┐│     │┌──▼──┐│
││ L2  ││     ││ L2  ││  ← 256KB-1MB
│└──┬──┘│     │└──┬──┘│
└───┼───┘     └───┼───┘
    └──────┬──────┘
     ┌─────▼─────┐
     │  L3 共享   │  ← 4-32MB
     └─────┬─────┘
           ▼
        主存 DRAM
```

### 3.2 内存属性（MAIR）

| 属性 | 编码 | 用途 |
|------|------|------|
| Normal-WB | 0xFF | 普通 RAM（最常用） |
| Normal-NC | 0x44 | DMA 缓冲区 |
| Device-nGnRnE | 0x00 | MMIO 寄存器 |

### 3.3 Cache 维护指令

```
DC CIVAC, Xt    // Clean+Invalidate（刷回内存+无效化）
DC CVAC, Xt     // Clean（仅刷回内存）
DC IVAC, Xt     // Invalidate（仅无效化，慎用！可能丢数据）
IC IALLU        // Invalidate 所有指令缓存
```

**使用场景：**

| 场景 | 操作 | 原因 |
|------|------|------|
| DMA 设备写内存后 CPU 读 | DC IVAC | CPU cache 中可能有旧数据 |
| CPU 写内存后 DMA 设备读 | DC CVAC | 确保数据从 cache 刷到内存 |
| 自修改代码 / 模块加载 | DC CVAC + IC IALLU + ISB | 确保指令缓存看到新代码 |
| kexec / 关闭 MMU 前 | DC CIVAC 全部 | 确保所有脏数据写回 |

### 3.4 内存屏障

ARM64 是弱内存序架构，CPU 和编译器可能重排内存访问。屏障指令强制顺序：

```
DMB (Data Memory Barrier):
  保证 DMB 前的内存访问在 DMB 后的之前完成（对其他观察者可见）
  用途: smp_mb(), smp_rmb(), smp_wmb()

DSB (Data Synchronization Barrier):
  比 DMB 更强，还保证 DSB 前的所有指令（包括 cache/TLB 维护）完成
  用途: TLB flush 后、cache 维护后

ISB (Instruction Synchronization Barrier):
  刷新流水线，确保 ISB 后的指令看到之前的系统寄存器修改
  用途: 写 SCTLR/TTBR/VBAR 后

LDAR/STLR (Load-Acquire / Store-Release):
  单条指令级别的屏障，比 DMB 轻量
  LDAR: 之后的读写不会重排到它之前
  STLR: 之前的读写不会重排到它之后
  用途: spinlock 实现
```

**屏障的 shareability domain：**

```
ISH (Inner Shareable): 同一个 cache coherency domain 内的所有 CPU
OSH (Outer Shareable): 包括 GPU、DMA 等外部 master
SY  (Full System): 整个系统

例: DMB ISH  → 对所有 CPU 可见（最常用）
    DMB OSH  → 对 CPU + DMA 设备可见
```

**Linux 内核中的对应关系：**

```c
smp_mb()   → DMB ISH      // 全屏障
smp_rmb()  → DMB ISHLD    // 读屏障
smp_wmb()  → DMB ISHST    // 写屏障
mb()       → DSB SY       // 系统级全屏障（含设备）
rmb()      → DSB ISHLD
wmb()      → DSB ISHST
```

### 3.5 Cache Coherency（缓存一致性）

ARM64 多核系统通过硬件协议维护 cache 一致性：

```
┌────────┐    ┌────────┐
│ Core 0 │    │ Core 1 │
│ L1 Cache│    │ L1 Cache│
└───┬────┘    └───┬────┘
    │   MOESI/MESI 协议    │
    └─────────┬────────────┘
              │ Snoop Filter / Directory
              ▼
         ┌─────────┐
         │ L3/LLC  │
         └────┬────┘
              ▼
           主存 DRAM
```

- **硬件保证**：多核之间的 cache 一致性由 ACE/CHI 协议自动维护
- **软件需要关心**：CPU 与非 coherent 设备（DMA）之间的一致性，需要手动 cache 维护或使用 DMA coherent 映射


## 四、GIC 中断控制器

### 4.1 GICv3 架构

```
┌─────────────────────────────────────────┐
│          GIC Distributor (GICD)          │  ← 全局，中断路由/优先级
├─────────────────────────────────────────┤
│    ┌────────┐  ┌────────┐  ┌────────┐  │
│    │ GICR 0 │  │ GICR 1 │  │ GICR 2 │  │  ← Per-CPU Redistributor
│    └───┬────┘  └───┬────┘  └───┬────┘  │
│    ┌───▼────┐  ┌───▼────┐  ┌───▼────┐  │
│    │ICC_*   │  │ICC_*   │  │ICC_*   │  │  ← CPU Interface (系统寄存器)
│    └───┬────┘  └───┬────┘  └───┬────┘  │
│        ▼           ▼           ▼        │
│     Core 0      Core 1      Core 2     │
└─────────────────────────────────────────┘
```

### 4.2 中断类型

| 类型 | ID 范围 | 说明 |
|------|---------|------|
| SGI | 0-15 | 软件生成（IPI 核间通信） |
| PPI | 16-31 | 私有外设（定时器、PMU） |
| SPI | 32-1019 | 共享外设（UART、网卡） |
| LPI | 8192+ | 消息中断（PCIe MSI） |

## 五、Linux 中断处理完整路径

### 5.1 异常向量表

```c
// arch/arm64/kernel/entry.S
SYM_CODE_START(vectors)
    kernel_ventry  1, h, 64, sync     // +0x200 内核态同步异常
    kernel_ventry  1, h, 64, irq      // +0x280 内核态 IRQ ★
    kernel_ventry  1, h, 64, fiq      // +0x300 内核态 FIQ
    kernel_ventry  1, h, 64, error    // +0x380 内核态 SError

    kernel_ventry  0, t, 64, sync     // +0x400 用户态同步异常(syscall)
    kernel_ventry  0, t, 64, irq      // +0x480 用户态 IRQ ★
    kernel_ventry  0, t, 64, fiq      // +0x500
    kernel_ventry  0, t, 64, error    // +0x580
SYM_CODE_END(vectors)
```

### 5.2 汇编入口

```asm
// kernel_ventry: 128字节对齐，栈溢出检测后跳转
// entry_handler: 保存寄存器 + 调用 C handler

.macro entry_handler el, ht, regsize, label
    kernel_entry \el, \regsize    // 保存 x0-x29, LR, SP, PC, PSTATE
    mov   x0, sp                  // pt_regs 指针作为参数
    bl    el\el\ht_\regsize_\label_handler  // 调用 C 函数
    b     ret_to_kernel / ret_to_user
.endm
```

`kernel_entry` 保存的内容：

```asm
stp  x0, x1, [sp, #16 * 0]      // 保存 x0-x29
...
stp  x28, x29, [sp, #16 * 14]
mrs  x22, elr_el1               // 保存返回地址
mrs  x23, spsr_el1              // 保存 PSTATE
stp  x22, x23, [sp, #S_PC]
```

### 5.3 C 层处理（entry-common.c）

```c
// 内核态 IRQ
asmlinkage void noinstr el1h_64_irq_handler(struct pt_regs *regs)
{
    el1_interrupt(regs, handle_arch_irq);
}

static void __el1_irq(struct pt_regs *regs, void (*handler)(struct pt_regs *))
{
    irqentry_state_t state = arm64_enter_from_kernel_mode(regs);
    irq_enter_rcu();                    // preempt_count += HARDIRQ_OFFSET
    do_interrupt_handler(regs, handler); // 切换 IRQ 栈，调用 GIC handler
    irq_exit_rcu();                     // 处理 softirq
    arm64_exit_to_kernel_mode(regs, state);
}

// 用户态 IRQ
static void el0_interrupt(struct pt_regs *regs, void (*handler)(struct pt_regs *))
{
    arm64_enter_from_user_mode(regs);
    irq_enter_rcu();
    do_interrupt_handler(regs, handler);
    irq_exit_rcu();
    arm64_exit_to_user_mode(regs);      // 检查信号/调度
}

// IRQ 栈切换
static void do_interrupt_handler(struct pt_regs *regs, void (*handler)(struct pt_regs *))
{
    if (on_thread_stack())
        call_on_irq_stack(regs, handler);  // 切到独立 IRQ 栈
    else
        handler(regs);
}
```

### 5.4 GIC 驱动层

```c
// drivers/irqchip/irq-gic-v3.c
// 初始化: set_handle_irq(gic_handle_irq)

static void __gic_handle_irq(u32 irqnr, struct pt_regs *regs)
{
    gic_complete_ack(irqnr);            // 写 ICC_EOIR1_EL1 (EOI)
    generic_handle_domain_irq(gic_data.domain, irqnr);  // → 通用层
}

static void __gic_handle_irq_from_irqson(struct pt_regs *regs)
{
    u32 irqnr = gic_read_iar();         // 读 ICC_IAR1_EL1 (ACK+获取中断号)
    bool is_nmi = gic_rpr_is_nmi_prio();

    if (is_nmi) { nmi_enter(); __gic_handle_nmi(irqnr, regs); nmi_exit(); }
    gic_pmr_mask_irqs();                // 屏蔽普通IRQ，允许NMI嵌套
    gic_arch_enable_irqs();
    if (!is_nmi) __gic_handle_irq(irqnr, regs);
}
```

### 5.5 通用中断层

```c
// kernel/irq/irqdesc.h
generic_handle_irq_desc(desc) → desc->handle_irq(desc)

// kernel/irq/chip.c - GIC 最常用的流控函数
void handle_fasteoi_irq(struct irq_desc *desc)
{
    raw_spin_lock(&desc->lock);
    kstat_incr_irqs_this_cpu(desc);
    handle_irq_event(desc);             // 调用驱动 handler
    cond_unmask_eoi_irq(desc, chip);    // EOI
    raw_spin_unlock(&desc->lock);
}

// kernel/irq/handle.c
irqreturn_t __handle_irq_event_percpu(struct irq_desc *desc)
{
    for_each_action_of_desc(desc, action) {
        res = action->handler(irq, action->dev_id);  // ★ 驱动 handler
        if (res == IRQ_WAKE_THREAD)
            __irq_wake_thread(desc, action);          // 唤醒中断线程
    }
}
```

### 5.6 核心数据结构

```c
struct irq_desc {
    struct irq_data      irq_data;      // hwirq, chip
    irq_flow_handler_t   handle_irq;    // handle_fasteoi_irq 等
    struct irqaction     *action;       // 驱动 handler 链表
    raw_spinlock_t       lock;
};

struct irqaction {
    irq_handler_t        handler;       // 硬中断函数
    irq_handler_t        thread_fn;     // 线程化函数
    struct task_struct   *thread;       // 中断线程
    void                 *dev_id;
    unsigned int         flags;         // IRQF_SHARED 等
};
```

### 5.7 完整调用链

```
硬件中断 → GIC 路由到 CPU
  │
  ▼ CPU 跳转 VBAR_EL1+0x280
kernel_ventry 1,h,64,irq              [entry.S]
  │ kernel_entry 1 (保存寄存器)
  ▼
el1h_64_irq_handler(pt_regs)          [entry-common.c]
  │ irq_enter_rcu()
  ▼
do_interrupt_handler → call_on_irq_stack
  ▼
gic_handle_irq(regs)                  [irq-gic-v3.c]
  │ irqnr = gic_read_iar()  (ACK)
  │ gic_complete_ack()       (EOI)
  ▼
generic_handle_domain_irq(domain, hwirq)
  ▼
desc->handle_irq(desc)                [chip.c]
  │ = handle_fasteoi_irq()
  ▼
handle_irq_event → action->handler(irq, dev_id)  ← 驱动代码
  │
  │ 返回 IRQ_WAKE_THREAD → 唤醒中断线程
  ▼
irq_exit_rcu()                        [softirq.c]
  │ invoke_softirq() (如有 pending)
  ▼
ret_to_kernel: kernel_exit 1 → ERET   [entry.S]
```

### 5.8 中断线程化示例

```c
static irqreturn_t my_hardirq(int irq, void *dev_id)
{
    writel(IRQ_CLEAR, dev->regs + STATUS);  // 快速清中断
    return IRQ_WAKE_THREAD;
}

static irqreturn_t my_thread_fn(int irq, void *dev_id)
{
    // 可睡眠，做耗时处理
    process_data(dev);
    return IRQ_HANDLED;
}

request_threaded_irq(irq, my_hardirq, my_thread_fn,
                     IRQF_ONESHOT, "my-dev", dev);
```
