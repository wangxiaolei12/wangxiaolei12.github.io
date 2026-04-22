---
layout: post
title: "Linux 系统 Suspend/Resume 的 PM 阶段详解"
date: 2026-04-22 22:40:00 +0800
excerpt: "深入分析 Linux 内核 suspend/resume 的各个阶段、runtime PM 的 disable/enable 时机，以及驱动中如何选择正确的 PM 宏。"
---

# Linux 系统 Suspend/Resume 的 PM 阶段详解

## 一、概述

Linux 内核的系统 suspend/resume 流程并不是一步完成的，而是分为多个阶段依次执行。每个阶段有不同的约束条件（中断是否可用、runtime PM 是否启用等），不同类型的驱动需要在合适的阶段完成自己的挂起和恢复操作。

本文基于内核源码 `kernel/power/suspend.c` 和 `drivers/base/power/main.c`，详细描述各阶段的执行顺序、环境约束，以及驱动开发中如何选择对应的 PM 宏。

## 二、Suspend 方向：从用户态到硬件休眠

入口函数为 `suspend_devices_and_enter()`，内部调用关系如下：

```
suspend_devices_and_enter()
  ├── dpm_suspend_start()
  │     ├── dpm_prepare()           // 阶段 1: prepare
  │     └── dpm_suspend()           // 阶段 2: suspend
  └── suspend_enter()
        ├── dpm_suspend_late()      // 阶段 3: suspend_late
        ├── dpm_suspend_noirq()     // 阶段 4: suspend_noirq
        ├── disable_secondary_cpus  // 关闭副 CPU
        ├── arch_suspend_disable_irqs // 关闭本地中断
        ├── syscore_suspend()       // 阶段 5: syscore
        └── suspend_ops->enter()    // 阶段 6: 进入硬件休眠
```

### 阶段 1 — prepare（`dpm_prepare`）

- 调用每个设备的 `.prepare()` 回调
- 目的：让设备做好 suspend 前的准备工作，比如阻止新的子设备注册
- 设备可以返回 "direct_complete" 标志，表示已处于 runtime suspended 状态，可跳过后续 suspend 回调
- **runtime PM：enabled**
- **中断：正常工作**

### 阶段 2 — suspend（`dpm_suspend`）

- 调用每个设备的 `.suspend()` 回调
- 目的：执行主要的设备挂起逻辑——保存设备状态、停止 I/O、关闭功能等
- 用户态进程此时已经被冻结（freeze）
- **runtime PM：enabled**
- **中断：正常工作**

### 阶段 3 — suspend_late（`dpm_suspend_late`）

- **在执行 late 回调之前，`pm_runtime_disable(dev)` 被调用**
- 调用每个设备的 `.suspend_late()` 回调
- 目的：完成那些需要在 runtime PM 禁用后才能做的操作
- 从这里开始，`pm_runtime_get_sync()` 等调用只改引用计数，不会真正触发硬件操作
- **runtime PM：disabled** ★
- **中断：正常工作**

### 阶段 4 — suspend_noirq（`dpm_suspend_noirq`）

- 调用每个设备的 `.suspend_noirq()` 回调
- "noirq" 的含义：非 wakeup 的中断不再被分发到设备驱动的中断处理函数
- 目的：在没有中断干扰的情况下完成最后的硬件操作（比如关闭 power domain）
- **runtime PM：disabled**
- **中断：不再分发到驱动** ★

### 阶段 5 — syscore（`syscore_suspend`）

- 关闭非 boot CPU（`pm_sleep_disable_secondary_cpus`）
- 关闭本地中断（`arch_suspend_disable_irqs`）
- 调用 syscore 级别的 suspend 回调（时钟源、中断控制器等最底层硬件）
- **只有 boot CPU 在运行，中断完全关闭**

### 阶段 6 — 进入硬件休眠

- 调用 `suspend_ops->enter(state)`，平台特定的 enter 函数
- CPU 真正进入休眠（对于 ARM 平台通常是 PSCI/ATF 调用）

## 三、Resume 方向：从硬件唤醒到用户态

完全镜像 suspend，逆序执行：

```
  CPU 被唤醒
  ├── syscore_resume()           // 阶段 5: 恢复最底层硬件，开中断，启副 CPU
  ├── dpm_resume_noirq()         // 阶段 4: noirq resume（runtime PM 仍然 disabled）
  ├── dpm_resume_early()         // 阶段 3: early resume，结束后 pm_runtime_enable()
  ├── dpm_resume()               // 阶段 2: resume（runtime PM 已 enabled）
  └── dpm_complete()             // 阶段 1: complete
```

## 四、Runtime PM 的 disable/enable 时机

这是理解整个流程的关键：

```
suspend 方向:
  dpm_prepare()        ← runtime PM enabled
  dpm_suspend()        ← runtime PM enabled
  dpm_suspend_late()   ← pm_runtime_disable(dev) 在回调执行前 ★
  dpm_suspend_noirq()  ← runtime PM disabled

  ─── 硬件休眠 ───

resume 方向:
  dpm_resume_noirq()   ← runtime PM disabled
  dpm_resume_early()   ← 回调执行后 pm_runtime_enable(dev) ★
  dpm_resume()         ← runtime PM enabled
  dpm_complete()       ← runtime PM enabled
```

源码位置（`drivers/base/power/main.c`）：

```c
// device_suspend_late() 中：
/*
 * After this point, any runtime PM operations targeting the device
 * will fail until the corresponding pm_runtime_enable() call in
 * device_resume_early().
 */
pm_runtime_disable(dev);

// device_resume_early() 中：
pm_runtime_enable(dev);
```

## 五、驱动中的 PM 宏选择

内核提供了三组宏，分别对应阶段 2、3、4：

| 宏 | 设置的回调 | 对应阶段 | runtime PM | 中断 |
|---|---|---|---|---|
| `SET_SYSTEM_SLEEP_PM_OPS` | `.suspend` / `.resume` | 阶段 2 | enabled | 正常 |
| `LATE_SYSTEM_SLEEP_PM_OPS` | `.suspend_late` / `.resume_early` | 阶段 3 | disabled | 正常 |
| `NOIRQ_SYSTEM_SLEEP_PM_OPS` | `.suspend_noirq` / `.resume_noirq` | 阶段 4 | disabled | 不分发 |

### 如何选择

**`SET_SYSTEM_SLEEP_PM_OPS` — 普通外设驱动（最常用）**

适用于 I2C、SPI、网卡、显示、USB 等大多数设备驱动。此时 runtime PM 和中断都正常工作，可以自由调用各种内核 API。

**`LATE_SYSTEM_SLEEP_PM_OPS` — 资源提供者驱动**

适用于 clock controller、regulator、pinctrl 这类为其他设备提供资源的驱动。它们需要等依赖它们的设备先 suspend 完（阶段 2），自己最后才能关闭；resume 时则需要最先恢复，让依赖它们的设备在阶段 2 resume 时资源已经就绪。

**`NOIRQ_SYSTEM_SLEEP_PM_OPS` — 最底层基础设施驱动**

适用于中断控制器（GIC、GPIO interrupt controller）、power domain controller、底层总线控制器等。这些驱动需要在中断被屏蔽后才能安全操作，且必须在所有其他设备之后才能关闭。

简单判断规则：

```
普通外设？                          → SET_SYSTEM_SLEEP_PM_OPS
为其他设备提供资源？                 → LATE_SYSTEM_SLEEP_PM_OPS
最底层基础设施（中断/电源/总线）？    → NOIRQ_SYSTEM_SLEEP_PM_OPS
```

核心原则：**越底层的驱动越晚 suspend、越早 resume**，确保上层设备操作时底层资源仍然可用。

## 六、实例分析：imx8m blk-ctrl 补丁中的问题

### 问题背景

imx8m/imx8mp 的 blk-ctrl 驱动是一个 genpd provider（power domain controller）。它的 `.power_on` / `.power_off` 回调由 genpd 框架在 noirq 阶段通过 sync 路径调用：

```
dpm_resume_noirq()
  → genpd_sync_power_on()
    → imx8m_blk_ctrl_power_on()     // genpd 的 .power_on 回调
      → pm_runtime_get_sync(bus_power_dev)  // 试图上电上游 bus domain
```

### 问题根因

在 noirq 阶段，runtime PM 已经在阶段 3（`device_suspend_late`）被 disable 了。此时 `pm_runtime_get_sync(bus_power_dev)` 只会增加引用计数，不会真正触发硬件上电。上游 bus power domain（如 mediamix、dispmix）实际上仍处于掉电状态，后续的寄存器访问会导致 bus fault。

### 为什么不能用 NOIRQ_SYSTEM_SLEEP_PM_OPS 解决

blk-ctrl 的 `.power_on` / `.power_off` 不是设备自身的 PM 回调，而是 genpd 框架的 provider 回调。这两者是完全不同的机制：

- `NOIRQ_SYSTEM_SLEEP_PM_OPS` 设置的是设备的 `.suspend_noirq` / `.resume_noirq` 回调
- genpd 的 `.power_on` / `.power_off` 是 power domain 控制器的回调，由 genpd 框架在恢复 domain 层级时自动调用

即使给 blk-ctrl 设备注册了 `NOIRQ_SYSTEM_SLEEP_PM_OPS`，也无法影响 genpd 框架调用 `.power_on` 时的行为。

### 正确的解决方案

在 `.power_on` 回调内部检测 runtime PM 是否被禁用，如果是则改用 genpd 的 sync 接口来上电上游 bus domain：

```c
/* power_on 中 */
if (!pm_runtime_enabled(bc->bus_power_dev))
    dev_pm_genpd_resume(bc->bus_power_dev);

/* power_off 中对称处理 */
if (!pm_runtime_enabled(bc->bus_power_dev))
    dev_pm_genpd_suspend(bc->bus_power_dev);
```

`dev_pm_genpd_resume()` 走的是 genpd 的 sync 路径（`genpd_switch_state`），不依赖 runtime PM，可以在 noirq 阶段正确地上电 power domain。这是在这个上下文中唯一能正确工作的方式。
