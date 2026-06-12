---
layout: post
title: "Linux 内存管理(1): 物理内存概述 — Node/Zone/Page 三级结构"
date: 2026-06-12 15:01:00 +0800
excerpt: "Linux 物理内存管理的基础架构：NUMA Node、Zone 划分（区分32位/64位）、struct page 页描述符、内存模型、启动初始化流程。"
---

# Linux 内存管理(1): 物理内存概述

---

## 一、物理内存三级组织

```
Node (NUMA 节点)
 └── Zone (内存区域，按地址范围/用途划分)
      └── Page (物理页帧，4KB，由 struct page 描述)
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Node 0 (pglist_data)                   Node 1 (pglist_data)                │
│  CPU 0,1 本地内存                        CPU 2,3 本地内存                    │
│  ┌────────────────────────┐             ┌────────────────────────┐          │
│  │ Zone A (低地址)         │             │ Zone A                 │          │
│  ├────────────────────────┤             ├────────────────────────┤          │
│  │ Zone B                 │             │ Zone B                 │          │
│  ├────────────────────────┤             ├────────────────────────┤          │
│  │ Zone C (高地址)         │             │ Zone C                 │          │
│  └────────────────────────┘             └────────────────────────┘          │
│                                                                             │
│  每个 Zone 内部:                                                            │
│  ┌────────────────────────────────────────────────┐                         │
│  │  free_area[0]:  order-0 空闲链表 (4KB 单页)     │                         │
│  │  free_area[1]:  order-1 空闲链表 (8KB, 2页)     │                         │
│  │  free_area[2]:  order-2 空闲链表 (16KB, 4页)    │                         │
│  │  ...                                           │                         │
│  │  free_area[10]: order-10 空闲链表 (4MB, 1024页) │                         │
│  └────────────────────────────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Zone 划分 — 因架构而异

### Zone 类型定义

```c
// include/linux/mmzone.h
enum zone_type {
    ZONE_DMA,       // 受限 DMA 设备可达的最低地址范围
    ZONE_DMA32,     // 32-bit 地址可达范围 (仅 64-bit 系统有)
    ZONE_NORMAL,    // 正常内存，内核可直接线性映射
    ZONE_HIGHMEM,   // 高端内存 (仅 32-bit 系统有！)
    ZONE_MOVABLE,   // 虚拟 zone，可迁移页 (热插拔/CMA)
    MAX_NR_ZONES
};
```

### 32-bit vs 64-bit Zone 对比

**32-bit（ARM32 / x86_32）：**

```
物理地址:
0 ─────────────────────── 16MB ──────── ~896MB ──────────── 内存顶端
│      ZONE_DMA           │  ZONE_NORMAL  │   ZONE_HIGHMEM   │
│  ISA DMA 可达 (0~16M)   │ 内核可直接映射 │  内核无法直接映射  │
└──────────────────────────┴──────────────┴──────────────────┘

为什么有 HIGHMEM？
  32-bit 内核虚拟地址空间只有 ~1GB (3G/1G 用户/内核分割)
  内核线性映射区只能映射 ~896MB 物理内存
  超过 896MB 的物理页无法线性映射，需要 kmap() 临时映射
```

**64-bit（ARM64 / x86_64）：**

```
物理地址 (x86_64):
0 ───── 16MB ──────────── 4GB ────────────────────── 内存顶端
│ ZONE_DMA │   ZONE_DMA32   │       ZONE_NORMAL       │
│ ISA 兼容  │  32-bit DMA 可达 │   所有内存，直接线性映射  │
└──────────┴─────────────────┴────────────────────────┘
  无 ZONE_HIGHMEM！64-bit 虚拟空间足够映射所有物理内存

物理地址 (ARM64):
0 ──── dma_limit(如1GB) ──── 4GB ──────────────── 内存顶端
│      ZONE_DMA              │ ZONE_DMA32 │  ZONE_NORMAL  │
│  由 DT dma-ranges 决定     │            │               │
└────────────────────────────┴────────────┴───────────────┘
  ZONE_DMA 范围取决于设备树中最受限的 DMA master
```

### 完整对比表

| 架构 | ZONE_DMA | ZONE_DMA32 | ZONE_NORMAL | ZONE_HIGHMEM | 说明 |
|------|----------|-----------|-------------|-------------|------|
| **x86_64** | 0~16MB | 16MB~4GB | 4GB+ | ❌ 无 | DMA 为 ISA 兼容 |
| **ARM64** | 0~dma_limit | ~4GB | 4GB+ | ❌ 无 | dma_limit 由 DT 决定 |
| **x86_32** | 0~16MB | ❌ 无 | 16MB~896MB | 896MB+ | 超出线性映射范围 |
| **ARM32** | 0~16MB | ❌ 无 | 16MB~760MB | 760MB+ | 内核仅映射 ~760MB |

### HIGHMEM 为什么 64-bit 不需要？

```
32-bit 内核地址空间布局 (3G/1G 分割):
┌─────────────────────────────┐ 4GB
│  内核空间 (1GB)              │
│  ├─ 线性映射: 0~896MB        │ ← 只能映射这么多物理内存
│  ├─ vmalloc: ~128MB         │
│  └─ fixmap/pkmap            │
├─────────────────────────────┤ 3GB (PAGE_OFFSET)
│  用户空间 (3GB)              │
└─────────────────────────────┘ 0

  物理内存 > 896MB → ZONE_HIGHMEM，用 kmap() 临时映射

64-bit 内核地址空间布局:
  线性映射区: 128TB+ → 所有物理内存都能直接映射
  → 不需要 HIGHMEM
  → kmap() 在 64-bit 上是空操作 (直接返回 page_address)
```

---

## 三、Node — pglist_data

每个 NUMA 节点用 `pglist_data` 描述（UMA 系统只有 1 个节点）：

```c
// include/linux/mmzone.h
typedef struct pglist_data {
    struct zone node_zones[MAX_NR_ZONES];   // 该节点所有 zone
    struct zonelist node_zonelists[MAX_ZONELISTS]; // 分配回退列表
    int nr_zones;
    unsigned long node_start_pfn;           // 起始页帧号
    unsigned long node_present_pages;       // 实际存在的页数
    unsigned long node_spanned_pages;       // 跨越的页数 (含空洞)
    int node_id;                            // NUMA 节点 ID
    struct lruvec lruvec;                   // LRU 回收
    ...
} pg_data_t;

// 访问:
#define NODE_DATA(nid) (node_data[(nid)])
```

---

## 四、Zone 结构体

```c
struct zone {
    /* 水位线: 控制分配压力和回收时机 */
    unsigned long _watermark[NR_WMARK];   // min / low / high
    unsigned long watermark_boost;
    long lowmem_reserve[MAX_NR_ZONES];    // 为低端 zone 预留

    struct pglist_data *zone_pgdat;        // 所属 node
    struct per_cpu_pages __percpu *per_cpu_pageset; // PCP 热页缓存

    /* 地址范围 */
    unsigned long zone_start_pfn;          // 起始 PFN
    unsigned long spanned_pages;           // 跨越页数 (含空洞)
    unsigned long present_pages;           // 实际存在页数
    unsigned long managed_pages;           // 由 buddy 管理的页数

    /* ★ 伙伴系统空闲链表 */
    struct free_area free_area[NR_PAGE_ORDERS]; // order 0~10

    const char *name;                      // "DMA", "DMA32", "Normal"...
};
```

### 水位线机制

```
空闲页数
  ▲
  │  ┌─── high ─── 内存充足，正常分配
  │  │
  │  ├─── low  ─── 唤醒 kswapd 后台回收
  │  │
  │  ├─── min  ─── 紧急！仅 __GFP_HIGH/PF_MEMALLOC 可分配
  │  │              其他分配触发直接回收 (direct reclaim)
  │  └─── 0    ─── OOM killer 杀进程
  ▼
```

---

## 五、struct page — 页描述符

每个物理页 (4KB) 有一个 `struct page`，是内核最密集的数据结构：

```c
// include/linux/mm_types.h
struct page {
    unsigned long flags;    // 页状态: PG_locked, PG_dirty, PG_lru, PG_slab...

    union {  /* 不同用途复用同一内存 */
        struct {  /* 页缓存 / 匿名页 (最常见) */
            struct list_head lru;
            struct address_space *mapping;  // 所属文件
            pgoff_t index;                  // 文件内页偏移
        };
        struct {  /* slab 分配器使用 */
            struct kmem_cache *slab_cache;
            void *freelist;                // 空闲对象链表
            unsigned inuse:16;             // 已用对象数
            unsigned objects:15;           // 总对象数
        };
        struct {  /* 伙伴系统空闲页 */
            unsigned long _buddy_pfn;
            unsigned int _buddy_order;
        };
        struct {  /* 复合页 (compound page, 如 huge page) */
            unsigned long compound_head;
            unsigned int compound_order;
        };
    };

    atomic_t _refcount;    // 引用计数 (get_page/put_page)
    atomic_t _mapcount;    // 映射计数 (几个 PTE 指向此页)
};
```

### page ↔ pfn ↔ 物理地址 转换

```c
// 页帧号 (PFN) = 物理地址 >> PAGE_SHIFT (12)
// 一个 PFN 对应一个 struct page

#define page_to_pfn(page)   /* 实现取决于内存模型 */
#define pfn_to_page(pfn)
#define page_to_phys(page)  (page_to_pfn(page) << PAGE_SHIFT)
#define phys_to_page(phys)  pfn_to_page((phys) >> PAGE_SHIFT)
#define virt_to_page(addr)  pfn_to_page(virt_to_pfn(addr))

// 线性映射区虚拟地址转换 (64-bit):
#define __pa(vaddr)  ((vaddr) - PAGE_OFFSET + PHYS_OFFSET)  // 虚拟→物理
#define __va(paddr)  ((paddr) - PHYS_OFFSET + PAGE_OFFSET)  // 物理→虚拟
```

---

## 六、内存模型 — 如何管理 page 数组

```
┌──────────────────────────────────────────────────────────────────┐
│  FLATMEM (平坦)                                                   │
│  ─ 全局 mem_map[] 数组，pfn 直接索引                              │
│  ─ 适用: UMA，内存无空洞                                          │
│  ─ page_to_pfn(page) = page - mem_map                            │
├──────────────────────────────────────────────────────────────────┤
│  SPARSEMEM_VMEMMAP ← 现代 64-bit 内核默认                        │
│  ─ 内存分 section (ARM64: 128MB/section, x86_64: 128MB)         │
│  ─ struct page 数组映射到 vmemmap 连续虚拟地址                    │
│  ─ 支持内存空洞、热插拔                                          │
│  ─ page_to_pfn 仍是简单指针减法（因为 vmemmap 连续）              │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、启动时物理内存初始化

```
固件传递内存信息:
  x86: E820 表 / EFI Memory Map
  ARM: DTB memory 节点
    │
    ▼
memblock (早期内存管理器, 在 buddy 就绪前使用)
    ├── memblock.memory: 所有物理内存区域
    ├── memblock.reserved: 已预留 (kernel image, DTB, initrd)
    └── memblock_alloc(): 早期分配 (页表、per-cpu 区等)
    │
    ▼
mm_core_init() / free_all_bootmem()
    │
    ├── 将 memblock 中未 reserved 的内存交给 buddy 系统
    │       __free_pages_core() → 加入 zone->free_area[]
    │
    ├── 各 zone 水位线计算
    │
    └── 伙伴系统就绪，memblock 退役
    │
    ▼
kmem_cache_init() → SLUB 初始化 (基于 buddy)
    │
    ▼
内存子系统完全可用
```

---

## 八、关键 GFP 标志

分配物理页时通过 GFP 标志指定约束：

```c
/* Zone 选择 */
#define __GFP_DMA       (从 ZONE_DMA 分配)
#define __GFP_DMA32     (从 ZONE_DMA32 分配)
#define __GFP_HIGHMEM   (允许从 ZONE_HIGHMEM 分配, 32-bit)
// 无 zone 标志 → 默认 ZONE_NORMAL

/* 行为组合 */
#define GFP_KERNEL  (__GFP_RECLAIM | __GFP_IO | __GFP_FS)
//   可睡眠、可回收、可做 I/O → 进程上下文常用

#define GFP_ATOMIC  (__GFP_HIGH | __GFP_KSWAPD_RECLAIM)
//   不可睡眠、不直接回收 → 中断上下文/自旋锁内使用

#define GFP_DMA     (__GFP_DMA)
//   从 ZONE_DMA 分配，用于老旧 ISA DMA 设备

#define GFP_USER    (__GFP_RECLAIM | __GFP_IO | __GFP_FS | __GFP_HARDWALL)
//   为用户空间分配
```

---

## 九、源文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/mmzone.h` | zone, pglist_data, free_area, 水位线, zone_type |
| `include/linux/mm_types.h` | struct page, mm_struct, vm_area_struct |
| `include/linux/gfp.h` | GFP 标志定义 |
| `mm/page_alloc.c` | 伙伴系统核心 |
| `mm/memblock.c` | 早期内存管理 |
| `arch/arm64/mm/init.c` | ARM64 zone 初始化，dma zone 大小确定 |
| `arch/x86/mm/init.c` | x86 zone 初始化 |
| `arch/arm/mm/init.c` | ARM32 zone + HIGHMEM 初始化 |
