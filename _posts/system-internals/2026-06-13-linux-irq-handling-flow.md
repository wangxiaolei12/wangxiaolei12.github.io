---
layout: post
title: "Linux 中断子系统(2): 中断处理流程 — 从硬件触发到驱动 Handler"
date: 2026-06-13 08:31:00 +0800
excerpt: "一个中断从硬件触发到驱动 handler 执行的完整路径：ARM64 异常入口→GIC 读 IAR→domain 查找→流控处理→驱动 handler→threaded IRQ。逐步骤带代码。"
---

# Linux 中断子系统(2): 中断处理流程

---

## 一、一句话概览

```
网卡拉高中断线 → GIC 通知 CPU → CPU 跳到异常入口 → 读 GIC 得到 hwirq
→ 查电话簿(domain)得到 virq → 找到 irq_desc → 调流控函数 → 调驱动 handler
→ 写 EOI 告诉 GIC "处理完了"
```

---

## 二、逐步骤详解

### 步骤 1: 硬件 → CPU

```
网卡完成收包 → 拉高 IRQ 线 → GIC 收到
    │
    ▼
GIC 内部:
  ├── 记录 INTID=72 到 pending 寄存器
  ├── 判断优先级，选择目标 CPU
  └── 向 CPU 发 IRQ 信号 (nIRQ 引脚拉低)
    │
    ▼
CPU 检测到 IRQ:
  ├── 完成当前指令
  ├── 保存 PC 到 ELR_EL1
  ├── 保存 PSTATE 到 SPSR_EL1
  ├── 跳转到 VBAR_EL1 + offset (异常向量)
```

### 步骤 2: ARM64 异常向量入口

```c
// arch/arm64/kernel/entry.S

// CPU 跳到这里 (从内核态 EL1 来的 IRQ):
el1h_64_irq:
    kernel_entry 1              // 把所有寄存器存到栈上 (pt_regs)
    call handle_arch_irq        // → gic_handle_irq (GIC 驱动注册的)
    kernel_exit 1               // 恢复寄存器，eret 返回被打断的地方
```

### 步骤 3: GIC 驱动 — 读硬件中断号

```c
// drivers/irqchip/irq-gic-v3.c
static void gic_handle_irq(struct pt_regs *regs)
{
    u32 irqnr;

    // ★ 读 ICC_IAR1_EL1 寄存器 → 拿到硬件中断号
    irqnr = gic_read_iar();  // 返回 72 (SPI 72)

    // 读 IAR 同时做了两件事:
    //   1. 告诉 GIC "我知道了"(相当于 ack)
    //   2. GIC 将此中断从 pending 变为 active

    if (irqnr > 15 && irqnr < 1020) {
        // 普通外设中断 → 去查映射
        generic_handle_domain_irq(gic_data.domain, irqnr);
    }
    else if (irqnr < 16) {
        // IPI (核间中断，0~15)
        gic_handle_ipi(irqnr, regs);
    }
    // irqnr=1023: spurious，忽略
}
```

### 步骤 4: 查电话簿 — hwirq 找到 virq

```c
// kernel/irq/irqdomain.c
int generic_handle_domain_irq(struct irq_domain *domain, irq_hw_number_t hwirq)
{
    // ★ 在 domain 的 revmap 里查找: hwirq=72 → irq_desc 是哪个？
    struct irq_desc *desc = irq_resolve_mapping(domain, hwirq);
    //   内部: return domain->revmap[72] → irq_data → irq_desc[167]

    if (!desc)
        return -EINVAL;  // 未映射的中断

    // 找到了，开始处理
    generic_handle_irq_desc(desc);
    //   内部就是: desc->handle_irq(desc);
    return 0;
}
```

### 步骤 5: 流控 handler — handle_fasteoi_irq

```c
// kernel/irq/chip.c
void handle_fasteoi_irq(struct irq_desc *desc)
{
    raw_spin_lock(&desc->lock);

    // 检查中断是否被 disable 了
    if (unlikely(irqd_irq_disabled(&desc->irq_data))) {
        mask_irq(desc);
        goto out;
    }

    // ★ 调用驱动注册的 handler(s)
    handle_irq_event(desc);

    // ★ 写 EOI 告诉 GIC "我处理完了"
    desc->irq_data.chip->irq_eoi(&desc->irq_data);
    //   → gic_eoi_irq() → 写 ICC_EOIR1_EL1 = 72
    //   → GIC 将中断从 active 变为 idle，可以再次触发

out:
    raw_spin_unlock(&desc->lock);
}
```

### 步骤 6: 调用驱动 handler

```c
// kernel/irq/handle.c
irqreturn_t handle_irq_event(struct irq_desc *desc)
{
    struct irqaction *action = desc->action;

    // ★ 遍历 action 链表，逐个调用
    for_each_action_of_desc(desc, action) {
        irqreturn_t res;

        // 调用驱动的 handler
        res = action->handler(desc->irq_data.irq, action->dev_id);
        //    例如: e1000_intr(167, netdev)

        switch (res) {
        case IRQ_HANDLED:       // "是我的中断，处理完了"
            break;
        case IRQ_WAKE_THREAD:   // "是我的，但要在线程里继续处理"
            wake_up_process(action->thread);
            break;
        case IRQ_NONE:          // "不是我的中断"(共享中断时)
            break;
        }
    }
}
```

### 步骤 7: 返回

```
handle_fasteoi_irq 返回
    → gic_handle_irq 返回
        → el1h_64_irq:
            kernel_exit:
              irq_exit()
                → 检查 softirq pending → 如有则 invoke_softirq()
              恢复 pt_regs
              eret → 回到被中断打断的地方继续执行
```

---

## 三、完整调用栈（从底到顶）

```
e1000_intr()                          ← 驱动 handler
handle_irq_event()                    ← 遍历 action 链表
handle_fasteoi_irq()                  ← 流控 (desc->handle_irq)
generic_handle_irq_desc()             ← 调 handle_irq
generic_handle_domain_irq()           ← domain revmap 查找
gic_handle_irq()                      ← 读 IAR 获取 hwirq
el1h_64_irq (entry.S)                ← ARM64 异常向量
────── 硬件 ──────
CPU 收到 IRQ 信号 (GIC → nIRQ)
GIC 收到设备中断 (SPI 72)
网卡拉高中断线
```

---

## 四、Threaded IRQ — 线程化中断

有些驱动中断处理需要睡眠（I2C/SPI 通信），不能在硬中断上下文做。用 threaded IRQ：

```c
// 驱动注册:
request_threaded_irq(irq,
    my_hardirq,     // top half: 快速判断 + 返回 IRQ_WAKE_THREAD
    my_thread_fn,   // bottom half: 在内核线程中执行，可以睡眠
    IRQF_ONESHOT,   // 处理完线程前不要 unmask
    "my_dev", dev);
```

### 执行流程

```
硬中断上下文 (不可睡眠):
  handle_fasteoi_irq()
    → my_hardirq(irq, dev) → return IRQ_WAKE_THREAD
    → wake_up_process(action->thread)  // 唤醒 "irq/167-my_dev" 线程
    → chip->irq_eoi()
    → 注意: IRQF_ONESHOT 保持中断 masked！

进程上下文 (可以睡眠):
  内核线程 "irq/167-my_dev" 被唤醒:
    → my_thread_fn(irq, dev)
        可以做: mutex_lock(), i2c_transfer(), msleep()...
    → irq_finalize_oneshot()
        → chip->irq_unmask()  // 处理完才重新使能中断
```

---

## 五、request_irq 注册过程

```c
// 驱动调用:
int irq = platform_get_irq(pdev, 0);  // 从 DT 得到 virq=167
request_irq(irq, e1000_intr, IRQF_SHARED, "eth0", netdev);
```

内部：
```c
// kernel/irq/manage.c
request_irq(irq, handler, flags, name, dev_id)
    → request_threaded_irq(irq, handler, NULL, flags, name, dev_id)
        │
        ├── desc = irq_to_desc(irq)      // 找到 irq_desc[167]
        │
        ├── action = kzalloc(irqaction)   // 创建执行人
        │     action->handler = e1000_intr
        │     action->name = "eth0"
        │     action->dev_id = netdev
        │     action->flags = IRQF_SHARED
        │
        ├── __setup_irq(irq, desc, action)
        │     ├── 如果 IRQF_SHARED: 检查已有 action 的 flags 兼容
        │     ├── 挂到 desc->action 链表尾部
        │     └── irq_startup(desc)
        │           → chip->irq_unmask()  // ★ 使能硬件中断
        │
        └── 返回 0 (成功)
```

---

## 六、中断屏蔽与使能

```c
// 驱动中临时屏蔽:
disable_irq(irq);   // desc->depth++, 如果 0→1 则 chip->irq_mask()
enable_irq(irq);    // desc->depth--, 如果 1→0 则 chip->irq_unmask()

// 嵌套安全:
disable_irq(167);   // depth: 0→1, mask 硬件
disable_irq(167);   // depth: 1→2, 不重复 mask
enable_irq(167);    // depth: 2→1, 不 unmask
enable_irq(167);    // depth: 1→0, unmask 硬件 ← 最后一次 enable 才真正打开

// 在中断 handler 中用 (不等待当前 handler 完成):
disable_irq_nosync(irq);
```

---

## 七、中断亲和性

```bash
# 查看 IRQ 167 当前在哪个 CPU 处理:
cat /proc/irq/167/smp_affinity      # 返回 cpumask, 如 "f" = CPU0-3

# 绑定到 CPU 2:
echo 4 > /proc/irq/167/smp_affinity  # 4 = bit2 = CPU2

# 内核内部:
irq_set_affinity(167, cpumask_of(2));
    → gic_set_affinity()
        → 写 GICD_IROUTER[72] = CPU2 的 affinity 值
        → GIC 后续只把 hwirq 72 送给 CPU2
```

---

## 八、时序图

```
时间 ─────────────────────────────────────────────────────────────────▶

硬件                  CPU (硬中断上下文)            内核线程
────                  ────────────────            ────────

网卡收包完成
 │ 拉 IRQ
 ▼
GIC 记录 pending
GIC → CPU IRQ
                   异常入口 (保存寄存器)
                   gic_handle_irq()
                     读 IAR → hwirq=72
                     domain revmap → desc[167]
                     handle_fasteoi_irq()
                       e1000_intr()
                         关网卡中断
                         return IRQ_WAKE_THREAD
                       wake_up(irq/167-eth0)
                       eoi(72)
                   irq_exit()
                     raise_softirq(NET_RX)
                     invoke_softirq()
                       net_rx_action()     ← softirq 中收包
                   eret (恢复被打断的代码)
                                              irq/167-eth0 醒来
                                              thread_fn()
                                                后续处理
                                              unmask → 网卡中断再次使能
```

---

## 九、源文件索引

| 文件 | 内容 |
|------|------|
| `arch/arm64/kernel/entry.S` | 异常向量表, el1h_64_irq |
| `drivers/irqchip/irq-gic-v3.c` | gic_handle_irq, gic_chip |
| `kernel/irq/irqdomain.c` | generic_handle_domain_irq, revmap |
| `kernel/irq/chip.c` | handle_fasteoi_irq, handle_level_irq |
| `kernel/irq/handle.c` | handle_irq_event, 遍历 action |
| `kernel/irq/manage.c` | request_irq, enable/disable_irq |
| `include/linux/interrupt.h` | request_irq API, IRQF_* 标志 |
