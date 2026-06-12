---
layout: post
title: "Linux 内存管理(5): mmap、vmalloc、brk — 用户与内核的内存映射"
date: 2026-06-12 15:05:00 +0800
excerpt: "深入分析三种内存映射机制：mmap 用户空间文件/匿名映射、vmalloc 内核虚拟连续分配、brk/sbrk 堆管理。完整调用链与页表建立时机。"
---

# Linux 内存管理(5): mmap、vmalloc、brk

---

## 一、三种映射的定位

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  接口         │ 地址空间    │ 物理连续？ │ 何时分配物理页 │ 典型场景          │
├───────────────┼────────────┼───────────┼──────────────┼──────────────────┤
│ mmap()        │ 用户空间    │ 不要求     │ 缺页时(lazy) │ 文件映射/malloc   │
│ brk/sbrk      │ 用户空间    │ 不要求     │ 缺页时(lazy) │ 小块 malloc       │
│ vmalloc()     │ 内核空间    │ 不连续     │ 立即分配      │ 内核大块分配      │
│ kmalloc()     │ 内核空间    │ 物理连续   │ 立即分配      │ 内核小对象(DMA)   │
└───────────────┴────────────┴───────────┴──────────────┴──────────────────┘
```

---

## 二、mmap — 用户空间内存映射

### 系统调用入口

```c
// mm/mmap.c
SYSCALL_DEFINE6(mmap_pgoff, unsigned long, addr, unsigned long, len,
                unsigned long, prot, unsigned long, flags,
                unsigned long, fd, unsigned long, pgoff)
{
    // → do_mmap()
}
```

### do_mmap 流程

```
用户: mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
    │
    ▼
do_mmap(file, addr, len, prot, flags, pgoff)           [mm/mmap.c]
    │
    ├── get_unmapped_area()          // 找一段空闲虚拟地址
    │       └── arch_get_unmapped_area()
    │             // 在 mmap_base 附近找 len 大小的空洞
    │
    ├── 权限检查 (可写？可执行？)
    │
    └── mmap_region(file, addr, len, vm_flags, pgoff)
            │
            ├── vma_merge() 或 vm_area_alloc()
            │       // 尝试和相邻 VMA 合并，不能则创建新 VMA
            │
            ├── vma->vm_start = addr
            │   vma->vm_end = addr + len
            │   vma->vm_flags = VM_READ | VM_WRITE | ...
            │   vma->vm_file = file  (匿名映射则为 NULL)
            │
            ├── 如果是文件映射:
            │       file->f_op->mmap(file, vma)
            │       // 设置 vma->vm_ops = &ext4_file_vm_ops
            │
            ├── vma_link() → 插入 maple tree
            │
            └── 返回虚拟地址 addr
                // ★ 注意：此时没有分配任何物理页！没有建立页表！
                // 物理页在第一次访问时通过缺页异常分配 (lazy allocation)
```

### 缺页时才真正分配

```
用户第一次读写 mmap 返回的地址
    │
    ▼ Page Fault
handle_mm_fault() → handle_pte_fault()
    │
    ├── 匿名映射 (MAP_ANONYMOUS):
    │       do_anonymous_page()
    │           → alloc_page(GFP_HIGHUSER_MOVABLE)  // 分配物理页
    │           → clear_page()                       // 清零
    │           → set_pte_at()                       // 建立页表映射
    │
    └── 文件映射 (fd >= 0):
            do_fault() → do_read_fault() / do_cow_fault()
                → vma->vm_ops->fault()
                    → filemap_fault()
                        → find_get_page() 或 read_page()
                        // 从 page cache 取或从磁盘读
                → set_pte_at()  // 映射到用户地址
```

---

## 三、brk / sbrk — 堆管理

`brk` 调整进程堆的上边界：

```
进程地址空间:
     start_brk ─────────┐
                         │  heap 区域 (brk 管理)
     brk (当前堆顶) ────┘
                         │
     新 brk ─────────────┘  ← sys_brk(new_brk) 扩展
```

### 系统调用

```c
// mm/mmap.c
SYSCALL_DEFINE1(brk, unsigned long, brk)
{
    unsigned long oldbrk = mm->brk;
    unsigned long newbrk = PAGE_ALIGN(brk);

    if (brk < mm->start_brk)  // 不能小于起始
        goto out;

    // 缩小 heap
    if (brk <= mm->brk) {
        mm->brk = brk;
        do_brk_munmap(...);  // 释放多余的 VMA
        goto success;
    }

    // 扩大 heap
    if (do_brk_flags(&vmi, brkvma, oldbrk, newbrk - oldbrk, 0) < 0)
        goto out;

    mm->brk = brk;

success:
    return brk;
}
```

**要点：**
- `brk` 只调整 VMA 边界，**不分配物理页**
- 物理页在缺页时分配（同 mmap 匿名映射）
- glibc `malloc` 小于 128KB 时用 `brk`，大于时用 `mmap`

---

## 四、vmalloc — 内核虚拟连续分配

### 为什么需要 vmalloc？

```
kmalloc: 物理连续 → 受碎片限制，大块分配可能失败
vmalloc: 虚拟连续，物理可不连续 → 通过页表映射拼接，不受碎片影响
```

### 调用链

```
vmalloc(size)                                    [mm/vmalloc.c]
    │
    ▼
__vmalloc_node(size, align, GFP_KERNEL|__GFP_HIGHMEM, node)
    │
    ▼
__vmalloc_node_range(size, align, VMALLOC_START, VMALLOC_END, ...)
    │
    ├── ① 分配虚拟地址区间
    │       __get_vm_area_node(size, align, ...)
    │           → alloc_vmap_area()
    │               // 在 VMALLOC_START ~ VMALLOC_END 找空闲区间
    │               // 用红黑树管理 vmap_area
    │
    ├── ② 分配物理页 (逐页，不要求连续)
    │       vm_area_alloc_pages(gfp, order, nr_pages, pages[])
    │           → alloc_pages(gfp, 0)  × nr_pages
    │           // 每页独立从 buddy 分配，不需要连续！
    │
    └── ③ 建立页表映射
            vmap_pages_range(addr, addr+size, prot, pages)
                → vmap_pages_range_noflush()
                    // 遍历每页，填写 PGD→PUD→PMD→PTE
                    // 将虚拟地址 [addr, addr+size) 映射到各个物理页
                → flush_tlb_kernel_range()  // 刷 TLB
```

### 内存布局

```
内核虚拟地址:
VMALLOC_START ─────────────────────────────────────── VMALLOC_END
    │                                                    │
    │  [vm_area 1]     [vm_area 2]     [vm_area 3]      │
    │  addr=0xffff..a  addr=0xffff..b  addr=0xffff..c   │
    │  size=16KB       size=8KB        size=64KB         │
    │  pages[0..3]     pages[0..1]     pages[0..15]      │
    │     ↓↓↓↓           ↓↓              ↓↓↓...         │
    │  物理页散布在内存各处，但虚拟地址连续                 │
```

### vmalloc vs kmalloc 选择

| | kmalloc | vmalloc |
|---|---|---|
| 物理连续 | ✅ 是 | ❌ 否 |
| 速度 | 快 (buddy/slab) | 慢 (页表建立) |
| 最大大小 | ~4MB (order 10) | 几乎无限 |
| 可用于 DMA | ✅ | ❌ (除非 bounce buffer) |
| 适用场景 | 驱动 buffer, 小结构 | 模块加载, 大数组, iptables 规则 |
| 地址范围 | 线性映射区 | VMALLOC 区 |

---

## 五、vfree / munmap / brk 缩小 — 释放流程

### vfree

```
vfree(addr)
    │
    ├── find_vm_area(addr)           // 找到 vm_struct
    ├── remove_vm_area()             // 从红黑树移除
    ├── vunmap_range()               // 清除页表
    ├── flush_tlb_kernel_range()     // 刷 TLB
    └── for each page: __free_pages(page, 0)  // 归还 buddy
```

### munmap

```
munmap(addr, len)
    │
    ▼
do_munmap(mm, addr, len)
    ├── 找到覆盖的 VMA(s)
    ├── 如果部分覆盖：split VMA
    ├── unmap_region()
    │       ├── unmap_vmas()         // 清除页表项
    │       ├── free_pgtables()      // 释放空页表页
    │       └── tlb_finish_mmu()     // flush TLB
    └── remove_vma()                 // 释放 VMA 结构
        // 映射的物理页如果 refcount 降为 0 → 回收到 buddy/page cache
```

---

## 六、总结对比图

```
用户空间 malloc(100KB):
    glibc: brk() 扩展堆 → VMA 扩大 → 缺页时分配物理页

用户空间 malloc(1MB):
    glibc: mmap(ANONYMOUS) → 创建 VMA → 缺页时分配物理页

内核 kmalloc(256):
    SLUB → per-CPU sheaf → slab → buddy 物理连续页

内核 vmalloc(1MB):
    找 vmalloc 虚拟区间 → 逐页 alloc_pages → 建页表映射
```

---

## 七、源文件索引

| 文件 | 内容 |
|------|------|
| `mm/mmap.c` | do_mmap, brk, munmap, VMA 管理 |
| `mm/vmalloc.c` | vmalloc, vfree, vmap_area 管理 |
| `mm/memory.c` | handle_mm_fault, 缺页处理, copy_page_range |
| `mm/mmap.c` | SYSCALL(brk), do_brk_flags |
| `include/linux/mm.h` | vm_area_struct, mmap 相关宏 |
| `include/linux/vmalloc.h` | vmalloc/vfree API |
| `arch/arm64/mm/mmu.c` | ARM64 页表建立 |
