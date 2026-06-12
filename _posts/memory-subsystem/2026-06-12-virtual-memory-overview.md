---
layout: post
title: "Linux 内存管理(2): 虚拟内存概述 — 地址空间、页表、VMA"
date: 2026-06-12 15:02:00 +0800
excerpt: "Linux 虚拟内存体系：用户/内核地址空间布局、四级页表遍历、struct mm_struct 与 VMA 管理、缺页异常处理流程。以 ARM64 为例。"
---

# Linux 内存管理(2): 虚拟内存概述

---

## 一、虚拟地址空间布局 (ARM64, 48-bit VA)

```
0xFFFF_FFFF_FFFF_FFFF ┌───────────────────────────┐
                      │  内核空间 (高地址)          │
0xFFFF_0000_0000_0000 ├───────────────────────────┤ ← PAGE_OFFSET
                      │                           │
                      │  ┌── 线性映射区 ──────┐    │ physmem 直接映射
                      │  │ virt = phys + offset│    │ (page_offset_base)
                      │  └────────────────────┘    │
                      │                           │
                      │  vmalloc 区               │ VMALLOC_START ~ VMALLOC_END
                      │  modules 区               │ MODULES_VADDR
                      │  fixmap 区                │
                      │  PCI I/O 区               │
                      │  vmemmap 区               │ struct page 数组映射
                      │                           │
0x0000_FFFF_FFFF_FFFF ├── ─ ─ ─ 空洞 ─ ─ ─ ─ ─ ──┤ (非规范地址，访问触发异常)
0x0000_0000_0000_0000 ├───────────────────────────┤
                      │  用户空间 (低地址)          │
                      │                           │
                      │  0x0000_0000_0000 ~ 0x0000_FFFF_FFFF_FFFF │
                      │                           │
                      │  ┌─────────────────────┐  │
                      │  │ text (代码段)         │  │ 0x400000 (ELF 加载地址)
                      │  │ data/bss             │  │
                      │  │ heap  ↓ (brk 增长)    │  │
                      │  │                      │  │
                      │  │ mmap 区 ↓ (匿名/文件) │  │ 从 TASK_UNMAPPED_BASE 向下
                      │  │                      │  │
                      │  │ stack ↑ (向低地址增长) │  │ 栈顶接近 TASK_SIZE
                      │  └─────────────────────┘  │
                      └───────────────────────────┘
```

---

## 二、页表结构 — 32-bit vs 64-bit

### 32-bit 两级页表 (x86_32 / ARM32, 4KB 页)

```
虚拟地址 (32-bit):
┌──────────────┬──────────────┬─────────────┐
│  PGD (10位)   │  PTE (10位)   │ Offset(12位) │
│  [31:22]     │  [21:12]     │  [11:0]     │
└──────┬───────┴──────┬───────┴──────┬──────┘
       │              │              │
       ▼              ▼              │
  ┌──────────┐   ┌──────────┐       │
  │ 页目录    │→ │ 页表      │──┐    │
  │ 1024 项   │   │ 1024 项   │  │    │
  │ (4KB)    │   │ (4KB)    │  │    │
  └──────────┘   └──────────┘  │    │
                                ▼    ▼
                         物理页帧 + 页内偏移 = 物理地址

  寻址能力: 2^32 = 4GB
  页目录: 1024 × 1024 × 4KB = 4GB ✓
  每个进程页目录占 4KB (1024 × 4 bytes)
```

### 64-bit 四级页表 (x86_64 / ARM64, 4KB 页, 48-bit VA)

```
虚拟地址 (48-bit, 高16位为符号扩展):
┌────────┬────────┬────────┬────────┬─────────────┐
│ PGD(9) │ PUD(9) │ PMD(9) │ PTE(9) │ Offset(12)  │
│ [47:39]│ [38:30]│ [29:21]│ [20:12]│ [11:0]      │
└───┬────┴───┬────┴───┬────┴───┬────┴──────┬──────┘
    │        │        │        │           │
    ▼        ▼        ▼        ▼           │
┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       │
│ PGD  │→│ PUD  │→│ PMD  │→│ PTE  │──┐    │
│ 512  │ │ 512  │ │ 512  │ │ 512  │  │    │
│entries│ │entries│ │entries│ │entries│  │    │
│(4KB) │ │(4KB) │ │(4KB) │ │(4KB) │  │    │
└──────┘ └──────┘ └──────┘ └──────┘  │    │
                                      ▼    ▼
                               物理页帧 + 页内偏移 = 物理地址

  寻址能力: 2^48 = 256TB (用户128TB + 内核128TB)
  每级 512 项 × 8 bytes = 4KB (一页)
  9+9+9+9+12 = 48 bit
```

### 五级页表 (x86_64, 57-bit VA, 需要 CPU 支持 LA57)

```
┌────────┬────────┬────────┬────────┬────────┬─────────────┐
│ PGD(9) │ P4D(9) │ PUD(9) │ PMD(9) │ PTE(9) │ Offset(12)  │
│[56:48] │[47:39] │[38:30] │[29:21] │[20:12] │  [11:0]     │
└────────┴────────┴────────┴────────┴────────┴─────────────┘
  寻址能力: 2^57 = 128PB
```

### 对比总结

| | 32-bit | 64-bit (48VA) | 64-bit (57VA) |
|---|---|---|---|
| 页表级数 | 2级 | 4级 | 5级 |
| 每级索引位数 | 10 bit | 9 bit | 9 bit |
| 每级项数 | 1024 | 512 | 512 |
| 页内偏移 | 12 bit | 12 bit | 12 bit |
| 虚拟地址位数 | 32 | 48 | 57 |
| 寻址范围 | 4GB | 256TB | 128PB |
| 内核名称 | PGD→PTE | PGD→PUD→PMD→PTE | PGD→P4D→PUD→PMD→PTE |

### Linux 页表遍历代码

```c
// include/linux/pgtable.h
typedef struct { unsigned long pgd; } pgd_t;  // 页全局目录
typedef struct { unsigned long p4d; } p4d_t;  // 页四级目录 (5级页表)
typedef struct { unsigned long pud; } pud_t;  // 页上级目录
typedef struct { unsigned long pmd; } pmd_t;  // 页中间目录
typedef struct { unsigned long pte; } pte_t;  // 页表项

// 遍历页表 (通用，4/5级自适应):
pgd_t *pgd = pgd_offset(mm, addr);       // mm->pgd + pgd_index(addr)
pud_t *pud = pud_offset(pgd, addr);
pmd_t *pmd = pmd_offset(pud, addr);
pte_t *pte = pte_offset_map(pmd, addr);
// pte 包含: 物理页帧号 + 标志位 (Present, RW, User, Dirty, Accessed...)
```

---

## 三、struct mm_struct — 进程地址空间

```c
// include/linux/mm_types.h
struct mm_struct {
    struct maple_tree mm_mt;          // VMA 红黑/maple tree
    unsigned long task_size;           // 用户空间大小
    pgd_t *pgd;                       // 页表根 (切换进程时写入 TTBR0/CR3)

    atomic_t mm_users;                 // 使用该 mm 的线程数
    atomic_t mm_count;                 // mm 引用计数

    unsigned long start_code, end_code;   // text 段
    unsigned long start_data, end_data;   // data 段
    unsigned long start_brk, brk;         // heap (brk 系统调用)
    unsigned long start_stack;            // 栈起始
    unsigned long mmap_base;              // mmap 区域基地址

    unsigned long total_vm;            // 总虚拟页数
    unsigned long locked_vm;           // 锁定页数
    struct rw_semaphore mmap_lock;     // VMA 操作锁
};
```

---

## 四、VMA — 虚拟内存区域

每段连续的虚拟地址映射用 `vm_area_struct` 描述：

```c
struct vm_area_struct {
    unsigned long vm_start;     // 起始虚拟地址
    unsigned long vm_end;       // 结束虚拟地址 (不含)
    unsigned long vm_flags;     // VM_READ | VM_WRITE | VM_EXEC | VM_SHARED...

    struct mm_struct *vm_mm;    // 所属进程
    struct file *vm_file;       // 映射的文件 (NULL = 匿名映射)
    pgoff_t vm_pgoff;           // 文件内偏移 (页为单位)

    const struct vm_operations_struct *vm_ops;  // fault, map_pages...
    // maple tree 管理，替代旧的 rb_tree
};
```

### /proc/PID/maps 中的 VMA

```
地址范围              权限 偏移     设备  inode  路径
00400000-00452000    r-xp 00000000 08:01 123    /usr/bin/app    [text]
00651000-00652000    rw-p 00051000 08:01 123    /usr/bin/app    [data]
00652000-00673000    rw-p 00000000 00:00 0      [heap]
7f8a1000-7f8c3000    r-xp 00000000 08:01 456    /lib/libc.so.6
7ffcb000-7ffec000    rw-p 00000000 00:00 0      [stack]
```

---

## 五、缺页异常处理 (Page Fault)

```
CPU 访问虚拟地址 → MMU 查页表 → PTE 无效/权限不足
    │
    ▼
异常入口 (ARM64: do_page_fault / x86: do_page_fault)
    │
    ▼
handle_mm_fault(vma, addr, flags)
    │
    ├── __handle_mm_fault()
    │       ├── pgd_offset(mm, addr)     → 检查/分配 PGD
    │       ├── pud_alloc()              → 检查/分配 PUD
    │       ├── pmd_alloc()              → 检查/分配 PMD
    │       └── handle_pte_fault()
    │               │
    │               ├── PTE 不存在 (首次访问):
    │               │       ├── 匿名页: do_anonymous_page()
    │               │       │     → alloc_page() + 清零 + 建立映射
    │               │       └── 文件页: do_fault() → filemap_fault()
    │               │             → 从 page cache 或磁盘读入
    │               │
    │               ├── PTE 存在但只读 (COW):
    │               │       └── do_wp_page()
    │               │             → 复制页面 + 建立新映射
    │               │
    │               └── PTE 在 swap 中:
    │                       └── do_swap_page()
    │                             → 从 swap 读回 + 建立映射
    │
    └── 返回用户空间，重新执行触发异常的指令
```

---

## 六、内核地址空间映射方式

| 区域 | 虚拟地址范围 | 映射方式 | 用途 |
|------|-------------|---------|------|
| 线性映射 | PAGE_OFFSET ~ | `virt = phys + offset` | 物理内存直接访问 |
| vmalloc | VMALLOC_START ~ END | 页表逐页映射 | 虚拟连续/物理不连续 |
| vmemmap | VMEMMAP_START ~ | 映射 struct page 数组 | page_to_pfn 快速转换 |
| fixmap | FIXMAP_START ~ | 编译时固定虚拟地址 | early console, 临时映射 |
| modules | MODULES_VADDR ~ | 动态映射 | 内核模块 |

```c
// 线性映射转换 (ARM64):
#define __pa(vaddr)    ((vaddr) - PAGE_OFFSET + PHYS_OFFSET)
#define __va(paddr)    ((paddr) - PHYS_OFFSET + PAGE_OFFSET)

// virt_to_page: 虚拟地址 → struct page
#define virt_to_page(addr)  pfn_to_page(virt_to_pfn(addr))
```

---

## 七、源文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/mm_types.h` | mm_struct, vm_area_struct, page |
| `include/linux/pgtable.h` | 页表遍历宏 |
| `mm/memory.c` | handle_mm_fault, 缺页处理 |
| `mm/mmap.c` | VMA 管理, do_mmap, brk |
| `arch/arm64/mm/fault.c` | ARM64 缺页异常入口 |
| `arch/arm64/include/asm/pgtable.h` | ARM64 页表定义 |
| `arch/arm64/include/asm/memory.h` | 地址空间布局常量 |
