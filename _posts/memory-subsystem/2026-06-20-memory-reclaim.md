---
layout: post
title: "Linux 内存管理(6): 内存回收全过程 — 水位线、LRU、文件页、匿名页与 Swap"
date: 2026-06-20 23:00:00 +0800
excerpt: "深入分析 Linux 内存回收机制：水位线计算与触发条件、kswapd 与 direct reclaim 两条路径、LRU 链表组织与页面流动、文件页与匿名页的回收策略、Swap 写出全流程、Workingset 检测与 MGLRU。基于 mm/vmscan.c。"
---

# Linux 内存管理(6): 内存回收全过程

---

## 一、水位线（Watermarks）：什么时候触发回收

### 1.1 三条水位线

每个 zone 有三条核心水位线，定义在 `include/linux/mmzone.h`：

```c
enum zone_watermarks {
    WMARK_MIN,    // 最低水位 — direct reclaim 阈值
    WMARK_LOW,    // 低水位 — 唤醒 kswapd
    WMARK_HIGH,   // 高水位 — kswapd 回收目标
    WMARK_PROMO,  // NUMA 分层提升水位
    NR_WMARK
};
```

以 **8GB arm64 系统**为例（默认配置），最终值为：

```
空闲内存
  ↑
  │
27.7MB ── HIGH ──  kswapd 回收到这里就停，任务完成
  │       ↕ 8.2MB
19.5MB ── LOW ───  空闲内存降到这里，后台唤醒 kswapd
  │       ↕ 8.2MB
11.3MB ── MIN ───  降到这里，进程阻塞，自己做回收（direct reclaim）
  │
  │       [紧急保留区，普通分配拿不到]
  ↓
```

### 1.2 水位线怎么算出来的

计算发生在 `mm/page_alloc.c: __setup_per_zone_wmarks()`，系统启动时调用一次。

#### 第 1 步：算系统需要保留多少空闲内存

```c
// mm/page_alloc.c: calculate_min_free_kbytes()
lowmem_kbytes = nr_free_buffer_pages() * (PAGE_SIZE >> 10);
new_min_free_kbytes = int_sqrt(lowmem_kbytes * 16);
```

- `lowmem_kbytes`：所有低端内存 zone 的 managed 页面总量（KB）。64 位系统上约等于全部物理内存。
- 公式：`min_free_kbytes = sqrt(总内存KB × 16)`

8GB 系统：
```
lowmem_kbytes ≈ 8,388,608 KB
min_free_kbytes = sqrt(8,388,608 × 16) = sqrt(134,217,728) ≈ 11,585 KB
```

#### 第 2 步：KB 转页数

```
pages_min = 11,585 KB ÷ 4 KB/页 = 2896 页
```

#### 第 3 步：按 zone 比例分配得到 WMARK_MIN

```c
tmp = (u64)pages_min * zone_managed_pages(zone);
tmp = div64_ul(tmp, lowmem_pages);
zone->_watermark[WMARK_MIN] = tmp;
```

单 zone 情况下，WMARK_MIN = 2896 页 ≈ 11.3 MB。

#### 第 4 步：算水位间距

```c
tmp = max_t(u64, tmp >> 2,
            mult_frac(zone_managed_pages(zone), watermark_scale_factor, 10000));
```

取两个值中较大的：
- **保底值**：`WMARK_MIN / 4 = 724 页`（防止间距太小）
- **比例值**：`zone总页数 × watermark_scale_factor / 10000 = 2,097,152 × 10 / 10000 = 2097 页`

`watermark_scale_factor` 默认 10（万分之十 = 0.1%），可通过 `/proc/sys/vm/watermark_scale_factor` 调节（范围 1~3000）。

8GB 系统取 max(724, 2097) = **2097 页 ≈ 8.2 MB**。

#### 第 5 步：等差叠加

```c
zone->_watermark[WMARK_LOW]  = min_wmark_pages(zone) + tmp;
zone->_watermark[WMARK_HIGH] = low_wmark_pages(zone) + tmp;
```

```
WMARK_MIN  = 2896 页  (11.3 MB)
WMARK_LOW  = 2896 + 2097 = 4993 页  (19.5 MB)
WMARK_HIGH = 4993 + 2097 = 7090 页  (27.7 MB)
```

### 1.3 水位线触发的行为

| 空闲内存位置 | 发生什么 | 代码位置 |
|---|---|---|
| > HIGH | 正常分配 | `get_page_from_freelist()` 快速路径 |
| < LOW | 唤醒 kswapd | `wakeup_kswapd()` |
| < MIN | 进程自己做 direct reclaim | `__alloc_pages_slowpath()` → `try_to_free_pages()` |
| 回收失败 | OOM killer | `__alloc_pages_may_oom()` |

### 1.4 watermark_boost

当分配器检测到内存碎片化时，临时抬高所有水位（默认最多抬高 150%），让 kswapd 更积极回收，给 kcompactd 留空间做碎片整理。回收完成后清零。

```c
static inline unsigned long wmark_pages(const struct zone *z, enum zone_watermarks w)
{
    return z->_watermark[w] + z->watermark_boost;  // 运行时水位 = 基础值 + boost
}
```

---

## 二、回收的两条路径

### 2.1 kswapd — 后台异步回收

每个 NUMA node 一个内核线程，不阻塞用户进程。

```
kswapd()                           // mm/vmscan.c
  └─ for(;;)
       ├─ kswapd_try_to_sleep()    // 等待唤醒
       └─ balance_pgdat()          // 核心回收循环
            ├─ pgdat_balanced()？  // 所有 zone ≥ HIGH？是则停
            ├─ kswapd_age_node()   // 老化：把 active 页赶到 inactive
            └─ kswapd_shrink_node()
                 └─ shrink_node()  // 执行回收
```

**触发**：`get_page_from_freelist()` 中发现空闲 < LOW → `wakeup_kswapd()`
**目标**：回收到空闲 ≥ HIGH

### 2.2 Direct Reclaim — 同步直接回收

分配内存的进程自己被阻塞做回收。

```
__alloc_pages_slowpath()                // mm/page_alloc.c
  ├─ wake_all_kswapds()                // 顺便唤醒 kswapd
  ├─ __alloc_pages_direct_reclaim()
  │     └─ __perform_reclaim()
  │           └─ try_to_free_pages()   // 进入 mm/vmscan.c
  │                └─ do_try_to_free_pages()
  ├─ __alloc_pages_direct_compact()    // 内存压缩
  └─ __alloc_pages_may_oom()           // OOM killer
```

`try_to_free_pages()` 初始化 `scan_control`：
```c
struct scan_control sc = {
    .nr_to_reclaim = SWAP_CLUSTER_MAX,  // 目标回收 32 页
    .priority = DEF_PRIORITY,           // 初始 priority = 12
    .may_writepage = 1,
    .may_unmap = 1,
    .may_swap = 1,
};
```

---

## 三、回收核心框架

### 3.1 调用链

```
do_try_to_free_pages()         // priority 12→0 循环
  └─ shrink_zones()            // 遍历各 zone
       └─ shrink_node()        // 对每个 node 回收
            └─ shrink_lruvec() // 对一组 LRU 链表操作
                 ├─ get_scan_count()        // 决定扫描 anon/file 各多少
                 └─ shrink_list()           // 对每个 LRU 链表
                      ├─ shrink_active_list()    // active → inactive（老化）
                      └─ shrink_inactive_list()  // 从 inactive 回收
                           ├─ isolate_lru_folios()   // 隔离一批页
                           ├─ shrink_folio_list()     // 逐页判断回收
                           └─ move_folios_to_lru()    // 未回收的放回
```

### 3.2 Priority 机制

```
扫描量 = LRU 总页数 >> priority

priority=12 → 扫描 1/4096（很温和）
priority=6  → 扫描 1/64
priority=0  → 扫描全部（最激进）
```

`do_try_to_free_pages()` 中：
```c
do {
    shrink_zones(zonelist, sc);
    if (sc->nr_reclaimed >= sc->nr_to_reclaim)
        break;
} while (--sc->priority >= 0);
```

---

## 四、LRU 链表：页面怎么组织

### 4.1 四个链表

每个 `lruvec`（per-node 或 per-memcg）维护：

```c
struct lruvec {
    struct list_head lists[NR_LRU_LISTS];
    unsigned long    anon_cost;   // 匿名页回收代价
    unsigned long    file_cost;   // 文件页回收代价
    unsigned long    refaults[];  // refault 计数
};

enum lru_list {
    LRU_INACTIVE_ANON = 0,  // 不活跃匿名页
    LRU_ACTIVE_ANON   = 1,  // 活跃匿名页
    LRU_INACTIVE_FILE = 2,  // 不活跃文件页
    LRU_ACTIVE_FILE   = 3,  // 活跃文件页
};
```

### 4.2 页面流动

```
新页 → inactive 尾部
         │
         │ 被再次访问
         ↓
      active 头部（受保护）
         │
         │ shrink_active_list()：未被引用则降级
         ↓
      inactive 头部
         │
         │ shrink_folio_list()：无引用则回收
         ↓
      回收释放 / swap out
```

### 4.3 shrink_active_list() — 老化

从 active 链表隔离一批页，逐个检查：

```c
// 检查 PTE 中的 Access bit
if (folio_referenced(folio, ...)) {
    // 可执行文件页 + 被引用 → 留在 active（rotate）
    if ((vm_flags & VM_EXEC) && folio_is_file_lru(folio)) {
        list_add(&folio->lru, &l_active);
        continue;
    }
}
// 其余降级到 inactive
folio_clear_active(folio);
folio_set_workingset(folio);
list_add(&folio->lru, &l_inactive);
```

### 4.4 active/inactive 比例

```c
inactive_ratio = int_sqrt(10 * gb);
// 8GB → ratio = sqrt(80) ≈ 9，即 active:inactive ≈ 9:1
```

如果 `inactive_is_low()` 返回 true（inactive 太少），会触发 `shrink_active_list()` 补充 inactive。

---

## 五、文件页 vs 匿名页：回收谁

### 5.1 get_scan_count() — 决定扫描比例

| 情况 | 决策 | 原因 |
|---|---|---|
| 没有 swap 空间 | 只扫文件页 | 匿名页无处可去 |
| 有大量干净文件缓存（cache_trim_mode） | 只扫文件页 | 零 IO 代价 |
| 文件页极少（file_is_tiny） | 只扫匿名页 | 不能逼文件缓存为零 |
| priority=0（紧急） | 等比扫描 | 急了什么都来 |
| 正常情况（SCAN_FRACT） | 按比例 | swappiness + refault 代价 |

### 5.2 正常比例计算

```c
// mm/vmscan.c: calculate_pressure_balance()
total_cost = anon_cost + file_cost;
anon_cost_adj = total_cost + anon_cost;  // 保证至少 1/3 压力
file_cost_adj = total_cost + file_cost;

ap = swappiness * (anon_cost_adj + file_cost_adj) / anon_cost_adj;
fp = (200 - swappiness) * (anon_cost_adj + file_cost_adj) / file_cost_adj;
```

- **swappiness**（默认 60）：越大越倾向 swap 匿名页
- **anon_cost / file_cost**：来自 refault 反馈，回收代价高的一侧分配更少扫描压力

---

## 六、文件页回收

在 `shrink_folio_list()` 中：

### 干净文件页

```
直接从 page cache 移除 → 释放物理页
零 IO 代价，最优先回收对象
```

### 脏文件页

```c
static pageout_t pageout(struct folio *folio, ...) {
    // 普通文件脏页：不主动写回，避免破坏磁盘顺序 IO
    if (!shmem_mapping(mapping) && !folio_test_anon(folio))
        return PAGE_ACTIVATE;  // 放回 active 保护

    // shmem/tmpfs 脏页：通过 swap 写出
    return writeout(folio, mapping, ...);
}
```

普通文件脏页靠 writeback 线程（flusher）在后台刷盘，回收时只标记 `PG_reclaim`，等写完下次再回收。

---

## 七、匿名页回收与 Swap

### 7.1 Swap 写出流程

匿名页没有磁盘文件对应，回收必须经过 swap：

```
shrink_folio_list() 中：

① folio_alloc_swap(folio)          // mm/swapfile.c
   → 从 swap area 分配 slot
   → 加入 swap cache

② folio_mark_dirty(folio)
   → 标记脏

③ try_to_unmap(folio)              // 反向映射
   → 遍历所有映射该页的进程
   → 把 PTE 替换为 swap entry

④ pageout() → swap_writeout()     // mm/page_io.c
   ├─ 全零页 → swap_zeromap_folio_set()（不写 IO）
   ├─ zswap_store() → 压缩后存内存（优先）
   └─ __swap_writepage() → 写到 swap 设备

⑤ __remove_mapping()
   → 从 swap cache 移除
   → 释放物理页框
```

### 7.2 Swap 读入（page fault 路径）

```
进程访问 swap entry → do_swap_page()
  → 分配新物理页
  → 从 swap 设备/zswap 读入
  → workingset_refault() 评估是否激活
  → 建立页表映射
```

---

## 八、shrink_folio_list() — 逐页回收判定

这是回收的最核心函数，对 inactive 链表隔离出的每一页做决定：

```
对每个 folio：
  │
  ├─ trylock 失败 → 跳过
  ├─ 不可驱逐（mlock）→ 移到 unevictable
  ├─ 正在 writeback → 标记后跳过
  │
  ├─ folio_check_references()：
  │     ├─ VM_LOCKED → unevictable
  │     ├─ 被引用 + 之前也被引用 → ACTIVATE（放回 active）
  │     ├─ 被引用 + 可执行文件页 → ACTIVATE
  │     ├─ 被引用但第一次 → KEEP（再给一次机会）
  │     └─ 未被引用 → RECLAIM（继续回收）
  │
  ├─ 可 demote → 迁移到慢速 NUMA 节点
  ├─ 匿名页 → folio_alloc_swap() 分配 swap
  ├─ 有映射 → try_to_unmap() 解除 PTE
  │     └─ 失败 → 放回 active
  ├─ 脏页 → pageout()
  │     ├─ 普通文件脏页 → 不写，activate
  │     └─ anon/shmem → 写 swap
  └─ 干净无引用 → __remove_mapping() → 释放！
```

---

## 九、Workingset 检测 — 防止回收抖动

`mm/workingset.c` 实现了基于 refault distance 的工作集检测。

### 核心思想

```
              +--------------+                +-------------+
  reclaim ← |   inactive   | ←── demotion ──|    active   | ←─ promotion
              +--------------+                +-------------+
```

- 页面被驱逐时，在 page cache 留下 **shadow entry**（记录驱逐时的时间戳）
- 页面再次被访问（refault）时，计算 refault distance

### 判断逻辑

```c
void workingset_refault(struct folio *folio, void *shadow) {
    // refault_distance = 当前时间戳 - 驱逐时时间戳
    if (!workingset_test_recent(shadow, ...))
        return;  // 距离太远，正常放 inactive

    // 距离 ≤ workingset_size → 直接激活
    folio_set_active(folio);
    mod_lruvec_state(lruvec, WORKINGSET_ACTIVATE_BASE + file, nr);
}
```

**含义**：如果 refault distance ≤ active list 大小，说明这页本应留在内存却被冤枉赶走了，直接激活。

### 反馈机制

refault 增多 → 该类型回收代价（anon_cost/file_cost）上升 → `get_scan_count()` 减少对该侧扫描 → 恢复平衡。

---

## 十、MGLRU（Multi-Gen LRU）— 新一代回收算法

内核 6.1+ 引入，替代经典 active/inactive 双链表。

### 经典 LRU 的问题

- 只有 2 个列表，区分度粗糙
- 依赖被动的 referenced bit 检查
- 大内存系统扫描代价高

### MGLRU 的设计

```c
struct lru_gen_folio {
    unsigned long max_seq;                    // 最年轻代号
    unsigned long min_seq[ANON_AND_FILE];     // 最老代号
    struct list_head folios[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];
};
```

- **4 代**（generation），而非 2 个列表
- **主动老化**：`aging` 操作扫描进程页表的 PTE Access bit，把被访问的页移到新一代
- **精准驱逐**：`eviction` 从最老一代回收，保证被回收的页面确实长时间未被访问

```
aging:    inc max_seq → 扫描页表 → 被访问的页移到新一代
eviction: inc min_seq → 从最老代回收 → shrink_folio_list()
```

---

## 十一、总结流程图

```
[进程分配内存] alloc_pages()
       │
       ├─ 空闲 > HIGH → 直接分配成功
       │
       ├─ 空闲 < LOW  → 唤醒 kswapd ────→ 后台回收到 ≥ HIGH
       │                                         │
       ├─ 空闲 < MIN  → direct reclaim ──────────┤
       │   (进程阻塞，自己回收)                     │
       │                                         ↓
       │                              shrink_lruvec()
       │                              ├─ get_scan_count()：按比例分配
       │                              ├─ 文件页：干净的直接释放，脏的等 writeback
       │                              ├─ 匿名页：分配swap → unmap → 写出 → 释放
       │                              └─ workingset 反馈调节扫描比例
       │
       ├─ 回收成功 → 重新分配
       │
       └─ 回收失败 → OOM killer 杀进程释放内存
```

---

## 十二、调优参数

| 参数 | 默认值 | 作用 |
|---|---|---|
| `vm.min_free_kbytes` | sqrt(mem×16) | 直接设定 WMARK_MIN |
| `vm.watermark_scale_factor` | 10 | 水位间距（万分比），调大让 kswapd 更早介入 |
| `vm.watermark_boost_factor` | 15000 | 碎片化时临时抬高水位的系数 |
| `vm.swappiness` | 60 | anon/file 回收倾向，0=尽量不swap，200=极端swap |
| `vm.vfs_cache_pressure` | 100 | inode/dentry 缓存回收压力 |

**生产建议**：对延迟敏感的应用，调大 `watermark_scale_factor`（如 100~500），让 kswapd 更早工作，避免进程陷入 direct reclaim。
