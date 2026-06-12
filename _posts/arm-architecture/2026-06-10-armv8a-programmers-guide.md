---
layout: post
title: "【ARM 官方文档翻译】ARMv8-A 架构程序员指南"
date: 2026-06-10 15:40:00 +0800
excerpt: "ARM 官方 ARMv8-A Programmer's Guide (DEN0024) 核心内容中文翻译，面向程序员视角介绍 AArch64 执行状态、异常模型、内存管理和缓存操作。"
---

# ARMv8-A 架构程序员指南

> 原文：[ARMv8-A Architecture Programmer's Guide (DEN0024)](https://developer.arm.com/documentation/den0024/latest/)
>
> 本文基于 ARM 官方文档翻译，面向程序员视角介绍 ARMv8-A 架构核心概念。

---

## 1. ARMv8-A 架构基础

### 执行状态

ARMv8-A 定义两种执行状态：

| 执行状态 | 寄存器宽度 | 指令集 | 特点 |
|---------|-----------|--------|------|
| AArch64 | 64位 | A64 | 31个64位通用寄存器，PC不在通用寄存器中 |
| AArch32 | 32位 | A32/T32 | 兼容ARMv7，16个32位通用寄存器 |

### 异常级别

```
┌────────────────────────────────────────────────────────────────┐
│                                                                 │
│  EL3  ┌─────────────────────────────────────────────────────┐  │
│       │ Secure Monitor                                       │  │
│       │ - 管理 Secure/Non-secure 世界切换                    │  │
│       │ - 运行在 Secure 状态                                 │  │
│       │ - 执行 SMC (Secure Monitor Call) 响应                │  │
│       └─────────────────────────────────────────────────────┘  │
│                                                                 │
│  EL2  ┌─────────────────────────────────────────────────────┐  │
│       │ Hypervisor                                           │  │
│       │ - 虚拟化支持                                         │  │
│       │ - 控制 Stage 2 地址转换                              │  │
│       │ - 陷入 (trap) EL1 的系统寄存器访问                   │  │
│       │ - 执行 HVC (Hypervisor Call) 响应                    │  │
│       └─────────────────────────────────────────────────────┘  │
│                                                                 │
│  EL1  ┌─────────────────────────────────────────────────────┐  │
│       │ Operating System Kernel                              │  │
│       │ - 管理 Stage 1 页表                                  │  │
│       │ - 处理异常和中断                                     │  │
│       │ - 管理系统资源                                       │  │
│       │ - 执行 SVC (Supervisor Call) 响应                    │  │
│       └─────────────────────────────────────────────────────┘  │
│                                                                 │
│  EL0  ┌─────────────────────────────────────────────────────┐  │
│       │ User Application                                     │  │
│       │ - 非特权执行                                         │  │
│       │ - 不能直接访问硬件                                   │  │
│       │ - 通过 SVC 请求内核服务                              │  │
│       └─────────────────────────────────────────────────────┘  │
│                                                                 │
└────────────────────────────────────────────────────────────────┘

特权升序：EL0 < EL1 < EL2 < EL3
异常只能转到相同或更高 EL
异常返回只能到相同或更低 EL
```

### 安全模型 (TrustZone)

```
┌───────────────────────┐     ┌───────────────────────┐
│    Non-secure World   │     │    Secure World       │
│                       │     │                       │
│  EL0: Normal Apps     │     │  S.EL0: Trusted Apps  │
│  EL1: Normal OS       │     │  S.EL1: Trusted OS    │
│  EL2: Hypervisor      │     │  S.EL2: (Armv8.4+)   │
│                       │     │                       │
└───────────┬───────────┘     └───────────┬───────────┘
            │                              │
            └──────────┬───────────────────┘
                       │
              ┌────────▼────────┐
              │  EL3: Secure    │
              │  Monitor (SMC)  │
              └─────────────────┘
```

---

## 2. AArch64 寄存器

### 通用寄存器

```
64位视图:  X0  X1  X2  ... X28 X29(FP) X30(LR)  SP
32位视图:  W0  W1  W2  ... W28 W29     W30      WSP

特殊寄存器:
  PC   — 程序计数器 (不可直接读写，通过 ADR/ADRP 获取)
  SP   — 栈指针 (每个 EL 有独立 SP_ELx)
  XZR  — 零寄存器 (读取永远为 0，写入被丢弃)

过程调用标准 (AAPCS64):
  X0-X7   : 参数/返回值寄存器
  X8      : 间接结果位置寄存器
  X9-X15  : 调用者保存的临时寄存器
  X16-X17 : 过程内调用临时寄存器 (IP0, IP1)
  X18     : 平台寄存器
  X19-X28 : 被调用者保存的寄存器
  X29     : 帧指针 (FP)
  X30     : 链接寄存器 (LR)
```

### PSTATE 和条件标志

```
条件标志 (NZCV):
  N — 负标志 (结果为负时设置)
  Z — 零标志 (结果为零时设置)
  C — 进位标志
  V — 溢出标志

处理器状态字段:
  D — 调试屏蔽
  A — SError 屏蔽
  I — IRQ 屏蔽
  F — FIQ 屏蔽
  CurrentEL — 当前异常级别
  SPSel — 栈指针选择 (0=SP_EL0, 1=SP_ELx)
```

---

## 3. A64 指令集概述

### 指令编码

A64 指令集使用固定 32 位指令编码。所有指令 4 字节对齐。

### 主要指令类别

```
┌────────────────────────────────────────────────────────────────┐
│  数据处理 (寄存器)                                              │
│  ADD, SUB, AND, ORR, EOR, MOV, MVN, ...                        │
│  MADD, MSUB, SMULL, UMULL, ...                                 │
├────────────────────────────────────────────────────────────────┤
│  数据处理 (立即数)                                              │
│  ADD #imm, SUB #imm, MOVZ, MOVK, MOVN, ...                    │
├────────────────────────────────────────────────────────────────┤
│  加载/存储                                                      │
│  LDR, STR, LDP, STP, LDXR, STXR, LDAR, STLR, ...             │
│  寻址模式: [base], [base, #offset], [base, #offset]!, ...      │
├────────────────────────────────────────────────────────────────┤
│  分支                                                           │
│  B, BL, BR, BLR, RET, B.cond, CBZ, CBNZ, TBZ, TBNZ           │
├────────────────────────────────────────────────────────────────┤
│  系统                                                           │
│  SVC, HVC, SMC, MSR, MRS, NOP, WFI, WFE, ISB, DSB, DMB       │
├────────────────────────────────────────────────────────────────┤
│  SIMD & 浮点                                                   │
│  FADD, FMUL, FCMP, FCVT, LD1, ST1, ADD (vector), ...          │
└────────────────────────────────────────────────────────────────┘
```

### Load/Store 寻址模式

```asm
// 基址 + 偏移 (无更新)
LDR X0, [X1, #8]        // X0 = *(X1 + 8)

// 前索引 (先更新基址)
LDR X0, [X1, #8]!       // X1 = X1 + 8; X0 = *X1

// 后索引 (后更新基址)
LDR X0, [X1], #8        // X0 = *X1; X1 = X1 + 8

// 寄存器偏移
LDR X0, [X1, X2]        // X0 = *(X1 + X2)

// 寄存器偏移 + 移位
LDR X0, [X1, X2, LSL #3]  // X0 = *(X1 + X2*8)

// PC 相对 (用于字面量池)
LDR X0, label            // X0 = *label (PC 相对)

// Load Pair / Store Pair
LDP X0, X1, [SP], #16   // 从栈弹出两个寄存器
STP X29, X30, [SP, #-16]!  // 压入帧指针和链接寄存器
```

---

## 4. 异常处理

### 异常类型

| 类型 | 描述 | 示例 |
|------|------|------|
| Synchronous | 由指令执行直接触发 | SVC/HVC/SMC、未定义指令、数据中止、指令中止 |
| IRQ | 普通中断请求 | 外设中断 |
| FIQ | 快速中断请求 | 安全中断 |
| SError | 系统错误（异步） | 异步外部数据中止 |

### 异常进入过程

当异常发生时，硬件自动执行：

```
1. PSTATE 保存到 SPSR_ELx
2. 返回地址保存到 ELR_ELx
3. PSTATE.DAIF 根据异常类型设置屏蔽位
4. 执行状态可能切换 (AArch32 → AArch64)
5. SP 切换到目标 EL 的 SP_ELx
6. PC 设置到 VBAR_ELx + offset (异常向量)
```

### 异常返回

```asm
ERET    // 从异常返回
        // 硬件自动: PSTATE = SPSR_ELx; PC = ELR_ELx
```

### 典型异常向量表

```asm
.align 11               // 向量表必须 2KB 对齐
vector_table:
    // 当前 EL, 使用 SP_EL0
    .align 7
    b sync_sp0          // +0x000: Synchronous
    .align 7
    b irq_sp0           // +0x080: IRQ
    .align 7
    b fiq_sp0           // +0x100: FIQ
    .align 7
    b serror_sp0        // +0x180: SError

    // 当前 EL, 使用 SP_ELx
    .align 7
    b sync_spx          // +0x200: Synchronous
    .align 7
    b irq_spx           // +0x280: IRQ
    .align 7
    b fiq_spx           // +0x300: FIQ
    .align 7
    b serror_spx        // +0x380: SError

    // 来自低 EL, AArch64
    .align 7
    b sync_lower_a64    // +0x400: Synchronous
    .align 7
    b irq_lower_a64     // +0x480: IRQ
    ...
```

---

## 5. 内存管理

### 虚拟内存布局 (EL0/EL1)

```
0xFFFFFFFF_FFFFFFFF ┌──────────────────────┐
                    │   内核空间            │ ← TTBR1_EL1
                    │   (高地址)            │
0xFFFF0000_00000000 ├──────────────────────┤
                    │                      │
                    │   无效区域            │ ← 访问产生 fault
                    │   (地址空洞)          │
                    │                      │
0x0000FFFF_FFFFFFFF ├──────────────────────┤
                    │   用户空间            │ ← TTBR0_EL1
                    │   (低地址)            │
0x00000000_00000000 └──────────────────────┘
```

### 页表格式 (4KB 粒度, 48位 VA)

```
虚拟地址 [47:0] 分解:

 47    39 38    30 29    21 20    12 11      0
┌────────┬────────┬────────┬────────┬─────────┐
│L0 索引 │L1 索引 │L2 索引 │L3 索引 │页内偏移  │
│ (9位)  │ (9位)  │ (9位)  │ (9位)  │ (12位)  │
└────┬───┴────┬───┴────┬───┴────┬───┴─────────┘
     │        │        │        │
     ▼        ▼        ▼        ▼
  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
  │L0 表 │→│L1 表 │→│L2 表 │→│L3 表 │→ 物理页帧
  │512项 │ │512项 │ │512项 │ │512项 │
  └──────┘ └──────┘ └──────┘ └──────┘
   每项覆盖  每项覆盖  每项覆盖  每项覆盖
   512GB     1GB      2MB      4KB
```

### 页表条目属性

```
63  54 53  48 47          12 11    2  1 0
┌─────┬──────┬──────────────┬───────┬───┐
│上层 │ 保留 │  输出地址     │ 下层  │类型│
│属性 │      │  [47:12]     │ 属性  │   │
└─────┴──────┴──────────────┴───────┴───┘

类型 (bits[1:0]):
  0b00 = Invalid (无效)
  0b01 = Block descriptor (L1/L2)
  0b11 = Table descriptor (L0/L1/L2) 或 Page descriptor (L3)

下层属性包括:
  - AttrIndx[2:0]: 索引到 MAIR_EL1 中的内存属性
  - NS: Non-secure 位
  - AP[2:1]: 访问权限 (EL0/EL1, 读/写)
  - SH[1:0]: 共享性 (Non-shareable, Inner, Outer)
  - AF: 访问标志
  - nG: 非全局位 (需要 ASID 匹配)

上层属性包括:
  - PXN: 特权执行从不
  - UXN: 非特权执行从不
  - Contiguous: 连续提示
```

---

## 6. 缓存操作

### 缓存维护指令

```asm
// 按虚拟地址操作 (Point of Coherency)
DC CIVAC, X0    // Clean and Invalidate by VA to PoC
DC CVAC, X0     // Clean by VA to PoC
DC IVAC, X0     // Invalidate by VA to PoC (特权)

// 按虚拟地址操作 (Point of Unification)
DC CVAU, X0     // Clean by VA to PoU
IC IVAU, X0     // Invalidate instruction cache by VA to PoU

// 按 Set/Way 操作
DC ISW, X0      // Invalidate by Set/Way
DC CSW, X0      // Clean by Set/Way
DC CISW, X0     // Clean and Invalidate by Set/Way

// 全部操作
IC IALLU        // Invalidate all instruction caches to PoU
```

### 自修改代码的典型序列

```asm
// 写入新指令到内存
STR W0, [X1]           // 写新指令

// 确保指令对数据缓存可见
DC CVAU, X1            // Clean data cache by VA to Point of Unification

// 确保 clean 完成
DSB ISH

// 使指令缓存中的旧内容无效
IC IVAU, X1            // Invalidate instruction cache by VA

// 确保 invalidate 完成
DSB ISH

// 同步指令流
ISB

// 此处可以安全执行新指令
```

---

## 7. 内存排序和屏障

### 内存类型

| 类型 | 特性 | 用途 |
|------|------|------|
| Normal (可缓存) | 可重排序、可合并、可推测、可缓存 | 代码和数据 |
| Normal (不可缓存) | 可重排序、可合并、可推测、不缓存 | DMA 缓冲区 |
| Device-nGnRnE | 不聚合、不重排序、不提前访问、无写入合并 | 严格外设 |
| Device-nGnRE | 不聚合、不重排序、不提前访问、允许提前写确认 | 大多数外设 |
| Device-nGRE | 不聚合、允许读重排序 | |
| Device-GRE | 允许聚合、允许重排序 | |

### 屏障指令示例

```asm
// DMB — 确保内存访问顺序
STR W0, [X1]           // Store A
DMB ISH                // 屏障: A 在 B 之前对 inner-shareable 域可见
STR W1, [X2]           // Store B

// DSB — 比 DMB 更强，等待之前所有内存访问完成
DSB ISH                // 等待所有之前的内存访问完成

// ISB — 流水线刷新
MSR SCTLR_EL1, X0     // 修改系统寄存器
ISB                    // 确保后续指令看到新配置

// Load-Acquire / Store-Release (单向屏障)
LDAR W0, [X1]          // Load-Acquire: 后续访问不会重排到此之前
STLR W0, [X1]          // Store-Release: 之前访问不会重排到此之后
```

---

## 8. 系统寄存器访问

### 读写系统寄存器

```asm
// 读取系统寄存器
MRS X0, SCTLR_EL1      // X0 = SCTLR_EL1
MRS X0, CurrentEL       // X0 = 当前异常级别
MRS X0, MPIDR_EL1       // X0 = 多处理器亲和寄存器

// 写入系统寄存器
MSR SCTLR_EL1, X0      // SCTLR_EL1 = X0
MSR VBAR_EL1, X0       // 设置异常向量表基址
MSR TTBR0_EL1, X0      // 设置页表基址

// 特殊 PSTATE 字段
MSR DAIFSet, #0xF       // 屏蔽所有异常 (D,A,I,F)
MSR DAIFClr, #0x2       // 取消屏蔽 IRQ
MSR SPSel, #1           // 选择 SP_ELx
```

---

## 9. 多核编程

### Exclusive 访问（原子操作）

```asm
// 自旋锁实现示例
spin_lock:
    MOV W1, #1
1:  LDAXR W0, [X2]      // Load-Exclusive with Acquire
    CBNZ W0, 1b         // 如果已锁定，重试
    STXR W0, W1, [X2]   // Store-Exclusive
    CBNZ W0, 1b         // 如果 Store 失败，重试
    RET                  // 获取锁成功

spin_unlock:
    STLR WZR, [X2]      // Store-Release: 释放锁
    RET
```

### LSE 原子指令 (Armv8.1+)

```asm
// 比 LD/STXR 循环更高效
LDADD W0, W1, [X2]     // 原子加: old = *X2; *X2 += W0; W1 = old
SWPA W0, W1, [X2]      // 原子交换 with Acquire
CAS W0, W1, [X2]       // Compare-and-Swap: if (*X2 == W0) *X2 = W1
```

---

## 参考

- 完整文档：[ARMv8-A Programmer's Guide (DEN0024)](https://developer.arm.com/documentation/den0024/latest/)
- ARM 架构参考手册：[DDI 0487](https://developer.arm.com/documentation/ddi0487/latest/)
- Procedure Call Standard：[AAPCS64](https://developer.arm.com/documentation/ihi0055/latest/)
