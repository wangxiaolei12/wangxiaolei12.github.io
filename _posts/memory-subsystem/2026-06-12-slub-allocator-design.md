---
layout: post
title: "Linux 内存管理(4): SLUB 分配器设计与实现 — 小对象分配回收"
date: 2026-06-12 15:04:00 +0800
excerpt: "Linux SLUB 分配器详解：kmem_cache 结构、per-CPU sheaves 快速路径、slab 页管理、freelist 空闲链、kmalloc 大小类。分配与释放的完整调用链。"
---

# Linux 内存管理(4): SLUB 分配器设计与实现

---

## 一、为什么需要 SLUB？

伙伴系统最小分配单位是 4KB (一页)。内核中大量小对象（task_struct 几KB, inode 几百字节, dentry...）用一整页太浪费。

SLUB 在 buddy 之上提供**小对象分配器**：

```
用户请求                     分配器选择
─────────                   ──────────
96 bytes (task_struct)   →  SLUB: kmem_cache_alloc()
4096 bytes (1 page)      →  Buddy: alloc_pages(0)
64KB (16 pages)          →  Buddy: alloc_pages(4)
256KB (vmalloc)          →  vmalloc()
```

---

## 二、核心数据结构

```
┌─────────────────────────────────────────────────────────────────────┐
│  kmem_cache ("task_struct" cache, object_size=832)                   │
│                                                                     │
│  ┌───────────────────────────────────────┐                          │
│  │  Per-CPU sheaves (cpu_sheaves)        │  ★ 快速路径，无锁        │
│  │  ┌─────┐ ┌─────┐ ┌─────┐             │                          │
│  │  │CPU 0│ │CPU 1│ │CPU 2│ ...         │                          │
│  │  │free │ │free │ │free │             │                          │
│  │  │objs │ │objs │ │objs │             │                          │
│  │  └─────┘ └─────┘ └─────┘             │                          │
│  └───────────────────────────────────────┘                          │
│                                                                     │
│  ┌───────────────────────────────────────┐                          │
│  │  Per-Node partial list                │  部分使用的 slab         │
│  │  node[0].partial → slab → slab → ... │                          │
│  │  node[1].partial → slab → ...        │                          │
│  └───────────────────────────────────────┘                          │
│                                                                     │
│  slab (一个或多个物理页):                                           │
│  ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┐                      │
│  │obj 0│obj 1│obj 2│obj 3│obj 4│obj 5│obj 6│                      │
│  │(used)│(free)│(used)│(free)│(free)│(used)│(free)│                 │
│  └─────┴──┼──┴─────┴──┼──┴──┼──┴─────┴──┼──┘                      │
│           │            │     │            │                         │
│           └────────────┴─────┴────────────┘                         │
│                    freelist 链表                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### struct kmem_cache

```c
// mm/slab.h
struct kmem_cache {
    struct slub_percpu_sheaves __percpu *cpu_sheaves; // per-CPU 快速缓存
    slab_flags_t flags;
    unsigned long min_partial;         // partial list 最小保留数
    unsigned int size;                 // 对象大小 (含元数据)
    unsigned int object_size;          // 用户请求的对象大小
    unsigned int offset;               // freelist 指针在对象内的偏移
    struct kmem_cache_order_objects oo; // slab 的 order 和 objects/slab
    gfp_t allocflags;
    void (*ctor)(void *object);        // 构造函数
    const char *name;                  // cache 名称
    struct list_head list;             // 全局 cache 链表

    struct kmem_cache_per_node_ptrs per_node[MAX_NUMNODES]; // per-node partial
};
```

### Slab 页 (struct slab, 复用 struct page)

```c
// 一个 slab 就是一个 compound page，page->slab_cache 指向所属 cache
// page->freelist: 第一个空闲对象
// page->inuse: 已使用对象数
// page->objects: 总对象数
```

---

## 三、分配流程 — kmem_cache_alloc

```
kmem_cache_alloc(cache, gfp)
    │
    ▼
slab_alloc_node(cache, gfp, node, caller)
    │
    ├── ★ 快速路径: 从 per-CPU sheaf 取
    │       object = sheaf->objects[--sheaf->count];
    │       if (object) return object;  // 无锁，最快
    │
    ├── sheaf 空了 → ___slab_alloc() 慢速路径
    │       │
    │       ├── 尝试从当前 CPU 的 slab (c->slab) 取
    │       │       freelist = slab->freelist;
    │       │       if (freelist) {
    │       │           object = freelist;
    │       │           slab->freelist = next_free(object);
    │       │           return object;
    │       │       }
    │       │
    │       ├── 当前 slab 满了 → deactivate, 从 partial list 取新 slab
    │       │       slab = get_partial(cache, node);
    │       │       // 从 per-node partial 链表取一个有空闲的 slab
    │       │
    │       └── partial 也没有 → allocate_slab()
    │               → alloc_pages(gfp, oo_order(cache->oo))
    │               // 从 buddy 分配新的页，切成 objects
    │               → 初始化 freelist 链表
    │               → 返回第一个 object
    │
    └── 返回 object 指针给调用者
```

### Freelist 链表结构

```
一个 slab 内 (假设 object_size=128, page=4096, objects=32):

┌──────────────────────────────────────────────┐
│ obj[0] │ obj[1] │ obj[2] │ obj[3] │ ...      │
│ [data] │ [FREE] │ [data] │ [FREE] │          │
│        │ next→──┼────────┼→next──→│ NULL     │
└──────────────────────────────────────────────┘
           ↑
       slab->freelist 指向第一个空闲 object

freelist 指针存储在 object 内部 (offset 位置):
  object + cache->offset = 指向下一个空闲 object
  (SLUB 不需要额外元数据空间，复用空闲 object 本身！)
```

---

## 四、释放流程 — kmem_cache_free

```
kmem_cache_free(cache, object)
    │
    ▼
slab_free(cache, slab, object)
    │
    ├── ★ 快速路径: 放回 per-CPU sheaf
    │       sheaf->objects[sheaf->count++] = object;
    │       if (count < capacity) return;  // 无锁，最快
    │
    ├── sheaf 满了 → __slab_free() 慢速路径
    │       │
    │       ├── 将 object 放回 slab 的 freelist 头部
    │       │       object->next_free = slab->freelist;
    │       │       slab->freelist = object;
    │       │       slab->inuse--;
    │       │
    │       ├── slab 从满变为部分使用？
    │       │       → 加入 per-node partial list
    │       │
    │       └── slab 完全空闲 (inuse == 0)？
    │               → 如果 partial 太多，释放回 buddy
    │                 free_slab() → __free_pages()
    │
    └── 完成
```

---

## 五、kmalloc — 通用小内存分配

`kmalloc` 是基于预定义大小类的 SLUB 快捷方式：

```c
void *kmalloc(size_t size, gfp_t flags)
{
    // size → 找到最接近的 kmalloc cache
    // 预定义大小: 8, 16, 32, 64, 96, 128, 192, 256, 512,
    //            1024, 2048, 4096, 8192, 16384, 32768...
    struct kmem_cache *cache = kmalloc_slab(size, flags);
    return kmem_cache_alloc(cache, flags);
}

void kfree(const void *ptr)
{
    // 从 page 反查所属 kmem_cache
    struct slab *slab = virt_to_slab(ptr);
    kmem_cache_free(slab->slab_cache, ptr);
}
```

```bash
# 查看系统所有 slab cache:
cat /proc/slabinfo
# 或
slabtop
```

```
name              <active_objs> <num_objs> <objsize> <objperslab> <pagesperslab>
task_struct            520        540       7616          4          8
inode_cache           8234      8370        680         12          2
dentry               12453     12510        192         21          1
kmalloc-256           1024      1024        256         16          1
kmalloc-128           2048      2048        128         32          1
```

---

## 六、kmem_cache_create — 创建自定义 cache

```c
// 驱动/子系统为自己的常用结构创建专用 cache:
struct kmem_cache *my_cache;

my_cache = kmem_cache_create(
    "my_objects",          // name (显示在 /proc/slabinfo)
    sizeof(struct my_obj), // object_size
    0,                     // align (0=自动)
    SLAB_HWCACHE_ALIGN,    // flags
    my_constructor         // ctor (可选)
);

// 分配:
struct my_obj *obj = kmem_cache_alloc(my_cache, GFP_KERNEL);

// 释放:
kmem_cache_free(my_cache, obj);

// 销毁 cache:
kmem_cache_destroy(my_cache);
```

---

## 七、SLUB vs 旧 SLAB 对比

| | SLAB (已移除) | SLUB (当前唯一) |
|---|---|---|
| 复杂度 | 高 (三链表 + 着色) | 低 (freelist 嵌入对象) |
| 元数据开销 | 大 (单独管理结构) | 小 (复用 page struct) |
| 调试 | 差 | 好 (红区/毒化/跟踪) |
| NUMA | 复杂 | 简洁 per-node partial |
| 性能 | per-CPU arrays | per-CPU sheaves |
| 状态 | 6.8 内核移除 | 唯一实现 |

---

## 八、源文件索引

| 文件 | 内容 |
|------|------|
| `mm/slub.c` | SLUB 核心：alloc/free/new_slab |
| `mm/slab.h` | struct kmem_cache 定义 |
| `mm/slab_common.c` | kmem_cache_create, kmalloc 初始化 |
| `include/linux/slab.h` | 用户 API: kmalloc/kfree/kmem_cache_* |
| `mm/kasan/` | KASAN 内存检测与 SLUB 集成 |
