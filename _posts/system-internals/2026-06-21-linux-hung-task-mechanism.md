---
layout: post
title: "Linux 内核 Hung Task 检测机制源码分析"
date: 2026-06-21 16:00:00 +0800
excerpt: "基于 mainline 内核 kernel/hung_task.c 源码，分析 khungtaskd 内核线程如何周期性检测 D 状态进程：task_is_hung 判断逻辑、上下文切换计数原理、sysctl 可调参数、休眠场景处理及 blocker 追踪机制。"
---

# Linux 内核 Hung Task 检测机制源码分析

源码：`kernel/hung_task.c`

---

## 1. Hung Task 解决什么问题

当一个进程因为等待 I/O 完成、获取锁等原因进入 `TASK_UNINTERRUPTIBLE`（D 状态）后，如果等待的资源长时间不可用（比如 NFS 服务器宕机、磁盘故障、死锁），该进程就会永远卡住，无法被 kill，也无法响应信号。

Hung Task 检测机制的作用就是：**周期性检查系统中所有 D 状态的进程，如果某个进程超过指定时间（默认 120 秒）没有被调度过，就打印警告甚至触发 panic**，帮助开发者定位问题。

我们在 dmesg 中看到的这类告警就是它产生的：

```
INFO: task xxx:1234 blocked for more than 120 seconds.
```

---

## 2. 整体架构

```
hung_task_init()  [subsys_initcall 阶段注册]
       │
       ▼
kthread_run(watchdog, ..., "khungtaskd")   ← 创建内核线程
       │
       ▼
   watchdog() 主循环
       │
       ├──→ schedule_timeout_interruptible(interval) 周期性睡眠
       │
       └──→ check_hung_uninterruptible_tasks(timeout)
                    │
                    ├──→ for_each_process_thread()  遍历所有进程/线程
                    │         │
                    │         └──→ task_is_hung()  判断是否 hung
                    │
                    └──→ hung_task_info()  打印堆栈 / 触发 panic
```

---

## 3. 源码逐层分析

### 3.1 初始化

```c
static int __init hung_task_init(void)
{
    atomic_notifier_chain_register(&panic_notifier_list, &panic_block);
    pm_notifier(hungtask_pm_notify, 0);
    watchdog_task = kthread_run(watchdog, NULL, "khungtaskd");
    hung_task_sysctl_init();
    return 0;
}
subsys_initcall(hung_task_init);
```

- 通过 `subsys_initcall` 在内核启动早期执行
- 注册 panic 通知链：系统已经 panic 后就不再报告 hung task
- 注册 PM 通知：系统休眠时暂停检测，避免误报
- 创建 `khungtaskd` 内核线程，执行 `watchdog()` 函数

### 3.2 主循环 watchdog()

```c
static int watchdog(void *dummy)
{
    unsigned long hung_last_checked = jiffies;
    set_user_nice(current, 0);

    for ( ; ; ) {
        unsigned long timeout = sysctl_hung_task_timeout_secs;
        unsigned long interval = sysctl_hung_task_check_interval_secs;

        if (interval == 0)
            interval = timeout;
        interval = min_t(unsigned long, interval, timeout);
        t = hung_timeout_jiffies(hung_last_checked, interval);

        if (t <= 0) {
            if (!atomic_xchg(&reset_hung_task, 0) &&
                !hung_detector_suspended)
                check_hung_uninterruptible_tasks(timeout);
            hung_last_checked = jiffies;
            continue;
        }
        schedule_timeout_interruptible(t);
    }
}
```

逻辑：
1. 计算距上次检查是否已过 interval 时间
2. 如果到时间了，且没有被 reset、也没有处于 suspend 状态，就执行检测
3. 否则睡眠等待

### 3.3 核心判断：task_is_hung()

```c
static bool task_is_hung(struct task_struct *t, unsigned long timeout)
{
    unsigned long switch_count = t->nvcsw + t->nivcsw;
    unsigned int state = READ_ONCE(t->__state);

    // 1. 只检查纯 TASK_UNINTERRUPTIBLE 状态
    //    跳过 KILLABLE、IDLE、FROZEN
    if (!(state & TASK_UNINTERRUPTIBLE) ||
        (state & (TASK_WAKEKILL | TASK_NOLOAD | TASK_FROZEN)))
        return false;

    // 2. 从未被调度过的新任务，跳过
    if (unlikely(!switch_count))
        return false;

    // 3. 切换次数有变化 → 更新记录，说明任务还活着
    if (switch_count != t->last_switch_count) {
        t->last_switch_count = switch_count;
        t->last_switch_time = jiffies;
        return false;
    }

    // 4. 切换次数没变，但还没超时 → 还不算 hung
    if (time_is_after_jiffies(t->last_switch_time + timeout * HZ))
        return false;

    // 5. 超时了且上下文切换次数完全没变 → hung!
    return true;
}
```

**判断依据**：`task_struct` 中的 `nvcsw`（自愿上下文切换）+ `nivcsw`（非自愿上下文切换）的总和。如果在 timeout 时间内，这个值一直没变，说明进程一直卡着没有被调度。

### 3.4 遍历与告警

```c
static void check_hung_uninterruptible_tasks(unsigned long timeout)
{
    // 系统已经 panic 就不再检测
    if (test_taint(TAINT_DIE) || did_panic)
        return;

    rcu_read_lock();
    for_each_process_thread(g, t) {
        // 限制每轮检查数量，避免长时间占用 CPU
        if (!max_count--)
            goto unlock;

        // 周期性释放 RCU 锁，允许其他任务运行
        if (time_after(jiffies, last_break + HUNG_TASK_LOCK_BREAK)) {
            if (!rcu_lock_break(g, t))
                goto unlock;
            last_break = jiffies;
        }

        if (task_is_hung(t, timeout)) {
            atomic_long_inc(&sysctl_hung_task_detect_count);
            this_round_count++;
            hung_task_info(t, timeout, this_round_count);
        }
    }
    rcu_read_unlock();

    if (hung_task_call_panic)
        panic("hung_task: blocked tasks");
}
```

设计考量：
- 用 `rcu_read_lock` 保护进程链表遍历
- 用 `rcu_lock_break()` 定期释放锁（每 HZ/10 即 100ms），避免 RCU grace period 过长
- `max_count` 限制每轮检查的进程数量，保证不会无限占用 CPU

### 3.5 Blocker 追踪（CONFIG_DETECT_HUNG_TASK_BLOCKER）

新版内核支持打印"是谁阻塞了这个 hung task"：

```c
static void debug_show_blocker(struct task_struct *task, unsigned long timeout)
```

能识别三种锁类型的持有者：

| 锁类型 | 获取 owner 方式 |
|--------|----------------|
| mutex | `mutex_get_owner()` |
| semaphore | `sem_last_holder()` |
| rwsem | `rwsem_owner()` + 区分 reader/writer |

如果 blocker 本身没有 hung，还会打印它的堆栈，极大方便调试死锁问题。

---

## 4. 可调参数

通过 `/proc/sys/kernel/` 下的 sysctl 接口可以动态调整：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `hung_task_timeout_secs` | 120 | 超时阈值（秒），设为 0 关闭检测 |
| `hung_task_check_interval_secs` | 0（等于timeout） | 检测周期 |
| `hung_task_warnings` | 10 | 最多打印几次警告，-1 为无限 |
| `hung_task_panic` | 0 | 检测到 N 个 hung task 时触发 panic |
| `hung_task_check_count` | PID_MAX_LIMIT | 每轮最多检查多少个进程 |
| `hung_task_detect_count` | 0 | 累计检测到的 hung task 数量（可读可清零） |

常用调试命令：

```bash
# 关闭 hung task 检测
echo 0 > /proc/sys/kernel/hung_task_timeout_secs

# 检测到 hung task 就 panic（配合 kdump 抓 vmcore）
echo 1 > /proc/sys/kernel/hung_task_panic

# 设置超时为 60 秒（更快发现问题）
echo 60 > /proc/sys/kernel/hung_task_timeout_secs
```

---

## 5. 休眠场景处理

```c
static int hungtask_pm_notify(struct notifier_block *self,
                              unsigned long action, void *hcpu)
{
    switch (action) {
    case PM_SUSPEND_PREPARE:
    case PM_HIBERNATION_PREPARE:
        hung_detector_suspended = true;
        break;
    case PM_POST_SUSPEND:
    case PM_POST_HIBERNATION:
        hung_detector_suspended = false;
        break;
    }
    return NOTIFY_OK;
}
```

系统进入休眠时，所有进程都会被冻结处于 D 状态，此时是正常行为，暂停检测避免误报。

---

## 6. 总结

Hung Task 检测机制的实现精炼而完善：

| 步骤 | 实现 |
|------|------|
| 创建检测线程 | `kthread_run(watchdog, "khungtaskd")` |
| 周期性唤醒 | `schedule_timeout_interruptible(interval)` |
| 遍历进程 | `for_each_process_thread` + RCU 保护 |
| 判断是否 hung | 比较 `nvcsw + nivcsw` 是否在 timeout 内有变化 |
| 告警/panic | 打印堆栈 + 可选触发 panic |
| 边界处理 | 休眠暂停、RCU 锁分段释放、检查数量上限 |

实际应用中，配合 `hung_task_panic=1` + kdump 可以在生产环境中自动抓取死锁/IO hang 的 vmcore，是排查 D 状态问题的重要手段。
