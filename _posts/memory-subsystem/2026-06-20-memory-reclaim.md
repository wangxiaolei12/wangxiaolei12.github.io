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

### 2.3 回收路径中的同步与异步

"同步/异步"是 **writeback 层面**的概念，不是回收路径本身的分类：

| 模式 | 含义 | 谁用 |
|---|---|---|
| **异步 writeback** | 把脏页提交给 BDI flusher 线程，不等完成 | kswapd 默认 |
| **同步 writeback** | 等磁盘 IO 完成才继续 | Direct Reclaim 在 priority 低时 |
| **不写回** | 遇到脏页直接跳过 | Direct Reclaim 初期（priority 高） |

具体行为：
```
kswapd 遇到脏文件页：
  → 不主动写回，标记 PG_reclaim → activate
  → 让 flusher 线程在后台写回
  → 如果页面循环回来还在 writeback → 等待（reclaim_throttle）

Direct Reclaim 遇到脏页：
  → priority 高（12~8）：跳过（activate 放回）
  → priority 低（≤ 4）：
    - 匿名页：通过 pageout() 写 swap（可能同步等待 zswap 压缩）
    - 文件页：仍不主动写（只标记让 flusher 处理）
  → legacy memcg：可能 folio_wait_writeback() 同步等待 IO
```

关键原则：**回收路径尽量不做文件脏页的 writeback**，因为：
- 会破坏块设备层的 IO 调度（回收路径写的位置是随机的）
- 回收路径的上下文不适合做大量 IO
- 有专门的 flusher（writeback）线程负责

---

## 三、回收核心框架

### 3.1 调用链全景

```
alloc_pages() 失败
  │
  ▼
do_try_to_free_pages()          ← priority 12→0 循环
  │
  ▼ (每轮 priority--)
shrink_zones()                  ← 遍历各 zone
  │
  ▼
shrink_node()                   ← 处理 writeback 拥塞、throttle
  │
  ▼
shrink_node_memcgs()            ← 遍历每个 memcg
  │
  ▼
shrink_lruvec()                 ← 对一个 lruvec 的 4 条 LRU 链表操作
  │
  ├─ get_scan_count()           ← 决定 anon/file 各扫多少页
  │
  └─ for_each_evictable_lru(lru):
       └─ shrink_list(lru)
            ├─ active list  → shrink_active_list()    [老化：active→inactive]
            └─ inactive list → shrink_inactive_list() [真正回收]
                  │
                  ├─ isolate_lru_folios()    ← 从链表尾部摘出一批页
                  ├─ shrink_folio_list()     ← 逐页判断：回收/保留/激活
                  └─ move_folios_to_lru()    ← 没回收成功的放回链表
```

### 3.2 Priority 机制

```
扫描量 = LRU 总页数 >> priority

priority=12 → 扫描 1/4096（很温和）
priority=6  → 扫描 1/64
priority=0  → 扫描全部（最激进）
```

`do_try_to_free_pages()` 中的 priority 循环：
```c
// mm/vmscan.c: do_try_to_free_pages()
do {
    sc->nr_scanned = 0;
    shrink_zones(zonelist, sc);

    if (sc->nr_reclaimed >= sc->nr_to_reclaim)
        break;                       // 回收够了就停

    if (sc->compaction_ready)
        break;                       // 有足够连续内存可供压缩
} while (--sc->priority >= 0);       // 12→11→10→...→0
```

如果 priority 降到 0 仍回收不到足够内存，还有多次 retry 机会：
- `memcg_full_walk`：重新完整遍历 cgroup 树
- `force_deactivate`：强制降级 active 页
- `memcg_low_reclaim`：突破 memory.low 保护

### 3.3 shrink_lruvec() — LRU 级核心调度

这是实际驱动 4 条 LRU 链表扫描的函数：

```c
// mm/vmscan.c: shrink_lruvec()
static void shrink_lruvec(struct lruvec *lruvec, struct scan_control *sc)
{
    unsigned long nr[NR_LRU_LISTS];

    // 1. 决定每条 LRU 扫描多少页
    get_scan_count(lruvec, sc, nr);

    // 2. 按批次循环扫描，每批最多 SWAP_CLUSTER_MAX(32) 页
    while (nr[LRU_INACTIVE_ANON] || nr[LRU_ACTIVE_FILE] ||
                    nr[LRU_INACTIVE_FILE]) {
        for_each_evictable_lru(lru) {
            if (nr[lru]) {
                nr_to_scan = min(nr[lru], SWAP_CLUSTER_MAX);
                nr[lru] -= nr_to_scan;
                nr_reclaimed += shrink_list(lru, nr_to_scan, lruvec, sc);
            }
        }

        // 回收够了就停（kswapd 和 memcg 会按比例扫完）
        if (nr_reclaimed < nr_to_reclaim || proportional_reclaim)
            continue;
        ...
    }
}
```

`shrink_list()` 根据链表类型分发：
- active 链表 → `shrink_active_list()`（老化降级，不真正释放）
- inactive 链表 → `shrink_inactive_list()`（真正回收释放）

### 3.4 关于 folio

从内核 5.16 开始，回收代码操作的基本单位从 `struct page` 变为 `struct folio`：

```c
struct folio = 保证是 head page 的 page（消除 head/tail 歧义）
```

- 一个 folio 可能是 1 页（4KB）、多页大页（16KB mTHP）、或透明大页（2MB THP）
- 回收时用 `folio_nr_pages(folio)` 获取实际包含的 base page 数量
- 统计计数按实际页数，而非 folio 个数

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

### 4.2 页面在 LRU 中的流动

```
时间老化方向：  头部(新) ──────────────────→ 尾部(老)
                 │                              │
                 │    页面慢慢往尾部滑动          │
                 │    （因为新页不断插入头部）     │
                 │                              ▼
                 │                        被隔离出来尝试回收

页面生命周期：

  ┌─────────────────────────────────────────────────────────────┐
  │  新文件页读入 → inactive_file 头部                            │
  │       │                                                      │
  │       │ 被再次访问（mark_page_accessed / PTE Accessed=1）     │
  │       ▼                                                      │
  │  active_file 头部（受保护）                                    │
  │       │                                                      │
  │       │ shrink_active_list()：Accessed=0 → 降级               │
  │       ▼                                                      │
  │  inactive_file 头部                                           │
  │       │                                                      │
  │       │ 滑到尾部 → isolate → shrink_folio_list()              │
  │       ▼                                                      │
  │  回收释放（clean）或 标记writeback 后释放（dirty）              │
  └─────────────────────────────────────────────────────────────┘
```

### 4.3 isolate_lru_folios() — 隔离细节

从 LRU **尾部**（最老的页面）开始扫描，摘出一批页到临时列表：

```c
// mm/vmscan.c: isolate_lru_folios()
while (scan < nr_to_scan && !list_empty(src)) {
    folio = lru_to_folio(src);       // 从 LRU 尾部取

    // ① zone 不对？跳过（回收有 zone 限制）
    if (folio_zonenum(folio) > sc->reclaim_idx) {
        move_to = &folios_skipped;
        goto move;
    }

    // ② may_unmap=0 但页面 mapped？跳过
    if (!sc->may_unmap && folio_mapped(folio))
        goto move;

    // ③ 尝试获取引用（原子操作）
    if (!folio_try_get(folio))
        goto move;

    // ④ 清除 LRU 标志（标记正在被隔离，防止并发）
    if (!folio_test_clear_lru(folio)) {
        folio_put(folio);            // 别人已经在隔离了
        goto move;
    }

    // ⑤ 隔离成功
    nr_taken += nr_pages;
    move_to = dst;
move:
    list_move(&folio->lru, move_to);
}
```

关键点：
- 从尾部扫描 = 优先回收最久未被提升的页
- `folio_test_clear_lru` 是原子操作，保证不会两个线程同时隔离同一页
- zone 不匹配的页被跳过（splice 回链表头部避免反复扫）

### 4.4 shrink_active_list() — 老化（降级）

**目的**：把"不够热"的页从 active 赶到 inactive，为后续回收做准备。不释放任何页面。

```c
// mm/vmscan.c: shrink_active_list()
static void shrink_active_list(unsigned long nr_to_scan,
                               struct lruvec *lruvec, ...)
{
    LIST_HEAD(l_hold);       // 临时持有
    LIST_HEAD(l_active);     // 继续留在 active
    LIST_HEAD(l_inactive);   // 降级到 inactive

    // 1. 从 active 尾部隔离一批页
    lruvec_lock_irq(lruvec);
    nr_taken = isolate_lru_folios(nr_to_scan, lruvec, &l_hold, ...);
    lruvec_unlock_irq(lruvec);

    // 2. 逐页检查引用位
    while (!list_empty(&l_hold)) {
        folio = lru_to_folio(&l_hold);

        // 不可驱逐（mlock 等）→ 放回
        if (unlikely(!folio_evictable(folio))) {
            folio_putback_lru(folio);
            continue;
        }

        // 检查 PTE 中的 Accessed bit（遍历所有映射该页的进程页表）
        if (folio_referenced(folio, 0, sc->target_mem_cgroup, &vm_flags)) {
            // 被引用 + 可执行文件页 → 留在 active（给额外保护）
            if ((vm_flags & VM_EXEC) && folio_is_file_lru(folio)) {
                list_add(&folio->lru, &l_active);  // rotate 回 active
                continue;
            }
        }

        // 未被引用 或 不是可执行文件 → 降级到 inactive
        folio_clear_active(folio);
        folio_set_workingset(folio);      // 标记 workingset（用于 refault 检测）
        list_add(&folio->lru, &l_inactive);
    }

    // 3. 批量移回各自 LRU
    move_folios_to_lru(&l_active);     // 回到 active LRU 头部
    move_folios_to_lru(&l_inactive);   // 放到 inactive LRU 头部
}
```

**`folio_referenced()` 的工作原理**：

通过反向映射（rmap）遍历所有映射了该 folio 的进程页表项：
- 检查硬件 PTE 的 Accessed bit
- 如果 Accessed=1 → 清零（为下次检查做准备）→ 返回"被引用"
- 如果所有 PTE 的 Accessed=0 → 返回"未被引用"

这实现了经典的 **Clock / Second Chance 算法**：页面要被降级前，先检查引用位；被引用过则清零再给一次机会。

### 4.5 shrink_inactive_list() — 真正的回收

```c
// mm/vmscan.c: shrink_inactive_list()
static unsigned long shrink_inactive_list(unsigned long nr_to_scan,
        struct lruvec *lruvec, struct scan_control *sc, enum lru_list lru)
{
    LIST_HEAD(folio_list);

    // 1. 限流：如果已经隔离太多页，等一等（避免把 LRU 抽空）
    while (too_many_isolated(pgdat, file, sc))
        reclaim_throttle(pgdat, VMSCAN_THROTTLE_ISOLATED);

    // 2. 加锁，从 inactive LRU 尾部隔离一批页
    lruvec_lock_irq(lruvec);
    nr_taken = isolate_lru_folios(nr_to_scan, lruvec, &folio_list, ...);
    lruvec_unlock_irq(lruvec);

    if (nr_taken == 0)
        return 0;

    // 3. 核心：逐页尝试回收
    nr_reclaimed = shrink_folio_list(&folio_list, pgdat, sc, &stat, ...);

    // 4. 没回收成功的放回 LRU
    move_folios_to_lru(&folio_list);

    // 5. 如果全是脏页但没人在写 → 唤醒 flusher 线程
    if (stat.nr_unqueued_dirty == nr_taken)
        wakeup_flusher_threads(WB_REASON_VMSCAN);

    // 6. 记录回收代价（用于 get_scan_count 的反馈调节）
    lru_note_cost(lruvec, file, stat.nr_pageout, nr_scanned - nr_reclaimed);

    return nr_reclaimed;
}
```

### 4.6 active/inactive 比例

```c
inactive_ratio = int_sqrt(10 * gb);
// 8GB → ratio = sqrt(80) ≈ 9，即 active:inactive ≈ 9:1
```

如果 `inactive_is_low()` 返回 true（inactive 太少），会触发 `shrink_active_list()` 补充 inactive。

---

## 五、文件页 vs 匿名页：回收谁

### 5.1 get_scan_count() — 决定扫描比例

这个函数决定了 4 条 LRU 各扫描多少页，是回收策略的核心决策点。

决策逻辑（按优先级排列，满足则 goto out）：

```c
// mm/vmscan.c: get_scan_count()

// ① 没有 swap 或不允许 swap → 只扫文件页
if (!sc->may_swap || !can_reclaim_anon_pages(...))
    scan_balance = SCAN_FILE;

// ② cgroup 内 swappiness=0 → 只扫文件页
if (cgroup_reclaim(sc) && !swappiness)
    scan_balance = SCAN_FILE;

// ③ proactive reclaim 指定只回收匿名页
if (swappiness == SWAPPINESS_ANON_ONLY)
    scan_balance = SCAN_ANON;

// ④ priority=0（快 OOM 了）→ anon 和 file 等比例扫
if (!sc->priority && swappiness)
    scan_balance = SCAN_EQUAL;

// ⑤ 文件页极少 → 强制扫匿名页
if (sc->file_is_tiny)
    scan_balance = SCAN_ANON;

// ⑥ inactive file 够多（cache_trim_mode）→ 只扫文件
//    典型场景：大量顺序读产生的一次性缓存
if (sc->cache_trim_mode)
    scan_balance = SCAN_FILE;

// ⑦ 正常情况 → 按比例
scan_balance = SCAN_FRACT;
```

最终计算每条 LRU 的扫描量：

```c
out:
    for_each_evictable_lru(lru) {
        unsigned long lruvec_size = lruvec_lru_size(lruvec, lru, sc->reclaim_idx);
        unsigned long scan;

        // 基础扫描量 = 链表大小 >> priority
        scan = lruvec_size >> sc->priority;

        switch (scan_balance) {
        case SCAN_EQUAL:
            break;                           // 直接用基础值
        case SCAN_FRACT:
            scan = scan * fraction[file] / denominator;  // 按比例缩放
            break;
        case SCAN_FILE:
        case SCAN_ANON:
            if ((scan_balance == SCAN_FILE) != file)
                scan = 0;                    // 另一类不扫
            break;
        }

        nr[lru] = scan;
    }
```

| scan_balance | 含义 | 典型场景 |
|---|---|---|
| SCAN_FILE | 只扫文件页 | 无 swap / swappiness=0 / cache_trim |
| SCAN_ANON | 只扫匿名页 | 文件页极少 / proactive |
| SCAN_EQUAL | 等比例 | priority=0 紧急 |
| SCAN_FRACT | 按比例 | 正常运行 |

### 5.2 正常比例计算（SCAN_FRACT）

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

实际效果示例（swappiness=60，anon_cost=file_cost）：
```
ap ≈ 60, fp ≈ 140
file 扫描比例 ≈ 140/(60+140) = 70%
anon 扫描比例 ≈ 60/(60+140) = 30%
```

### 5.3 回收代价反馈（lru_note_cost）

每次 `shrink_inactive_list()` 完成后：

```c
lru_note_cost(lruvec, file, stat.nr_pageout, nr_scanned - nr_reclaimed);
```

- `nr_pageout`：写出了多少页（IO 代价）
- `nr_scanned - nr_reclaimed`：扫了但没回收成功的页数（无效扫描代价）

这些累计到 `lruvec->anon_cost` / `lruvec->file_cost`，下次 `get_scan_count()` 会据此调整扫描比例——哪一侧回收效率低就少扫哪一侧。

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

## 八、shrink_folio_list() — 逐页回收判定（源码详解）

这是回收的最核心函数，对 inactive 链表隔离出的每一页做生死判决。以下基于 `mm/vmscan.c` 源码逐步分析。

### 8.1 整体决策流程图

```
对每个 folio（从隔离列表取出）：
  │
  ├─① folio_trylock() 失败？
  │    → keep（放回 inactive，下次再试，避免死锁）
  │
  ├─② 硬件中毒页（HWPoison）？
  │    → unmap 并丢弃
  │
  ├─③ folio_evictable() = false？（mlock 等）
  │    → activate（移到 unevictable list）
  │
  ├─④ 正在 writeback？
  │    ├─ kswapd + 已标 reclaim + node 标记 WRITEBACK
  │    │    → activate（避免反复无效扫描）
  │    ├─ 普通情况：标记 reclaim flag，activate
  │    │    （下次如果还在 writeback 就是 case 1）
  │    └─ legacy memcg：同步等待
  │         → folio_wait_writeback() 后重试同一页
  │
  ├─⑤ folio_check_references() 检查引用：
  │    ├─ FOLIOREF_ACTIVATE → 踢回 active（太热）
  │    ├─ FOLIOREF_KEEP → 保留在 inactive（再给一次机会）
  │    └─ FOLIOREF_RECLAIM → 继续往下，尝试回收
  │
  ├─⑥ 可 demote 到低速 NUMA 节点？
  │    → 迁移到慢速 node（不释放物理页）
  │
  ├─⑦ 匿名页 + 没在 swap cache？
  │    → folio_alloc_swap()：分配 swap slot
  │    → 失败 → activate（无法回收）
  │    → 成功 → folio_mark_dirty()
  │
  ├─⑧ folio_mapped()？（有进程页表映射）
  │    → try_to_unmap()：通过 rmap 解除所有 PTE
  │    → 失败（有人 pin 住）→ activate
  │
  ├─⑨ folio_test_dirty()？
  │    ├─ 普通文件脏页：
  │    │    → 标记 reclaim，activate（让 flusher 写回）
  │    │    （回收代码不主动写文件脏页，避免破坏 IO 顺序）
  │    └─ 匿名页/shmem 脏页：
  │         → pageout()：发起写 swap I/O
  │         → PAGE_SUCCESS + 写完 → 继续释放
  │         → PAGE_SUCCESS + 还在写 → keep（下次回来）
  │
  ├─⑩ 有 buffer_head？
  │    → filemap_release_folio()：释放 buffer 映射
  │    → 失败 → activate
  │
  ├─⑪ __remove_mapping()：
  │    → 从 page cache / swap cache 中原子移除
  │    → 成功 → 页面彻底无人引用
  │
  └─⑫ free_it：
       → nr_reclaimed += folio_nr_pages(folio)
       → 加入 free_folios batch → free_unref_folios() 归还 buddy
```

### 8.2 folio_check_references() — 引用判定细节

```c
// mm/vmscan.c（简化）
static enum folio_references folio_check_references(struct folio *folio,
                                                     struct scan_control *sc)
{
    int referenced_ptes;      // PTE Accessed bit 被设置的次数
    int referenced_flag;      // page 自身的 Referenced flag

    referenced_ptes = folio_referenced(folio, ...);  // 遍历 rmap 检查 PTE
    referenced_flag = folio_test_clear_referenced(folio);  // 检查并清除 page flag

    if (referenced_ptes) {
        // 被页表引用过
        if (folio_is_file_lru(folio) && !referenced_flag
            && !folio_mapped_shared(folio))
            // 文件页 + 只被单进程映射 + 只引用一次 → 可回收
            // （典型场景：顺序读文件，read-once 模式）
            return FOLIOREF_RECLAIM_CLEAN;

        // 其余情况：被引用 → 踢回 active
        folio_set_referenced(folio);
        return FOLIOREF_ACTIVATE;
    }

    if (referenced_flag) {
        // PTE 没引用，但 page flag 有引用
        // （可能通过 mark_page_accessed 标记，非 mmap 访问）
        if (folio_is_file_lru(folio) && !folio_test_swapbacked(folio))
            return FOLIOREF_KEEP;  // 文件页保留在 inactive
    }

    return FOLIOREF_RECLAIM;  // 完全无引用，可回收
}
```

这实现了 **Second Chance / Clock 算法**的变体：
- 第一次到达 inactive 尾部有引用 → 清引用位，给第二次机会（activate）
- 第二次到达仍无引用 → 回收
- 特例：顺序读的文件页（单次引用）不给第二次机会，直接回收

### 8.3 Writeback 处理的三种情况

```c
// mm/vmscan.c: shrink_folio_list() 中的 writeback 处理
if (folio_test_writeback(folio)) {
    // Case 1: kswapd 发现页面在 writeback 且已标记 reclaim
    //         说明页面在 LRU 中转了一圈还没写完 → IO 跟不上
    if (current_is_kswapd() && folio_test_reclaim(folio) &&
        test_bit(PGDAT_WRITEBACK, &pgdat->flags)) {
        stat->nr_immediate += nr_pages;
        goto activate_locked;      // 赶走，让 kswapd 去做别的

    // Case 2: 首次遇到正在写回的页
    //         标记 reclaim 后放回，下次来如果写完了就可以回收
    } else if (...) {
        folio_set_reclaim(folio);
        stat->nr_writeback += nr_pages;
        goto activate_locked;

    // Case 3: legacy memcg，同步等待写回完成
    } else {
        folio_unlock(folio);
        folio_wait_writeback(folio);   // 阻塞等 IO 完成！
        list_add_tail(&folio->lru, folio_list);  // 放回列表重试
        continue;
    }
}
```

### 8.4 匿名页 swap 分配

```c
// 匿名页要回收必须先分配 swap slot
if (folio_test_anon(folio) && folio_test_swapbacked(folio) &&
        !folio_test_swapcache(folio)) {

    if (!(sc->gfp_mask & __GFP_IO))
        goto keep_locked;           // 不允许 IO → 无法 swap

    if (folio_maybe_dma_pinned(folio))
        goto keep_locked;           // 被 DMA pin 住 → 不能动

    // 大页尝试整体分配 swap，失败则 split 后逐页分配
    if (folio_test_large(folio)) {
        if (split_folio_to_list(folio, folio_list))
            goto activate_locked;
    }

    if (folio_alloc_swap(folio))     // 分配 swap slot 失败
        goto activate_locked;        // 没有 swap 空间了

    folio_mark_dirty(folio);         // 标记脏，后面 pageout 会写出
}
```

### 8.5 try_to_unmap() — 解除页表映射

```c
// 页面有映射（至少一个进程的页表指向它）
if (folio_mapped(folio)) {
    enum ttu_flags flags = TTU_BATCH_FLUSH;

    if (folio_test_large(folio))
        flags |= TTU_SYNC;          // 大页需要同步模式避免竞争

    try_to_unmap(folio, flags);      // 通过 rmap 遍历所有映射
    // → 对每个映射进程：
    //     PTE 清零（文件页）或 写入 swap entry（匿名页）
    //     TLB flush（批量）

    if (folio_mapped(folio)) {
        stat->nr_unmap_fail += nr_pages;
        goto activate_locked;        // unmap 失败 → 放弃回收
    }
}
```

### 8.6 脏页处理与 pageout()

```c
if (folio_test_dirty(folio)) {
    if (folio_is_file_lru(folio)) {
        // 普通文件脏页：不在这里写回！
        // 标记 immediate reclaim，让 flusher 线程处理
        folio_set_reclaim(folio);
        goto activate_locked;
        // 原因：回收路径写文件会破坏磁盘顺序 IO 调度
    }

    // 匿名页/shmem 脏页：通过 pageout() 写到 swap
    switch (pageout(folio, mapping, ...)) {
    case PAGE_KEEP:
        goto keep_locked;
    case PAGE_ACTIVATE:
        goto activate_locked;
    case PAGE_SUCCESS:
        // 写出成功
        if (folio_test_writeback(folio))
            goto keep;               // 异步 IO 还没完成
        // 同步 IO 已完成（ramdisk/zswap）→ 继续释放
        fallthrough;
    case PAGE_CLEAN:
        ; // 干净页，直接往下走释放
    }
}
```

### 8.7 最终释放 — __remove_mapping() + free

```c
// 从 page cache 或 swap cache 原子移除
if (!__remove_mapping(mapping, folio, true, sc->target_mem_cgroup))
    goto keep_locked;   // 移除失败（有人在用）→ 保留

folio_unlock(folio);

// 释放！
free_it:
    nr_reclaimed += nr_pages;
    folio_batch_add(&free_folios, folio);
    if (folio_batch_full(&free_folios)) {
        mem_cgroup_uncharge_folios(&free_folios);
        try_to_unmap_flush();          // 刷 TLB
        free_unref_folios(&free_folios);  // 归还 buddy allocator
    }
```

### 8.8 回收失败的处理

```c
activate_locked:
    // 回收失败但页面值得保护 → 提升到 active list
    folio_set_active(folio);
    stat->nr_activate[type] += nr_pages;

keep_locked:
    folio_unlock(folio);
keep:
    // 放回临时列表，最终由 move_folios_to_lru() 归还到 inactive LRU
    list_add(&folio->lru, &ret_folios);
```

### 8.9 一个完整的回收实例

**干净文件页**（最简单最快的路径）：
```
read() 读文件 → page cache 加入 inactive_file
  → 久未访问，滑到 inactive 尾部
  → isolate_lru_folios() 隔离
  → shrink_folio_list():
      trylock ✓
      not writeback ✓
      folio_check_references() → FOLIOREF_RECLAIM（无引用）
      not mapped（或已被 evict）
      not dirty ✓
      __remove_mapping() 从 page cache 移除 ✓
      → free_it → free_unref_folios() → 归还 buddy

  总计：零磁盘 IO，纯内存操作，微秒级完成
```

**匿名页**（最复杂最慢的路径）：
```
malloc() + write → page fault → 分配物理页加入 active_anon
  → shrink_active_list(): Accessed=0 → 降级到 inactive_anon
  → isolate_lru_folios() 隔离
  → shrink_folio_list():
      trylock ✓
      folio_check_references() → FOLIOREF_RECLAIM
      folio_alloc_swap() 分配 swap slot ✓
      folio_mark_dirty()
      try_to_unmap(): 清所有进程 PTE，写入 swap entry
      pageout() → swap_writepage() → 写磁盘/zswap
      IO 完成后 → __remove_mapping() 从 swap cache 移除
      → free_it

  总计：涉及 swap 分配 + rmap 遍历 + PTE 修改 + 磁盘/压缩 IO
  延迟：毫秒级
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
