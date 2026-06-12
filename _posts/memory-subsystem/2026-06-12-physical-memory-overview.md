---
layout: post
title: "Linux 内存管理(1): 物理内存概述 — Node/Zone/Page 三级结构"
date: 2026-06-12 15:01:00 +0800
excerpt: "Linux 物理内存管理的基础架构：NUMA Node、Zone 划分、struct page 页描述符、内存模型（FLATMEM/SPARSEMEM）。详解 pglist_data、zone、free_area 数据结构。"
---

# Linux 内存管理(1): 物理内存概述

---

## 一、物理内存整体模型

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    物理内存组织层次                                            │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Node 0 (pglist_data)          Node 1 (pglist_data)                 │    │
│  │  ┌───────────────────────┐    ┌───────────────────────┐            │    │
│  │  │ CPU 0,1 本地内存       │    │ CPU 2,3 本地内存       │            │    │
│  │  │                       │    │                       │            │    │
│  │  │ ┌────────────────┐    │    │ ┌────────────────┐    │            │    │
│  │  │ │ ZONE_DMA       │    │    │ │ ZONE_DMA       │    │            │    │
│  │  │ │(x86:0~16M      │    │    │ │                │    │            │    │
│  │  │ │ arm64:0~1G)    │    │    │ │                │    │            │    │
│  │  │ ├────────────────┤    │    │ ├────────────────┤    │            │    │
│  │  │ │ ZONE_DMA32     │    │    │ │ ZONE_DMA32     │    │            │    │
│  │  │ │ ~4GB           │    │    │ │                │    │            │    │
│  │  │ ├────────────────┤    │    │ ├────────────────┤    │            │    │
│  │  │ │ ZONE_NORMAL    │    │    │ │ ZONE_NORMAL    │    │            │    │
│  │  │ │ 4GB~...        │    │    │ │                │    │            │    │
│  │  │ ├────────────────┤    │    │ ├────────────────┤    │            │    │
│  │  │ │ ZONE_MOVABLE   │    │    │ │ ZONE_MOVABLE   │    │            │    │
│  │  │ │ (虚拟zone)     │    │    │ │                │    │            │    │
│  │  │ └────────────────┘    │    │ └────────────────┘    │            │    │
│  │  └───────────────────────┘    └───────────────────────┘            │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│  注: Zone 是否存在及范围因架构/配置/DT而异，并非所有平台都有全部 zone        │
│                                                                             │
│  每个 Zone 内部:                                                            │
│  ┌────────────────────────────────────────────────┐                         │
│  │  free_area[0]: order-0 空闲链表 (4KB 页)        │                         │
│  │  free_area[1]: order-1 空闲链表 (8KB 块)        │                         │
│  │  free_area[2]: order-2 空闲链表 (16KB 块)       │                         │
│  │  ...                                           │                         │
│  │  free_area[10]: order-10 空闲链表 (4MB 块)      │                         │
│  └────────────────────────────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Node — pglist_data

每个 NUMA 节点用 `pglist_data` 描述（UMA 系统只有 1 个节点）：

```c
// include/linux/mmzone.h
typedef struct pglist_data {
    struct zone node_zones[MAX_NR_ZONES];  // 该节点的所有 zone
    struct zonelist node_zonelists[MAX_ZONELISTS]; // 分配时的 zone 回退列表
    int nr_zones;                          // zone 数量
    unsigned long node_start_pfn;          // 起始页帧号
    unsigned long node_present_pages;      // 实际存在的页数
    unsigned long node_spanned_pages;      // 跨越的页数(含空洞)
    int node_id;                           // NUMA 节点 ID
    struct lruvec lruvec;                  // LRU 页面回收
    ...
} pg_data_t;

// 全局:
extern struct pglist_data *node_data[];    // node_data[nid]
#define NODE_DATA(nid) (node_data[(nid)])
```

---

## 三、Zone — 内存区域

不同 zone 对应不同物理地址约束（**因架构而异**）：

```c
enum zone_type {
    ZONE_DMA,       // 受限 DMA 设备可达范围
                    //   x86_64: 0~16MB (ISA DMA 兼容)
                    //   ARM64:  0~dma_phys_limit (来自 DT dma-ranges, 通常 0~1GB)
                    //   某些 ARM64 配置可能不存在此 zone
    ZONE_DMA32,     // 32-bit DMA 设备可达: 0~4GB
    ZONE_NORMAL,    // 所有物理内存 (64-bit 无高端内存问题)
    ZONE_MOVABLE,   // 可迁移页 (热插拔/CMA, 虚拟 zone)
    MAX_NR_ZONES
};
```

**各架构 Zone 对比：**

| 架构 | ZONE_DMA | ZONE_DMA32 | ZONE_NORMAL | 说明 |
|------|----------|-----------|-------------|------|
| x86_64 | 0~16MB | 16MB~4GB | 4GB+ | 三个都有，DMA 为 ISA 兼容 |
| ARM64 (典型) | 0~1GB | 1GB~4GB | 4GB+ | DMA 上界由 dma-ranges 决定 |
| ARM64 (无DMA zone) | 无 | 0~4GB | 4GB+ | CONFIG_ZONE_DMA=n |
| 32-bit ARM | 0~16MB | 无 | 16MB~760MB | 还有 ZONE_HIGHMEM |

```bash
# 查看当前系统 zone 划分:
cat /proc/zoneinfo | grep -E "Node|zone |spanned|present"
```

```c
// include/linux/mmzone.h
struct zone {
    unsigned long _watermark[NR_WMARK];   // 水位线: min/low/high
    unsigned long watermark_boost;
    long lowmem_reserve[MAX_NR_ZONES];    // 为低端 zone 预留

    struct pglist_data *zone_pgdat;        // 所属 node
    struct per_cpu_pages __percpu *per_cpu_pageset; // PCP 热页缓存

    unsigned long zone_start_pfn;          // 起始 PFN
    unsigned long spanned_pages;           // 跨越页数
    unsigned long present_pages;           // 实际页数
    unsigned long managed_pages;           // 由 buddy 管理的页数

    struct free_area free_area[NR_PAGE_ORDERS]; // ★ 伙伴系统空闲链表
    unsigned long flags;                   // zone 状态标志
    const char *name;                      // "DMA", "Normal"...
};
```

### 水位线机制

```
pages
  ▲
  │  ┌─── high ────── 正常分配，无压力
  │  │
  │  ├─── low  ────── 唤醒 kswapd 后台回收
  │  │
  │  ├─── min  ────── 仅允许 __GFP_HIGH 分配，直接回收
  │  │
  │  └─── 0    ────── OOM killer
  │
  空闲页数从上到下递减表示内存压力增大
```

---

## 四、struct page — 页描述符

每个物理页（4KB）由一个 `struct page` 描述，是内核中最密集的数据结构：

```c
// include/linux/mm_types.h
struct page {
    unsigned long flags;    // PG_locked, PG_dirty, PG_lru, PG_slab...
    union {
        struct {  /* 页缓存/匿名页 */
            struct list_head lru;           // LRU 链表
            struct address_space *mapping;  // 所属文件/匿名映射
            pgoff_t index;                  // 页内偏移
            unsigned long private;
        };
        struct {  /* slab 使用 */
            struct kmem_cache *slab_cache;
            void *freelist;
            union {
                unsigned long counters;
                struct { unsigned inuse:16; unsigned objects:15; unsigned frozen:1; };
            };
        };
        struct {  /* 复合页 (compound page) */
            unsigned long compound_head;
            unsigned int compound_order;
            atomic_t compound_mapcount;
        };
        struct {  /* 伙伴系统空闲页 */
            unsigned long _buddy_pfn;
            unsigned int _buddy_order;
        };
    };
    atomic_t _refcount;       // 引用计数
    atomic_t _mapcount;       // 映射计数(几个PTE指向它)
    // ...
};
```

### page 与 pfn 的转换

```c
// 页帧号 (PFN) ↔ struct page ↔ 物理地址

#define page_to_pfn(page)   ((page) - mem_map)           // FLATMEM
#define pfn_to_page(pfn)    (mem_map + (pfn))            // FLATMEM

// SPARSEMEM (现代内核默认):
#define page_to_pfn(page)   section_nr_to_pfn(page_to_section(page)) + ...
#define pfn_to_page(pfn)    __pfn_to_section(pfn)->section_mem_map + ...

// 物理地址转换:
#define page_to_phys(page)  (page_to_pfn(page) << PAGE_SHIFT)
#define phys_to_page(phys)  pfn_to_page((phys) >> PAGE_SHIFT)
```

---

## 五、内存模型

```
┌──────────────────────────────────────────────────────────────────┐
│  FLATMEM (平坦模型)                                               │
│  ─ 一个全局 mem_map[] 数组，PFN 直接索引                          │
│  ─ 适用: UMA, 内存连续无空洞                                      │
│  ─ page = mem_map[pfn]                                           │
├──────────────────────────────────────────────────────────────────┤
│  SPARSEMEM (稀疏模型) ← 现代内核默认                              │
│  ─ 内存分成 section (128MB/section on x86_64)                    │
│  ─ 每个 section 有独立的 mem_map                                  │
│  ─ 支持内存空洞、热插拔                                          │
│  ─ SPARSEMEM_VMEMMAP: section mem_map 映射到连续虚拟地址          │
│    使得 page_to_pfn 仍然是简单指针运算                            │
└──────────────────────────────────────────────────────────────────┘
```

---

## 六、启动时物理内存初始化流程

```
固件/bootloader 传递内存信息 (DTB / E820 / EFI Memory Map)
    │
    ▼
memblock (早期内存管理器)
    ├── memblock.memory: 所有可用内存区域
    ├── memblock.reserved: 已预留区域 (kernel, DTB, initrd)
    └── memblock_alloc(): 早期分配
    │
    ▼ (buddy 系统初始化)
free_all_bootmem() / memblock_free_all()
    │
    ├── 将 memblock.memory 中未 reserved 的页交给 buddy
    ├── __free_pages_core(): 逐块加入 zone->free_area[]
    │
    ▼
伙伴系统就绪，memblock 退役
    │
    ▼
slab 分配器初始化 (kmem_cache_init)
    └── 基于 buddy 创建 slab cache
```

---

## 七、关键宏与 API

```c
// 页大小
#define PAGE_SIZE   (1UL << PAGE_SHIFT)  // 4096 (4KB)
#define PAGE_SHIFT  12

// GFP 标志 (分配时指定)
#define GFP_KERNEL   (__GFP_RECLAIM | __GFP_IO | __GFP_FS)  // 可睡眠
#define GFP_ATOMIC   (__GFP_HIGH | __GFP_KSWAPD_RECLAIM)    // 不可睡眠
#define GFP_DMA      (__GFP_DMA)         // 从 ZONE_DMA 分配
#define GFP_USER     (__GFP_RECLAIM | __GFP_IO | __GFP_FS | __GFP_HARDWALL)

// zone 选择: GFP 标志中的 zone modifier 决定从哪个 zone 分配
// __GFP_DMA → ZONE_DMA, __GFP_DMA32 → ZONE_DMA32, 无标志 → ZONE_NORMAL
```

---

## 八、源文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/mmzone.h` | zone, pglist_data, free_area, 水位线 |
| `include/linux/mm_types.h` | struct page, struct mm_struct, struct vm_area_struct |
| `include/linux/gfp.h` | GFP 标志定义 |
| `mm/page_alloc.c` | 伙伴系统核心 (alloc/free) |
| `mm/memblock.c` | 早期内存管理 |
| `mm/memory.c` | 页表操作, 缺页处理 |
| `arch/arm64/mm/init.c` | ARM64 内存初始化 |
