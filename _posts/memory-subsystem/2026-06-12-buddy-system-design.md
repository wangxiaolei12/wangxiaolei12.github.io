---
layout: post
title: "Linux 内存管理(3): 伙伴系统设计与实现 — 分配与回收"
date: 2026-06-12 15:03:00 +0800
excerpt: "Linux Buddy System 伙伴算法详解：free_area 分层结构、__rmqueue_smallest 分配拆分、__free_one_page 回收合并、PCP 热页缓存、迁移类型与碎片规避。基于 mm/page_alloc.c。"
---

# Linux 内存管理(3): 伙伴系统设计与实现

---

## 一、伙伴系统概述

伙伴系统管理 **物理页帧的分配与回收**，以 2^order 个连续页为单位：

```
order:  0     1      2       3        ...    10
大小:   4KB   8KB   16KB    32KB      ...    4MB
页数:   1     2      4       8        ...    1024
```

### 核心数据结构

```c
// 每个 zone 有 11 个 order 的空闲链表
struct zone {
    struct free_area free_area[NR_PAGE_ORDERS]; // NR_PAGE_ORDERS = 11 (0~10)
};

// 每个 order 按迁移类型分多条链表
struct free_area {
    struct list_head free_list[MIGRATE_TYPES]; // UNMOVABLE/MOVABLE/RECLAIMABLE/CMA...
    unsigned long nr_free;                     // 该 order 总空闲块数
};
```

```
zone->free_area[] 结构:

free_area[0] (order 0, 4KB):
  ├── free_list[MIGRATE_UNMOVABLE] → page → page → ...
  ├── free_list[MIGRATE_MOVABLE]   → page → page → ...
  └── free_list[MIGRATE_RECLAIMABLE] → page → ...

free_area[1] (order 1, 8KB):
  ├── free_list[MIGRATE_UNMOVABLE] → page → ...
  ├── free_list[MIGRATE_MOVABLE]   → page → ...
  └── ...

...

free_area[10] (order 10, 4MB):
  ├── free_list[MIGRATE_UNMOVABLE] → page → ...
  └── ...
```

---

## 二、分配流程 — alloc_pages

### 调用链

```
alloc_pages(gfp_mask, order)                   [include/linux/gfp.h]
    │
    ▼
__alloc_pages(gfp, order, preferred_nid, nodemask)   [mm/page_alloc.c]
    │
    ├── prepare_alloc_pages()               // 确定 zone 列表
    │
    ├── get_page_from_freelist()            // ★ 快速路径
    │       │
    │       ├── for_each_zone_zonelist()    // 遍历 zonelist
    │       │       ├── zone_watermark_fast() // 检查水位线
    │       │       │     if (free_pages > mark + order)
    │       │       │         → 满足，尝试分配
    │       │       │
    │       │       └── rmqueue()           // ★ 从 zone 中取页
    │       │               ├── rmqueue_pcplist() // order=0: 从 PCP 取
    │       │               └── rmqueue_buddy()   // order>0: 从 buddy 取
    │       │                       └── __rmqueue()
    │       │                               └── __rmqueue_smallest()  ★
    │       │
    │       └── 成功返回 page
    │
    └── (快速路径失败) → 慢速路径
            ├── __alloc_pages_direct_reclaim()  // 直接回收
            ├── __alloc_pages_direct_compact()  // 内存规整
            ├── __alloc_pages_kswapd_wake()     // 唤醒 kswapd
            └── __alloc_pages_may_oom()         // OOM killer
```

### __rmqueue_smallest — 伙伴分配核心

```c
// mm/page_alloc.c
struct page *__rmqueue_smallest(struct zone *zone, unsigned int order,
                               int migratetype)
{
    unsigned int current_order;
    struct free_area *area;
    struct page *page;

    // ★ 从 order 向上找，找到有空闲块的层级
    for (current_order = order; current_order < NR_PAGE_ORDERS; ++current_order) {
        area = &(zone->free_area[current_order]);
        page = get_page_from_free_area(area, migratetype);
        if (!page)
            continue;  // 该 order 没有空闲块，找更大的

        // ★ 找到了！从链表摘除 + 拆分
        page_del_and_expand(zone, page, order, current_order, migratetype);
        return page;
    }
    return NULL;  // 所有 order 都没有
}
```

### 拆分过程 (expand / page_del_and_expand)

```
请求 order=1 (8KB)，但最小可用块是 order=3 (32KB):

free_area[3]: [████████████████████████████████] 32KB 块

拆分:
Step 1: 从 order=3 取出，拆成两个 order=2 (16KB)
  [████████████████] [████████████████]
   返回前半             放入 free_area[2]

Step 2: 前半再拆成两个 order=1 (8KB)
  [████████] [████████]
   返回前半   放入 free_area[1]

Step 3: 返回前半 order=1 给调用者

结果:
  free_area[1] 多了一个 8KB 块
  free_area[2] 多了一个 16KB 块
  调用者得到一个 8KB 块
```

```c
// 拆分核心逻辑 (简化):
static void expand(struct zone *zone, struct page *page,
                   int low, int high, int migratetype)
{
    unsigned long size = 1 << high;

    while (high > low) {
        high--;
        size >>= 1;  // 减半

        // 后半块加入低一级的空闲链表
        __add_to_free_list(&page[size], zone, high, migratetype, false);
        set_buddy_order(&page[size], high);
    }
}
```

---

## 三、回收流程 — free_pages

### 调用链

```
free_pages(addr, order) 或 __free_pages(page, order)
    │
    ▼
__free_pages(page, order)
    │
    ├── order == 0: free_unref_page(page)    // 归还 PCP
    │
    └── order > 0: __free_pages_ok(page, order)
            │
            ├── __free_pages_prepare()        // 检查/清理 page 状态
            │
            └── free_one_page()
                    └── __free_one_page()     // ★ 伙伴合并核心
```

### __free_one_page — 伙伴合并

```c
static inline void __free_one_page(struct page *page, unsigned long pfn,
                                   struct zone *zone, unsigned int order,
                                   int migratetype, fpi_t fpi_flags)
{
    // ★ 循环尝试合并伙伴
    while (order < MAX_PAGE_ORDER) {

        // 找伙伴: pfn XOR (1 << order)
        buddy = find_buddy_page_pfn(page, pfn, order, &buddy_pfn);
        if (!buddy)
            goto done_merging;  // 伙伴不空闲，停止

        // 伙伴也空闲！从空闲链表摘除
        __del_page_from_free_list(buddy, zone, order, buddy_mt);

        // 合并: 取两者中 PFN 较小的作为新块首页
        combined_pfn = buddy_pfn & pfn;
        page = page + (combined_pfn - pfn);
        pfn = combined_pfn;
        order++;  // 阶数 +1，继续尝试更高阶合并
    }

done_merging:
    // 将最终块加入对应 order 的空闲链表
    __add_to_free_list(page, zone, order, migratetype, ...);
    set_buddy_order(page, order);
}
```

### 伙伴查找原理

```
伙伴的 PFN = 当前 PFN XOR (1 << order)

例: order=2, PFN=0x100 (二进制 ...0001_0000_0000)
    buddy_pfn = 0x100 ^ (1<<2) = 0x100 ^ 0x4 = 0x104

验证: 两个 order=2 的块 (PFN 0x100 和 0x104) 合并后
      = order=3 块，PFN = 0x100 (取 AND)

物理内存:
  [0x100][0x101][0x102][0x103] | [0x104][0x105][0x106][0x107]
  ←──── order=2 块 ─────────→   ←──── 伙伴 order=2 ─────→
  ←───────────────── 合并后 order=3 ──────────────────────→
```

---

## 四、PCP — Per-CPU Page 缓存

单页 (order=0) 分配非常频繁，每次都走 buddy 加锁太慢。PCP 提供 per-CPU 无锁快速路径：

```
alloc_pages(GFP_KERNEL, 0)
    │
    ▼
rmqueue_pcplist()
    │
    ├── 从当前 CPU 的 pcp->lists[migratetype] 取一页
    │       → 无需 zone->lock！
    │
    └── PCP 为空？→ rmqueue_bulk() 从 buddy 批量补充 (batch 个)

free_pages(page, 0)
    │
    ▼
free_unref_page()
    │
    ├── 放回当前 CPU 的 pcp->lists[migratetype]
    │
    └── PCP 过满？→ free_pcppages_bulk() 归还 buddy (batch 个)
```

```c
struct per_cpu_pages {
    int count;           // 当前缓存页数
    int high;            // 上限，超过则归还 buddy
    int batch;           // 每次批量操作页数
    struct list_head lists[NR_PCP_LISTS]; // 按迁移类型的链表
};
```

---

## 五、迁移类型 — 抗碎片化

```c
enum migratetype {
    MIGRATE_UNMOVABLE,    // 内核数据，不可移动
    MIGRATE_MOVABLE,      // 用户页，可迁移 (compact)
    MIGRATE_RECLAIMABLE,  // 页缓存，可回收
    MIGRATE_PCPTYPES,     // 上面三种参与 PCP
    MIGRATE_HIGHATOMIC,   // 高优先级原子分配预留
    MIGRATE_CMA,          // CMA 区域
    MIGRATE_TYPES
};
```

**目的：** 将可移动和不可移动的页分开放，避免不可移动页散布导致无法形成大连续块。

```
pageblock (通常 2MB):
┌────────────────────────────────────────┐
│  MIGRATE_MOVABLE 的 pageblock          │ ← 用户页，将来可 compact
├────────────────────────────────────────┤
│  MIGRATE_UNMOVABLE 的 pageblock        │ ← 内核页，永远不动
├────────────────────────────────────────┤
│  MIGRATE_MOVABLE 的 pageblock          │
└────────────────────────────────────────┘

当 MOVABLE 不够时，会 fallback 到其他类型（steal 整个 pageblock）
fallbacks[MIGRATE_MOVABLE] = { RECLAIMABLE, UNMOVABLE }
```

---

## 六、完整分配示例

```
请求: alloc_pages(GFP_KERNEL, 2)  // 分配 16KB (4页)

1. gfp_mask → 确定 zone: ZONE_NORMAL
2. 遍历 zonelist，找到 ZONE_NORMAL
3. 检查水位线: free_pages > high_wmark + 4 → OK
4. rmqueue_buddy():
     __rmqueue_smallest(zone, order=2, MIGRATE_UNMOVABLE)
       for order=2: free_area[2].free_list[UNMOVABLE] → 找到一个块!
       page_del_and_expand(): 无需拆分(刚好 order=2)
       返回 page
5. prep_new_page(): 设置 page flags, 清引用计数
6. 返回 page 给调用者
```

---

## 七、源文件索引

| 文件 | 内容 |
|------|------|
| `mm/page_alloc.c` | 伙伴系统核心：alloc/free/expand/merge |
| `include/linux/mmzone.h` | zone, free_area, migratetype |
| `include/linux/gfp.h` | GFP 标志，alloc_pages 入口 |
| `include/linux/page-flags.h` | page 标志位定义 |
| `mm/compaction.c` | 内存规整 (compact) |
| `mm/page_isolation.c` | pageblock 隔离 |
| `mm/internal.h` | 内部辅助函数 |
