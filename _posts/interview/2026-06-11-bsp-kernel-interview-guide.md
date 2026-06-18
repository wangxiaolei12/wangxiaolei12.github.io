---
layout: post
title: "BSP/Kernel 开发面试完整指南（含字节高频算法）"
date: 2026-06-11 18:30:00 +0800
excerpt: "系统整理 BSP/Linux Kernel 开发面试高频考点，涵盖 C 语言基础、ARM 体系结构、中断系统、同步机制、调试工具（perf/crash/BCC）以及字节跳动常考算法题。"
---

# BSP/Kernel 开发面试完整指南

---

## 一、C 语言基础

### volatile 的作用

```
- 告诉编译器不要优化该变量的读写，每次从内存重新取值
- 场景：
  1. MMIO 寄存器映射变量
  2. 中断服务程序修改的全局变量
  3. 多核共享变量（但不能替代内存屏障）
- 注意：volatile 不保证原子性
```

### 结构体对齐

```c
struct A {
    char a;     // offset 0, 填充3字节
    int b;      // offset 4
    short c;    // offset 8, 填充2字节
};  // sizeof = 12

#pragma pack(1)  // 取消对齐 sizeof = 7
```

### 位操作

```c
#define SET_BIT(reg, n)    ((reg) |= (1U << (n)))
#define CLR_BIT(reg, n)    ((reg) &= ~(1U << (n)))
#define GET_BIT(reg, n)    (((reg) >> (n)) & 1U)

// 统计1的个数
int popcount(unsigned int n) {
    int c = 0;
    while (n) { n &= (n - 1); c++; }
    return c;
}
```

### 手写 memcpy（处理重叠）

```c
void *my_memcpy(void *dst, const void *src, size_t n) {
    char *d = (char *)dst;
    const char *s = (const char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}
```

### 环形缓冲区 (Ring Buffer)

```c
typedef struct {
    uint8_t *buf;
    uint32_t size;          // 必须是2的幂
    volatile uint32_t head; // 写指针
    volatile uint32_t tail; // 读指针
} ring_buf_t;

int ring_put(ring_buf_t *rb, uint8_t data) {
    if (rb->head - rb->tail >= rb->size) return -1;
    rb->buf[rb->head & (rb->size - 1)] = data;
    __sync_synchronize();
    rb->head++;
    return 0;
}

int ring_get(ring_buf_t *rb, uint8_t *data) {
    if (rb->head == rb->tail) return -1;
    *data = rb->buf[rb->tail & (rb->size - 1)];
    __sync_synchronize();
    rb->tail++;
    return 0;
}
```

---

## 二、ARM 体系结构

### 启动流程

```
上电 → BootROM → SPL(初始化DDR) → U-Boot(加载kernel+dtb) → Kernel → init → Shell
```

### ARMv8 异常等级

```
EL0 - 用户态     EL1 - 内核
EL2 - Hypervisor EL3 - Secure Monitor (ATF)
```

### Cache 与 DMA 一致性

```
CPU→设备(DMA读)：flush/clean cache
设备→CPU(DMA写)：invalidate cache
API：dma_alloc_coherent() / dma_map_single() + dma_sync_*
```

### GIC 中断控制器

```
SPI - 共享外设中断，可路由到任意核
PPI - 每核私有（Timer）
SGI - 软件产生的核间中断 (IPI)
```

---

## 三、中断系统（重点）

### 中断全流程

```
硬件触发 → GIC Distributor → CPU Interface → CPU异常
→ 内核 irq_handler → irq_desc → irq_action → handler
→ 返回/调度下半部
```

### 上半部 vs 下半部

| 机制 | 上下文 | 可否睡眠 | 并发 | 适用场景 |
|------|--------|----------|------|----------|
| hardirq | 中断 | 不可 | - | ACK中断、保存关键数据 |
| softirq | 软中断 | 不可 | 同类型可多核并行 | 网络收发 |
| tasklet | 软中断 | 不可 | 同一个不并发 | 简单延迟处理 |
| workqueue | 进程 | 可以 | 可并发 | I2C/SPI读写等 |
| threaded_irq | 进程 | 可以 | 内核线程 | 推荐的现代写法 |

### softirq 详解

```
内核预定义类型（静态）：
HI_SOFTIRQ / TIMER_SOFTIRQ / NET_TX/RX / BLOCK / TASKLET / SCHED / RCU

执行时机：
1. 硬中断返回时 (irq_exit)
2. ksoftirqd 内核线程
3. local_bh_enable()

排查：/proc/softirqs 查看统计
问题：softirq 过多 → ksoftirqd 占CPU → 用户态饿死
```

### 中断上下文限制

```
- 不能睡眠（没有进程上下文）
- 不能用 mutex / semaphore
- 可以用 spinlock（必须 spin_lock_irqsave）
- 不能 copy_to_user / copy_from_user
- 不能做耗时操作
```

---

## 四、内核同步机制

| 机制 | 可睡眠 | 中断上下文 | 典型用途 |
|------|--------|-----------|----------|
| spinlock | 否 | 可 | 短临界区、寄存器操作 |
| mutex | 是 | 不可 | 长临界区、可能阻塞 |
| semaphore | 是 | 不可 | 资源计数 |
| RCU | 读无锁 | 读可 | 读多写少（路由表） |
| atomic | - | 可 | 单变量操作 |
| completion | 是 | 不可 | 等待事件完成 |

### RCU 原理

```
读者：rcu_read_lock()/unlock()（仅禁抢占，零开销）
写者：复制 → 修改副本 → rcu_assign_pointer() → synchronize_rcu() → 释放旧数据
Grace Period：所有读者退出后才释放旧数据
```

### 内存屏障

```c
barrier()           // 编译器屏障
smp_mb()            // 全屏障
smp_rmb() / smp_wmb()  // 读/写屏障

// 典型：生产者-消费者
// 生产者                 消费者
buf[idx] = data;        if (flag) {
smp_wmb();                  smp_rmb();
flag = 1;                   use(buf[idx]);
                        }
```

---

## 五、内存管理

| API | 特点 | 场景 |
|-----|------|------|
| kmalloc | 物理连续 | 小内存、DMA |
| vmalloc | 虚拟连续 | 大内存 |
| dma_alloc_coherent | 一致性DMA | 设备共享 |
| devm_xxx | 设备生命周期 | 驱动中优先 |

### ioremap vs mmap

```
ioremap：内核中映射设备物理地址，配合 readl/writel
mmap：用户空间映射，驱动实现 fops->mmap，调用 remap_pfn_range()
```

---

## 六、调试工具

### ftrace

```bash
cd /sys/kernel/debug/tracing
echo function_graph > current_tracer
echo my_driver_* > set_ftrace_filter
echo 1 > tracing_on
# ... 操作 ...
echo 0 > tracing_on && cat trace

# 事件追踪
echo 1 > events/irq/irq_handler_entry/enable
echo 1 > events/sched/sched_switch/enable
```

### perf

```bash
perf top                          # 实时热点
perf record -g -a -- sleep 10     # 采样
perf report                       # 分析

# 火焰图
perf script > out.txt
stackcollapse-perf.pl out.txt | flamegraph.pl > flame.svg

# 特定事件
perf stat -e cache-misses,instructions,cycles ./program
perf record -e irq:irq_handler_entry -a -- sleep 5
```

### crash（内核崩溃分析）

```bash
crash vmlinux /var/crash/vmcore

crash> bt           # 调用栈
crash> bt -a        # 所有CPU调用栈
crash> log          # dmesg
crash> ps -l        # D状态进程
crash> struct task_struct <addr>
crash> dis <func>   # 反汇编
crash> vm <pid>     # 内存映射
crash> irq -a       # 中断信息
crash> kmem -s      # slab信息

# 分析流程：bt看panic点 → dis确认指令 → struct看数据 → log看上下文
```

### BCC/eBPF

```bash
# 函数延迟
funclatency i2c_transfer

# IO 分析
biolatency          # IO延迟直方图
biosnoop            # 每次IO详情

# 中断分析
hardirqs            # 硬中断时间统计
softirqs            # 软中断统计

# 调度分析
runqlat             # 运行队列延迟
cpudist             # CPU使用分布

# 内存
memleak             # 内存泄漏

# 自定义
bpftrace -e 'kprobe:do_sys_open { printf("%s %s\n", comm, str(arg1)); }'
bpftrace -e 'tracepoint:irq:irq_handler_entry { @[args->name] = count(); }'
```

### 其他工具

```bash
devmem 0x10000000 32 0x01    # 寄存器读写
i2cdetect -y 0               # I2C扫描
i2cget -y 0 0x48 0x00        # I2C读
cat /proc/interrupts          # 中断计数
cat /proc/softirqs            # 软中断统计
```

### 工具选择速查

| 问题类型 | 推荐工具 |
|----------|----------|
| 内核崩溃 | crash + vmcore |
| CPU热点 | perf top + flamegraph |
| 函数追踪 | ftrace function_graph |
| 延迟分析 | BCC runqlat / perf sched |
| IO性能 | BCC biolatency |
| 内存泄漏 | kmemleak / BCC memleak |
| 中断问题 | /proc/interrupts + BCC hardirqs |
| 锁竞争 | perf lock / lockdep |

---

## 七、设备驱动

### Platform 驱动匹配

```
DTS compatible → of_match_table 匹配 → probe() 调用
```

### 字符设备完整流程

```c
// insmod → module_init → alloc_chrdev_region → cdev_add → device_create
// 用户 open("/dev/xxx") → VFS → inode → cdev → fops → drv_open
```

### 设备树解析 API

```c
base = devm_platform_ioremap_resource(pdev, 0);
irq = platform_get_irq(pdev, 0);
of_property_read_u32(dev->of_node, "clock-frequency", &val);
gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
clk = devm_clk_get(dev, NULL);
```

---

## 八、链表算法（字节高频）

### 反转链表

```c
struct ListNode* reverseList(struct ListNode* head) {
    struct ListNode *temp = NULL, *curr = head;
    while (curr) {
        struct ListNode *next = curr->next;
        curr->next = temp;
        temp = curr;
        curr = next;
    }
    return temp;
}
```

### K 个一组翻转（字节最爱）

```c
struct ListNode* reverseKGroup(struct ListNode* head, int k) {
    struct ListNode *cur = head;
    int count = 0;
    while (cur && count < k) { cur = cur->next; count++; }
    if (count < k) return head;
    struct ListNode *temp = reverseKGroup(cur, k);
    while (count--) {
        struct ListNode *next = head->next;
        head->next = temp;
        temp = head;
        head = next;
    }
    return temp;
}
```

### 环形链表找入环点

```c
struct ListNode* detectCycle(struct ListNode* head) {
    struct ListNode *slow = head, *fast = head;
    while (fast && fast->next) {
        slow = slow->next;
        fast = fast->next->next;
        if (slow == fast) {
            struct ListNode *p = head;
            while (p != slow) { p = p->next; slow = slow->next; }
            return p;
        }
    }
    return NULL;
}
```

### 合并K个有序链表（分治）

```c
struct ListNode* mergeTwoLists(struct ListNode* l1, struct ListNode* l2) {
    struct ListNode dummy = {0}, *tail = &dummy;
    while (l1 && l2) {
        if (l1->val <= l2->val) { tail->next = l1; l1 = l1->next; }
        else { tail->next = l2; l2 = l2->next; }
        tail = tail->next;
    }
    tail->next = l1 ? l1 : l2;
    return dummy.next;
}
```

---

## 九、字符串算法

### 最长无重复字符子串（字节必考）

```c
int lengthOfLongestSubstring(char *s) {
    int map[128] = {0}, res = 0, left = 0;
    for (int i = 0; s[i]; i++) {
        if (map[(int)s[i]] > left) left = map[(int)s[i]];
        map[(int)s[i]] = i + 1;
        int len = i - left + 1;
        if (len > res) res = len;
    }
    return res;
}
```

### 最长回文子串

```c
int expand(char *s, int l, int r, int n) {
    while (l >= 0 && r < n && s[l] == s[r]) { l--; r++; }
    return r - l - 1;
}
char* longestPalindrome(char *s) {
    int n = strlen(s), start = 0, maxlen = 0;
    for (int i = 0; i < n; i++) {
        int len1 = expand(s, i, i, n);
        int len2 = expand(s, i, i + 1, n);
        int len = len1 > len2 ? len1 : len2;
        if (len > maxlen) { maxlen = len; start = i - (len - 1) / 2; }
    }
    s[start + maxlen] = '\0';
    return s + start;
}
```

### KMP 匹配

```c
void buildNext(const char *p, int *next, int m) {
    next[0] = -1;
    int i = 0, j = -1;
    while (i < m - 1) {
        if (j == -1 || p[i] == p[j]) { i++; j++; next[i] = j; }
        else j = next[j];
    }
}
int kmp(const char *s, const char *p) {
    int n = strlen(s), m = strlen(p);
    int next[m];
    buildNext(p, next, m);
    int i = 0, j = 0;
    while (i < n && j < m) {
        if (j == -1 || s[i] == p[j]) { i++; j++; }
        else j = next[j];
    }
    return j == m ? i - m : -1;
}
```

---

## 十、二叉树

### 层序遍历

```c
void levelOrder(struct TreeNode *root) {
    if (!root) return;
    struct TreeNode *queue[10000];
    int front = 0, rear = 0;
    queue[rear++] = root;
    while (front < rear) {
        int size = rear - front;
        for (int i = 0; i < size; i++) {
            struct TreeNode *node = queue[front++];
            if (node->left) queue[rear++] = node->left;
            if (node->right) queue[rear++] = node->right;
        }
    }
}
```

### 最近公共祖先

```c
struct TreeNode* lowestCommonAncestor(struct TreeNode* root,
                                      struct TreeNode* p, struct TreeNode* q) {
    if (!root || root == p || root == q) return root;
    struct TreeNode *left = lowestCommonAncestor(root->left, p, q);
    struct TreeNode *right = lowestCommonAncestor(root->right, p, q);
    if (left && right) return root;
    return left ? left : right;
}
```

---

## 十一、排序与DP

### 快速排序

```c
void quicksort(int *a, int lo, int hi) {
    if (lo >= hi) return;
    int pivot = a[lo], l = lo, r = hi;
    while (l < r) {
        while (l < r && a[r] >= pivot) r--;
        a[l] = a[r];
        while (l < r && a[l] <= pivot) l++;
        a[r] = a[l];
    }
    a[l] = pivot;
    quicksort(a, lo, l - 1);
    quicksort(a, l + 1, hi);
}
```

### 编辑距离

```c
int minDistance(char *s1, char *s2) {
    int m = strlen(s1), n = strlen(s2);
    int dp[m + 1][n + 1];
    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;
    for (int i = 1; i <= m; i++)
        for (int j = 1; j <= n; j++) {
            if (s1[i-1] == s2[j-1]) dp[i][j] = dp[i-1][j-1];
            else {
                int a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1];
                dp[i][j] = (a < b ? (a < c ? a : c) : (b < c ? b : c)) + 1;
            }
        }
    return dp[m][n];
}
```

### 接雨水

```c
int trap(int *h, int n) {
    int l = 0, r = n - 1, lmax = 0, rmax = 0, res = 0;
    while (l < r) {
        if (h[l] < h[r]) {
            if (h[l] >= lmax) lmax = h[l]; else res += lmax - h[l];
            l++;
        } else {
            if (h[r] >= rmax) rmax = h[r]; else res += rmax - h[r];
            r--;
        }
    }
    return res;
}
```

### LRU 缓存（字节必考）

```
实现：双向链表 + 哈希表
- get(key): 哈希查找，命中则移到链表头部
- put(key,val): 命中则更新+移头; 未命中则新建插头，满则删尾
```

---

## 十二、面试 Top 问答

1. 从上电到 shell 的完整启动流程？
2. 中断上半部和下半部区别？什么时候用 workqueue vs threaded_irq？
3. spinlock 和 mutex 区别？中断中能用哪个？
4. DMA 时如何保证 cache 一致性？
5. 设备树如何匹配到驱动？
6. 如何分析内核 panic？（crash 工具使用）
7. softirq 和 tasklet 区别？ksoftirqd 是什么？
8. RCU 原理？什么场景用？
9. 如何用 perf 定位性能瓶颈？
10. eBPF/BCC 能做什么？和 ftrace 对比？
11. ioremap 和 mmap 区别？
12. 内存屏障什么时候需要？
13. kmalloc vs vmalloc？
14. 如何调试驱动加载后设备不工作？
15. 如何定位软中断占 CPU 过高的问题？

---

## 十三、内存使用过高排查

### 快速三板斧

```bash
free -h                                               # 全局概览
ps aux --sort=-%mem | head -10                        # 哪个进程吃的
cat /proc/meminfo | grep -E "MemAvailable|AnonPages|Slab|Shmem|SUnreclaim|SwapFree"
```

### /proc/meminfo 关键字段

| 字段 | 含义 | 高了说明什么 |
|------|------|-------------|
| MemAvailable | **实际可用**（含可回收 cache） | 这个低才是真紧张 |
| AnonPages | 匿名页（堆栈） | 进程吃内存 |
| Slab / SUnreclaim | 内核对象缓存 | 内核内存泄漏 |
| Shmem | tmpfs + 共享内存 | 查 /dev/shm |
| Buffers + Cached | 文件缓存（可回收） | 高是正常的 |

### 进程级排查

```bash
# 按 RSS 排序
ps -eo pid,user,rss,vsize,comm --sort=-rss | head -20

# 单进程详细
cat /proc/<pid>/smaps_rollup    # Rss/Pss/Anonymous/Swap
pmap -x <pid> | tail -5

# 监控是否持续增长（判断泄漏）
watch -n 5 "ps -o pid,rss,comm -p <pid>"
```

### 内核内存排查

```bash
# Slab 消耗
slabtop -o -s c | head -20

# vmalloc 区域
cat /proc/vmallocinfo | awk '{sum+=$2} END {print sum/1024/1024 " MB"}'

# kmemleak（需 CONFIG_DEBUG_KMEMLEAK=y）
echo scan > /sys/kernel/debug/kmemleak
cat /sys/kernel/debug/kmemleak
```

### tmpfs / 共享内存

```bash
grep Shmem /proc/meminfo
df -h | grep tmpfs
du -sh /dev/shm/*
```

### 排查流程

```
内存紧张？
├─ free -h 看 available
│    └─ buff/cache 高但 available 正常 → 没问题
├─ ps --sort=-%mem → 哪个进程？
│    ├─ RSS 巨大且持续增长 → 用户态泄漏（valgrind）
│    └─ 进程加起来对不上 → 内核占的
├─ /proc/meminfo 看 Slab / Shmem / AnonPages
│    ├─ Slab(SUnreclaim) 高 → slabtop / kmemleak
│    ├─ Shmem 高 → tmpfs + /dev/shm
│    └─ AnonPages 高 → 进程堆内存
└─ OOM 已发生 → dmesg | grep -i "oom\|killed"
```

### OOM 相关

```bash
# 查看 OOM 日志
dmesg | grep -i "oom\|killed\|out of memory" -A 20

# 保护关键进程不被 OOM Killer 杀
echo -1000 > /proc/<pid>/oom_score_adj
```

---

## 十三、文件系统裁剪

### 裁剪思路

核心原则：只保留系统运行所必需的文件，删除一切不需要的。

### 可裁剪目录

| 目录 | 可裁剪内容 | 说明 |
|------|-----------|------|
| `/usr/share` | man、doc、locale、info、zoneinfo | 文档/本地化 |
| `/usr/include` | 所有头文件 | 运行时不需要 |
| `/usr/lib` | 静态库 `*.a`、不用的 `.so` | 只保留运行时动态库 |
| `/lib/modules` | 不用的内核模块 | 只留需要的驱动 |
| `/var/cache` | 包管理器缓存 | 清空 |

### 常用裁剪操作

```bash
# 删除文档
rm -rf /target/usr/share/{man,doc,info}

# 只保留需要的 locale
cd /target/usr/share/locale && ls | grep -v "en_US" | xargs rm -rf

# 删除头文件和静态库
rm -rf /target/usr/include
find /target -name "*.a" -delete

# strip 二进制和动态库（去调试符号）
find /target -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null
find /target -name "*.so*" -exec strip --strip-unneeded {} \; 2>/dev/null
```

### BusyBox 替换工具链

```bash
# 一个 ~1MB 的 busybox 替代上百个命令
busybox --install -s /target/bin
```

### 依赖分析法（最小 rootfs）

```bash
# 分析程序依赖的共享库
ldd /target/usr/bin/my_app

# 只复制需要的到新 rootfs
mkdir -p /newroot/{bin,lib,etc,dev,proc,sys,tmp}
cp /target/usr/bin/my_app /newroot/bin/
# 复制 ldd 列出的所有 .so
```

### 构建工具自动裁剪

| 工具 | 适用场景 |
|------|---------|
| Buildroot | 嵌入式，从源码构建精简 rootfs |
| Yocto/OE | 嵌入式，高度可定制 |
| Alpine Linux | 容器/轻量系统，基于 musl + busybox |

### 裁剪效果参考

| 方案 | rootfs 大小 |
|------|------------|
| 完整 Ubuntu | ~1-2 GB |
| Alpine Linux | ~5 MB |
| BusyBox + musl 手动构建 | ~1-3 MB |

### 注意事项

```
- strip 前备份原始文件
- ldd 确认没有漏掉动态库依赖
- 注意 NSS 模块（libnss_*.so），ldd 不一定列全
- 裁剪后必须实际启动测试
```

---

*BSP 岗算法一般不超过 LeetCode Medium，但 C 实现和指针操作是加分项。内核知识占面试 60-70%，算法占 20-30%。*


---

## 十二、系统从上电到 Shell 的完整启动流程

### 全景图

```
上电
 │
 ▼
┌─────────────────────────────────────────────────┐
│ 1. ROM Code (BootROM)                           │
│    - 芯片内固化代码，不可修改                      │
│    - 初始化最基本硬件（CPU 时钟、基本 IO）          │
│    - 根据 boot pin/fuse 决定从哪里加载下一级       │
│      (eMMC / SD / NAND / SPI NOR / USB)          │
│    - 加载 SPL/TPL 到内部 SRAM（DDR 还没初始化）    │
│    - 跳转到 SPL                                  │
└─────────────────────┬───────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────┐
│ 2. SPL (Secondary Program Loader)               │
│    - 运行在 SRAM 中（几十~几百 KB）               │
│    - 初始化 DDR 控制器 → DDR 可用                 │
│    - 初始化基本时钟树                              │
│    - 从存储加载完整 U-Boot 到 DDR                  │
│    - 跳转到 U-Boot                               │
└─────────────────────┬───────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────┐
│ 3. U-Boot (完整 Bootloader)                     │
│    - 运行在 DDR 中                               │
│    - 初始化更多外设（网络、USB、显示、存储）         │
│    - 提供命令行环境（可交互调试）                   │
│    - 从存储/网络加载：                             │
│      • kernel image (Image/zImage)               │
│      • DTB (设备树)                              │
│      • initramfs（可选）                          │
│    - 设置 bootargs（内核命令行参数）               │
│    - 跳转到 kernel 入口                          │
└─────────────────────┬───────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────┐
│ 4. Kernel 启动                                   │
│                                                 │
│ 4.1 汇编阶段 (head.S)                            │
│    - 设置 MMU 页表、使能 MMU                      │
│    - 设置异常向量表                               │
│    - 跳转到 start_kernel()                       │
│                                                 │
│ 4.2 start_kernel()                              │
│    - setup_arch(): 解析 DTB、初始化内存布局        │
│    - mm_init(): 伙伴系统、slab 初始化             │
│    - sched_init(): 调度器初始化                   │
│    - init_IRQ(): 中断控制器初始化                  │
│    - time_init(): 定时器初始化                    │
│    - rest_init(): 创建 init 和 kthreadd 线程     │
│                                                 │
│ 4.3 kernel_init (PID=1)                         │
│    - 设备驱动初始化（按 initcall 级别依次调用）     │
│    - 挂载 rootfs                                 │
│      • initramfs → 或直接 mount root 分区        │
│    - 执行 /sbin/init（或 systemd）               │
└─────────────────────┬───────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────┐
│ 5. Init 进程 (systemd / busybox init)           │
│    - PID 1，所有用户进程的祖先                    │
│    - 挂载文件系统 (/proc, /sys, /dev)            │
│    - 启动系统服务（网络、日志、udev 等）           │
│    - 启动 getty → login → shell                  │
└─────────────────────┬───────────────────────────┘
                      ▼
              用户拿到 Shell
```

### 各阶段运行位置

| 阶段 | 运行在哪 | 为什么 |
|------|----------|--------|
| ROM Code | 芯片内 ROM | 固化不可改 |
| SPL | 内部 SRAM | DDR 还没初始化 |
| U-Boot | DDR | SPL 已初始化 DDR |
| Kernel | DDR | 虚拟地址空间 |
| Init/Shell | DDR | 用户空间 |

### 面试常见追问

**Q: 为什么需要 SPL，不能直接加载 U-Boot？**
> ROM Code 只能访问内部 SRAM（几十~几百 KB），完整 U-Boot 太大放不下。SPL 是精简版 bootloader，只做 DDR 初始化 + 加载完整 U-Boot。

**Q: kernel 怎么知道设备树在哪？**
> U-Boot 把 dtb 加载到 DDR 某地址，通过寄存器（ARM64 是 x0）把 dtb 地址传给 kernel 入口。

**Q: initramfs 是什么？为什么需要它？**
> 临时的内存根文件系统。kernel 需要先挂载 rootfs 才能执行 init，但挂载真正的 root 分区可能需要驱动（如 NVMe、LVM、加密）。initramfs 里有这些驱动和工具，帮 kernel 过渡到真正的 rootfs。

**Q: initcall 有哪些级别？**
```c
#define pure_initcall(fn)       // 0 - 最早
#define core_initcall(fn)       // 1
#define postcore_initcall(fn)   // 2
#define arch_initcall(fn)       // 3
#define subsys_initcall(fn)     // 4
#define fs_initcall(fn)         // 5
#define device_initcall(fn)     // 6 - module_init 默认级别
#define late_initcall(fn)       // 7 - 最晚
```

**Q: 如果系统卡在启动过程中，怎么定位卡在哪一步？**
> - U-Boot 阶段：打开 `CONFIG_BOOTSTAGE`，或加 `initcall_debug` 给 bootargs
> - Kernel 阶段：bootargs 加 `initcall_debug`，dmesg 会打印每个 initcall 的函数名和耗时
> - Init 阶段：看 systemd journal 或 `/var/log/boot.log`

### 时间参考（典型嵌入式 ARM）

| 阶段 | 耗时 |
|------|------|
| ROM → SPL | ~100ms |
| SPL（含 DDR 初始化） | ~200ms |
| U-Boot | ~1-3s |
| Kernel 到挂载 rootfs | ~2-5s |
| Init 到 Shell | ~1-10s（取决于服务多少） |

### 一句话总结

```
ROM → SPL(初始化DDR) → U-Boot(加载kernel+dtb) → Kernel(初始化子系统+挂载rootfs) → Init → Shell
```
