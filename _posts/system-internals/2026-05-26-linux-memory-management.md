---
layout: post
title: "Linux 内存管理全景分析：从物理页到虚拟地址"
date: 2026-05-26 16:00:00 +0800
excerpt: "基于 mainline 内核源码，全面分析 Linux 内存管理：物理内存组织、伙伴系统、SLUB 分配器、虚拟内存、Page Fault、MGLRU 页面回收、内存压缩等核心机制。"
---

# Linux 内存管理全景分析：从物理页到虚拟地址

## 一、物理内存组织

### 1.1 三级层次：Node → Zone → Page

```
┌─────────────────────────────────────────────────────┐
│                    系统物理内存                        │
├────────────────────────┬────────────────────────────┤
│       Node 0           │         Node 1             │  ← NUMA 节点
│   (pglist_data)        │     (pglist_data)          │
├──────┬──────┬──────────┼──────┬──────┬─────────────┤
│ZONE_ │ZONE_ │ZONE_     │ZONE_ │ZONE_ │ZONE_        │  ← 内存区域
│DMA   │DMA32 │NORMAL    │DMA   │DMA32 │NORMAL       │
├──────┴──────┴──────────┼──────┴──────┴─────────────┤
│  page/folio 数组        │   page/folio 数组          │  ← 页帧
└────────────────────────┴────────────────────────────┘
```

### 1.2 Zone 类型

```c
enum zone_type {
    ZONE_DMA,       // 低 16MB，老设备 DMA 限制
    ZONE_DMA32,     // 低 4GB，32位 DMA 设备
    ZONE_NORMAL,    // 正常可寻址内存
    ZONE_HIGHMEM,   // 仅 32 位系统，内核无法直接映射的高端内存
    ZONE_MOVABLE,   // 可迁移页，用于内存热插拔和大页
    ZONE_DEVICE,    // 持久内存/设备内存
};
```

### 1.3 水位线（Watermarks）

每个 Zone 维护三个水位线控制内存回收：

```
                    ┌─── zone 总页数
                    │
    ████████████████│████████████  ← WMARK_HIGH（kswapd 停止回收）
    ████████████████│
    ████████████████│█████████     ← WMARK_LOW（kswapd 开始回收）
    ████████████████│
    ████████████████│██████        ← WMARK_MIN（直接回收/OOM）
    ████████████████│
                    0
```

### 1.4 pglist_data（节点描述符）

```c
typedef struct pglist_data {
    struct zone node_zones[MAX_NR_ZONES];       // 该节点的所有 zone
    struct zonelist node_zonelists[MAX_ZONELISTS]; // 分配回退列表
    int nr_zones;
    unsigned long node_start_pfn;
    unsigned long node_present_pages;           // 物理页总数
    unsigned long node_spanned_pages;           // 跨度（含空洞）
    struct task_struct *kswapd;                 // 回收线程
    struct task_struct *kcompactd;              // 压缩线程
} pg_data_t;
```


## 二、伙伴系统（Buddy System）

### 2.1 核心数据结构

```
每个 Zone 维护 11 个 order 的空闲链表：

zone->free_area[0]  → 4KB 页的链表 (2^0)
zone->free_area[1]  → 8KB 块的链表 (2^1)
zone->free_area[2]  → 16KB 块的链表 (2^2)
...
zone->free_area[10] → 4MB 块的链表 (2^10)

每个 free_area 按迁移类型再分：
struct free_area {
    struct list_head free_list[MIGRATE_TYPES];
    unsigned long    nr_free;
};
```

### 2.2 迁移类型（反碎片化）

```c
enum migratetype {
    MIGRATE_UNMOVABLE,    // 内核数据，不可移动
    MIGRATE_MOVABLE,      // 用户页，可迁移
    MIGRATE_RECLAIMABLE,  // 缓存页，可回收
    MIGRATE_HIGHATOMIC,   // 高优先级原子分配保留
    MIGRATE_CMA,          // 连续内存分配器保留
};
```

将 pageblock（通常 2MB）按迁移类型分组，相同类型的分配聚集在一起，减少碎片。

### 2.3 分配过程

请求分配 order=1（8KB，2 页）的例子：

```
1. 先在 free_area[1] 找空闲块
   → 找到了？直接取出，完成

2. 找不到？向上找 free_area[2]（16KB）
   → 找到了？拆分：
     ┌────────────────┐
     │   16KB 块       │  ← 从 free_area[2] 取出
     └────────────────┘
           ↓ 拆分
     ┌────────┬────────┐
     │ 8KB(A) │ 8KB(B) │
     └────────┴────────┘
     A → 返回给请求者
     B → 放入 free_area[1] 作为空闲块

3. free_area[2] 也没有？继续向上找 free_area[3]（32KB）
   → 拆分两次：
     32KB → 16KB + 16KB(放回 free_area[2])
     16KB → 8KB(返回) + 8KB(放回 free_area[1])

4. 一直找到 free_area[10] 都没有 → 分配失败，进入慢速路径
```

图示：

```
分配 order=1，free_area[1] 为空，free_area[3] 有块：

free_area[3]: [████████ 32KB ████████]
                      ↓ 拆分
free_area[2]:                 [████ 16KB ████] ← 伙伴，放回
free_area[1]:         [██ 8KB ██]              ← 伙伴，放回
返回:          [██ 8KB ██]                      ← 给调用者
```

### 2.4 回收（释放）过程

释放 order=1（8KB）的块：

```
1. 找到它的"伙伴"（buddy）
   - 伙伴 = 与它大小相同、地址相邻、且对齐到 2^(order+1) 的块
   - 计算方式：buddy_pfn = pfn ^ (1 << order)

2. 伙伴空闲吗？
   ├── 是 → 合并！
   │   将伙伴从 free_area[1] 移除
   │   合并成 order=2 的块
   │   继续检查新块的伙伴...（递归合并）
   │
   └── 否 → 不合并
       直接将块放入 free_area[1]
```

递归合并示例：

```
释放 8KB 块 (pfn=4):

Step 1: buddy_pfn = 4 ^ 2 = 6
        pfn 6 空闲？是 → 合并成 16KB (pfn=4, order=2)

Step 2: 新块 pfn=4, order=2
        buddy_pfn = 4 ^ 4 = 0
        pfn 0 空闲？是 → 合并成 32KB (pfn=0, order=3)

Step 3: 新块 pfn=0, order=3
        buddy_pfn = 0 ^ 8 = 8
        pfn 8 空闲？否 → 停止
        放入 free_area[3]
```

### 2.5 PCP（Per-CPU Page Cache）快速路径

order=0 的分配/释放走 PCP，避免 zone lock：

```
分配 order=0:
  1. 关抢占，取当前 CPU 的 pcp
  2. pcp->lists[migratetype] 有页？→ 直接取，无需 zone lock
  3. 没有？→ 从 buddy 批量取 pcp->batch 个页填充 PCP

释放 order=0:
  1. 放入当前 CPU 的 pcp->lists[migratetype]
  2. pcp->count > pcp->high？→ 批量归还 pcp->batch 个页给 buddy
```

### 2.6 完整分配路径

```
alloc_pages(gfp_mask, order)
  → get_page_from_freelist()     // 快速路径
    ├── 遍历 zonelist
    ├── 检查水位线
    ├── order=0 → PCP 分配
    └── order>0 → buddy 分配
  → 如果失败：
    → __alloc_pages_slowpath()   // 慢速路径
      ├── 唤醒 kswapd
      ├── 直接回收（direct reclaim）
      ├── 内存压缩（compaction）
      └── OOM killer
```


## 三、SLUB 分配器

### 3.1 为什么需要 Slab

Buddy 最小分配 4KB（一页），但内核大量需要几十~几百字节的小对象。Slab 在 buddy 之上提供小对象分配。

```
用户/内核请求
     │
     ├── 大块（≥ 1 页）→ 直接走 Buddy
     │     alloc_pages(order)
     │
     └── 小对象（< 1 页）→ 走 SLUB
           kmalloc(size) → kmem_cache_alloc()
                │
                └── SLUB 内部需要新 slab 时
                    → 调用 alloc_pages() 从 Buddy 获取页
                    → 切成小对象管理
```

### 3.2 核心数据结构

```c
struct kmem_cache {
    struct kmem_cache_cpu __percpu *cpu_slab;  // Per-CPU 活跃 slab
    unsigned int size;          // 对象大小（含对齐）
    unsigned int object_size;   // 对象实际大小
    struct kmem_cache_node *node[];     // Per-node 部分满 slab 链表
};

struct kmem_cache_cpu {
    void **freelist;            // 当前 slab 的空闲对象链表
    struct slab *slab;          // 当前活跃 slab
    struct slab *partial;       // Per-CPU 部分满 slab 链表
};

struct slab {
    memdesc_flags_t flags;
    struct kmem_cache *slab_cache;
    struct list_head slab_list;
    struct freelist_counters;   // freelist + counters (lockless)
};
```

### 3.3 Slab 内部布局

```
一个 slab（假设 1 页 = 4096B，对象大小 = 192B）:

┌──────┬──────┬──────┬──────┬──────┬──────┬─────────┐
│obj 0 │obj 1 │obj 2 │obj 3 │ ...  │obj 20│ 剩余空间 │
│192B  │192B  │192B  │192B  │      │192B  │  (碎片) │
└──┬───┴──┬───┴──────┴──────┴──────┴──────┴─────────┘
   │      │
   │      └→ next_free 指针嵌入对象内部（对象空闲时）
   └→ freelist 头

空闲对象链表（嵌入式）:
  freelist → obj3 → obj7 → obj12 → NULL
  （已分配的对象中，next_free 位置被用户数据覆盖）
```

### 3.4 SLUB 分配过程

```
kmalloc(192) 或 kmem_cache_alloc(my_cache):

┌─────────────────────────────────────────────────────┐
│ 快速路径（无锁，最常见）                              │
│                                                     │
│ 1. 关抢占                                           │
│ 2. cpu_slab->freelist 非空？                        │
│    → 取 freelist 头部对象                           │
│    → freelist = object->next_free (cmpxchg)        │
│    → 返回对象 ✓                                    │
└─────────────────────────────────────────────────────┘
         │ freelist 为空
         ▼
┌─────────────────────────────────────────────────────┐
│ 中速路径                                            │
│                                                     │
│ 3. cpu_slab->partial 有 slab？                     │
│    → 取一个 partial slab 作为新的 cpu_slab->slab    │
│    → 从它的 freelist 分配                          │
│    → 返回对象 ✓                                    │
└─────────────────────────────────────────────────────┘
         │ partial 也空
         ▼
┌─────────────────────────────────────────────────────┐
│ 慢速路径（需要锁）                                   │
│                                                     │
│ 4. node->partial 有 slab？                         │
│    → 取锁，取一个 partial slab                     │
│    → 设为 cpu_slab->slab                           │
│    → 返回对象 ✓                                    │
│                                                     │
│ 5. 都没有 → 从 buddy 分配新页                      │
│    → allocate_slab() → alloc_pages(oo.order)       │
│    → 初始化 slab，构建 freelist                    │
│    → 返回第一个对象 ✓                              │
└─────────────────────────────────────────────────────┘
```

### 3.5 SLUB 释放过程

```
kfree(obj) 或 kmem_cache_free(cache, obj):

1. 找到对象所在的 slab（通过 virt_to_slab()）

┌─────────────────────────────────────────────────────┐
│ 快速路径：对象属于当前 CPU 的活跃 slab               │
│                                                     │
│ → object->next_free = cpu_slab->freelist (cmpxchg) │
│ → cpu_slab->freelist = object                      │
│ → 完成 ✓                                          │
└─────────────────────────────────────────────────────┘
         │ 不是当前 CPU 的 slab
         ▼
┌─────────────────────────────────────────────────────┐
│ 慢速路径                                            │
│                                                     │
│ 2. 将对象放回该 slab 的 freelist                    │
│                                                     │
│ 3. slab 从满变为部分满？                            │
│    → 放入 node->partial 链表                       │
│                                                     │
│ 4. slab 完全空闲（所有对象都释放了）？               │
│    → 从 partial 链表移除                           │
│    → 归还给 buddy: __free_pages(slab->page, order) │
└─────────────────────────────────────────────────────┘
```


## 四、虚拟内存管理

### 4.1 进程地址空间

```c
struct mm_struct {
    struct maple_tree mm_mt;     // VMA 树（替代了旧的红黑树）
    pgd_t *pgd;                 // 页全局目录（顶级页表）
    atomic_t mm_users;          // 用户引用计数
    atomic_t mm_count;          // 内核引用计数
    struct rw_semaphore mmap_lock; // mmap 读写锁
    unsigned long task_size;    // 用户空间大小
};
```

### 4.2 VMA（虚拟内存区域）

```c
struct vm_area_struct {
    unsigned long vm_start;     // 起始虚拟地址
    unsigned long vm_end;       // 结束虚拟地址
    struct mm_struct *vm_mm;    // 所属进程
    pgprot_t vm_page_prot;     // 页保护属性
    vm_flags_t vm_flags;       // 标志（读/写/执行/共享等）
    struct anon_vma *anon_vma;  // 匿名页反向映射
    struct file *vm_file;       // 映射的文件（NULL=匿名）
    unsigned long vm_pgoff;     // 文件偏移
    const struct vm_operations_struct *vm_ops;
#ifdef CONFIG_PER_VMA_LOCK
    unsigned int vm_lock_seq;   // Per-VMA 锁序列号
#endif
};
```

VMA 用 **Maple Tree** 组织（替代了旧的红黑树+链表），支持 RCU 读和更好的缓存局部性。

### 4.3 地址空间布局

```
64位进程地址空间 (以 x86_64 为例):

0x0000000000000000 ┌──────────────────┐
                   │    NULL 页        │
0x0000000000001000 ├──────────────────┤
                   │    代码段 (.text)  │
                   ├──────────────────┤
                   │    数据段 (.data)  │
                   ├──────────────────┤
                   │    BSS (.bss)     │
                   ├──────────────────┤
                   │    堆 (brk) ↓     │
                   │                  │
                   │    (空洞)         │
                   │                  │
                   │    mmap 区域 ↑    │
                   ├──────────────────┤
                   │    栈 ↓          │
0x00007FFFFFFFFFFF ├──────────────────┤
                   │   (非规范地址)    │
0xFFFF800000000000 ├──────────────────┤
                   │   内核空间        │
0xFFFFFFFFFFFFFFFF └──────────────────┘
```

## 五、页表与 Page Fault

### 5.1 多级页表

```
虚拟地址 → PGD → P4D → PUD → PMD → PTE → 物理页
            │     │     │     │     │
            9bit  9bit  9bit  9bit  9bit + 12bit offset
```

### 5.2 Page Fault 处理

```
handle_mm_fault(vma, address, flags)
  → __handle_mm_fault()
    ├── pgd_offset() → p4d_alloc() → pud_alloc() → pmd_alloc()
    │
    ├── 如果是大页 (PMD 级别):
    │   → create_huge_pmd()
    │
    └── handle_pte_fault()
        ├── pte 不存在:
        │   ├── 匿名页 → do_anonymous_page() → 分配零页/新页
        │   ├── 文件页 → do_fault() → 从 page cache 读取
        │   └── swap 页 → do_swap_page() → 从 swap 读回
        │
        ├── pte 存在但写保护:
        │   └── do_wp_page() → COW (Copy-On-Write)
        │
        └── NUMA fault → do_numa_page() → 迁移到本地节点
```

## 六、页面回收（MGLRU）

### 6.1 Multi-Gen LRU 数据结构

```c
struct lru_gen_folio {
    unsigned long max_seq;                              // 最新代
    unsigned long min_seq[ANON_AND_FILE];               // 最老代
    unsigned long timestamps[MAX_NR_GENS];              // 每代时间戳
    struct list_head folios[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];
    long nr_pages[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];
};
```

核心思想：

```
Generation:  0 (oldest)  →  1  →  2  →  3 (youngest)
             ↑ 回收方向                    ↑ 新页/被访问的页
```

- **Aging**：扫描页表，将被访问的页提升到最新代
- **Eviction**：从最老代开始回收
- 比传统 LRU 更精确地识别冷热页

### 6.2 回收触发

```
kswapd（后台回收）:
  当 free pages < WMARK_LOW 时被唤醒
  回收到 WMARK_HIGH 后睡眠

直接回收（direct reclaim）:
  当 free pages < WMARK_MIN 时
  分配者自己同步回收

OOM Killer:
  回收失败时，选择并杀死占内存最多的进程
```

### 6.3 可回收的页面类型

| 类型 | 来源 | 回收方式 |
|------|------|----------|
| 干净文件页 | page cache | 直接丢弃 |
| 脏文件页 | page cache | 写回磁盘后丢弃 |
| 匿名页 | 堆/栈/mmap | 写入 swap |
| slab 缓存 | dentry/inode cache | shrinker 回调 |

## 七、内存压缩（Compaction）

```
压缩前:
[used][free][used][free][used][free][used][free]

压缩后:
[used][used][used][used][free][free][free][free]
                         ↑ 连续空闲，可分配大页

工作方式:
  ← migrate_scanner (从低地址扫描可移动页)
  → free_scanner (从高地址扫描空闲页)
  两个扫描器相遇时完成
```

## 八、大页（Huge Pages）与 Folio

### 8.1 THP（Transparent Huge Pages）

```
普通页: 4KB (PTE 级别映射)
THP:    2MB (PMD 级别映射) 或 1GB (PUD 级别)
```

- `khugepaged`：后台扫描，将连续小页合并为大页
- 对应用透明，无需修改代码

### 8.2 Folio（新抽象）

```c
struct folio {
    memdesc_flags_t flags;
    struct address_space *mapping;
    pgoff_t index;
    atomic_t _mapcount;
    atomic_t _refcount;
    // 大页额外字段:
    atomic_t _large_mapcount;
    atomic_t _nr_pages_mapped;
};
```

明确表示"一个或多个连续物理页"的单位，统一大页/小页处理。

## 九、其他关键子系统

| 子系统 | 文件 | 功能 |
|--------|------|------|
| **vmalloc** | `vmalloc.c` | 虚拟连续但物理不连续的内核内存 |
| **CMA** | `cma.c` | 连续内存分配器（DMA 设备用） |
| **memcg** | `memcontrol.c` | cgroup 内存控制（限制/统计/回收） |
| **KSM** | `ksm.c` | 内核同页合并（去重） |
| **zswap** | `zswap.c` | 压缩 swap 缓存（内存中压缩存储） |
| **DAMON** | `damon/` | 数据访问监控（指导回收/迁移） |
| **rmap** | `rmap.c` | 反向映射（物理页→所有映射它的 PTE） |
| **migrate** | `migrate.c` | 页面迁移（NUMA 均衡/压缩/热插拔） |

## 十、整体数据流

```
用户 malloc()/mmap()
       │
       ▼
  VMA 创建 (mmap.c)          ← 只分配虚拟地址，不分配物理页
       │
       ▼ (首次访问)
  Page Fault (memory.c)      ← 按需分配物理页
       │
       ├── 匿名页 → Buddy/PCP 分配 (page_alloc.c)
       ├── 文件页 → Page Cache (filemap.c) → 磁盘 I/O
       └── Swap 页 → Swap In (swap_state.c)
       │
       ▼
  页表填充 (PTE/PMD)          ← 建立虚拟→物理映射
       │
       ▼ (内存紧张时)
  页面回收 (vmscan.c)         ← MGLRU aging/eviction
       │
       ├── 文件页 → 写回/丢弃
       ├── 匿名页 → Swap Out / zswap 压缩
       └── Slab → Shrinker 回调
       │
       ▼ (碎片化时)
  内存压缩 (compaction.c)     ← 整理碎片，生成连续空闲
       │
       ▼ (回收失败)
  OOM Killer (oom_kill.c)     ← 最后手段，杀进程释放内存
```

## 十一、设计趋势

1. **Folio 化**：全面用 folio 替代 page，统一大页/小页处理
2. **MGLRU**：替代传统 LRU，更智能的页面老化和回收
3. **Per-VMA Lock**：减少 mmap_lock 竞争，提升多线程 page fault 性能
4. **Maple Tree**：替代红黑树管理 VMA，更好的缓存和 RCU 支持
5. **DAMON**：基于采样的内存访问监控，指导主动回收和迁移
