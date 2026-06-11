---
layout: post
title: "Linux Kdump 完整流程分析：从 Panic 到 Dump 收集"
date: 2026-06-11 11:30:00 +0800
excerpt: "深入分析 Linux 内核 kdump 机制的完整流程，涵盖 crash kernel 加载、panic 触发路径、machine_kexec 跳转、以及第二内核 vmcore 收集。具体到每个函数调用链，基于最新 mainline 源码。"
---


基于 `/buildarea/raid0/xwang/mainline/linux/` 源码（最新 mainline）

---

## 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        KDUMP 完整生命周期                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐     ┌──────────────┐     ┌─────────────────────────────┐  │
│  │  Phase 1    │     │   Phase 2    │     │         Phase 3             │  │
│  │  加载阶段    │────▶│   触发阶段    │────▶│     Dump 收集阶段           │  │
│  │ (用户空间)   │     │ (内核 panic) │     │  (第二内核启动后)            │  │
│  └─────────────┘     └──────────────┘     └─────────────────────────────┘  │
│                                                                             │
│  kexec -p vmlinuz    panic()/oops        /proc/vmcore → makedumpfile       │
│  ──────────────      ────────────        ──────────────────────────        │
│  加载 crash kernel   触发 kdump          读取 crash dump                    │
│  到预留内存          跳转到 crash kernel  保存到磁盘                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Crash Kernel 加载流程

```
用户空间                          内核空间
─────────                        ─────────

kexec -p /boot/vmlinuz            
  │                               
  ├─ kexec_load() syscall ───────▶ SYSCALL_DEFINE4(kexec_load)
  │  (flags: KEXEC_ON_CRASH)          │ kernel/kexec.c
  │                                   │
  │  或                               ▼
  │                              kexec_load_check()
  ├─ kexec_file_load() ─────────▶    │ 权限/安全检查
  │  syscall                          │
  │                                   ▼
  │                              do_kexec_load()
  │                                   │
  │                                   ├──▶ dest_image = &kexec_crash_image
  │                                   │
  │                                   ▼
  │                              kimage_alloc_init()
  │                                   │
  │                                   ├── 验证 entry 在 crashk_res 范围内
  │                                   ├── image->type = KEXEC_TYPE_CRASH
  │                                   ├── image->control_page = crashk_res.start
  │                                   ├── sanity_check_segment_list()
  │                                   └── kimage_alloc_control_pages()
  │                                   │
  │                                   ▼
  │                              machine_kexec_prepare(image)
  │                                   │  arch/x86/kernel/machine_kexec_64.c
  │                                   ├── 复制 relocate_kernel 到 control page
  │                                   └── 设置 page table
  │                                   │
  │                                   ▼
  │                              kimage_crash_copy_vmcoreinfo()
  │                                   │  kernel/crash_core.c
  │                                   └── 分配 vmcoreinfo 安全副本
  │                                   │
  │                                   ▼
  │                              kimage_load_segment() × N
  │                                   │  将 crash kernel 段加载到预留内存
  │                                   │
  │                                   ▼
  │                              kimage_terminate()
  │                                   │
  │                                   ▼
  │                              machine_kexec_post_load()
  │                                   │
  │                                   ▼
  │                              xchg(&kexec_crash_image, image)
  │                                   │  安装 crash image
  │                                   ▼
  │                              arch_kexec_protect_crashkres()
  │                                   └── 将 crash 预留内存设为只读保护
  │
  └── 返回成功
```

### 关键数据结构

```c
// include/linux/kexec.h
struct kimage {
    unsigned long    start;           // crash kernel 入口地址
    struct list_head control_pages;   // 控制页面链表
    struct page     *control_code_page; // 包含 relocate_kernel 代码
    unsigned long    nr_segments;     // 段数量
    struct kexec_segment segment[KEXEC_SEGMENT_MAX]; // 段列表
    struct list_head dest_pages;      // 目标页面
    unsigned long    head;            // 页面拷贝链表头 (indirection page)
    void            *vmcoreinfo_data_copy;  // vmcoreinfo 安全副本
    int              type;            // KEXEC_TYPE_CRASH
    ...
};
```

---

## Phase 2: Crash 触发流程

### 触发路径总览

```
                    ┌────────────────────┐
                    │  触发源 (Trigger)   │
                    └────────┬───────────┘
                             │
            ┌────────────────┼────────────────┐
            │                │                │
            ▼                ▼                ▼
     ┌──────────┐    ┌──────────┐    ┌───────────────┐
     │  panic() │    │  oops    │    │ sysrq-c       │
     │          │    │ (die())  │    │ NMI watchdog   │
     └────┬─────┘    └────┬─────┘    └───────┬───────┘
          │               │                   │
          │               ▼                   │
          │        oops_end()                 │
          │          │                        │
          │          ├─ kexec_should_crash()   │
          │          │  检查是否应该 crash     │
          │          │                        │
          │          ▼                        │
          │     crash_kexec(regs)  ◀──────────┘
          │          │
          │          ├─ panic_try_start()
          │          │  atomic cmpxchg panic_cpu
          │          │  确保只有一个 CPU 执行
          │          │
          │          ▼
          │     __crash_kexec(regs)
          │          │
          ▼          ▼
     vpanic()        │
       │             │
       ├─ if (!crash_kexec_post_notifiers)
       │      __crash_kexec(NULL)  ─────────┐
       │                                    │
       ├─ panic_other_cpus_shutdown()       │
       ├─ atomic_notifier_call_chain()      │
       ├─ kmsg_dump()                       │
       │                                    │
       ├─ if (crash_kexec_post_notifiers)   │
       │      __crash_kexec(NULL)  ─────────┤
       │                                    │
       └────────────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │  __crash_kexec()    │
              │  kernel/crash_core.c│
              └────────┬────────────┘
                       │
                       ▼
```

### `__crash_kexec()` 详细流程

```
__crash_kexec(struct pt_regs *regs)     [kernel/crash_core.c]
    │
    ├── kexec_trylock()                  // 获取锁，防止并发
    │
    ├── if (!kexec_crash_image) return   // 没有加载 crash kernel 则返回
    │
    ├── crash_setup_regs(&fixed_regs, regs)  // 保存当前 CPU 寄存器
    │       │
    │       └── 如果 regs==NULL (从panic来), 用当前上下文
    │
    ├── crash_save_vmcoreinfo()          // 更新 vmcoreinfo note
    │       │
    │       └── 写入内核版本、符号表偏移、内存布局等
    │
    ├── machine_crash_shutdown(&fixed_regs)
    │       │  arch/x86/kernel/crash.c → native_machine_crash_shutdown()
    │       │
    │       ├── local_irq_disable()       // 关中断
    │       │
    │       ├── crash_smp_send_stop()     // 停止其他 CPU
    │       │       │
    │       │       └── kdump_nmi_shootdown_cpus()
    │       │               │
    │       │               ├── nmi_shootdown_cpus(kdump_nmi_callback)
    │       │               │       发送 NMI 到所有其他 CPU
    │       │               │
    │       │               └── kdump_nmi_callback(cpu, regs):
    │       │                       ├── crash_save_cpu(regs, cpu)
    │       │                       │     保存该 CPU 的寄存器到 ELF note
    │       │                       ├── cpu_emergency_stop_pt()
    │       │                       ├── kdump_sev_callback()
    │       │                       └── disable_local_APIC()
    │       │
    │       ├── cpu_emergency_stop_pt()   // 停止 Intel PT
    │       │
    │       ├── clear_IO_APIC()           // 清除 I/O APIC
    │       ├── lapic_shutdown()          // 关闭 LAPIC
    │       ├── restore_boot_irq_mode()   // 恢复启动时中断模式
    │       ├── hpet_disable()            // 关闭 HPET
    │       │
    │       ├── enc_kexec_begin/finish()  // SEV/TDX 加密处理
    │       │
    │       └── crash_save_cpu(regs, this_cpu)  // 保存当前 CPU 寄存器
    │
    ├── crash_cma_clear_pending_dma()     // 等待 CMA DMA 完成 (10s timeout)
    │
    └── machine_kexec(kexec_crash_image)  // 跳转！不再返回
            │  arch/x86/kernel/machine_kexec_64.c
            │
            ▼
```

### `machine_kexec()` - 最终跳转

```
machine_kexec(struct kimage *image)
    │
    ├── local_irq_disable()
    ├── hw_breakpoint_disable()
    ├── cet_disable()
    │
    ├── control_page = page_address(image->control_code_page)
    │     // control_page 包含 relocate_kernel 汇编代码的副本
    │
    ├── relocate_kernel_ptr = control_page +
    │     (relocate_kernel - __relocate_kernel_start)
    │
    ├── load_segments()              // 重新加载段寄存器
    │
    └── relocate_kernel_ptr(         // 调用汇编代码！
            image->head,             // indirection page (页面拷贝列表)
            pa_control_page,         // 控制页物理地址
            image->start,            // crash kernel 入口点
            flags)                   // RELOC_KERNEL_* 标志
            │
            ▼
    ┌──────────────────────────────────────────────┐
    │  relocate_kernel (汇编)                       │
    │  arch/x86/kernel/relocate_kernel_64.S        │
    │                                              │
    │  1. 保存 CPU 状态 (CR0/CR3/CR4/RSP)         │
    │  2. 设置 identity mapping page table         │
    │  3. 关闭分页 (CR0 &= ~X86_CR0_PG)          │
    │  4. 按 indirection page 列表拷贝页面         │
    │     (将 crash kernel 复制到最终位置)         │
    │  5. 跳转到 image->start                      │
    │     (crash kernel 的入口点)                  │
    └──────────────────────────────────────────────┘
            │
            ▼
    ┌──────────────────────────────────────────────┐
    │        Crash Kernel 启动                      │
    │   (在 crashk_res 预留内存中运行)             │
    └──────────────────────────────────────────────┘
```

---

## Phase 3: Crash Dump 收集

```
Crash Kernel 启动后
    │
    ├── 正常 Linux 引导流程
    │     (但内存受限于 crashkernel= 预留区域)
    │
    ├── 内核命令行包含: elfcorehdr=<addr>
    │     指向第一个内核准备的 ELF core header
    │
    ├── 内核启动时:
    │     ├── parse elfcorehdr
    │     └── 注册 /proc/vmcore
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  /proc/vmcore (fs/proc/vmcore.c)                    │
│                                                     │
│  结构: ELF Core Dump Format                         │
│  ┌─────────────────────────────────────────┐        │
│  │  ELF Header (Ehdr)                      │        │
│  ├─────────────────────────────────────────┤        │
│  │  PT_NOTE: CPU0 registers (prstatus)     │        │
│  │  PT_NOTE: CPU1 registers (prstatus)     │        │
│  │  ...                                    │        │
│  │  PT_NOTE: vmcoreinfo                    │        │
│  ├─────────────────────────────────────────┤        │
│  │  PT_LOAD: RAM range 0                   │──┐     │
│  │  PT_LOAD: RAM range 1                   │  │     │
│  │  ...                                    │  │     │
│  └─────────────────────────────────────────┘  │     │
│                                               │     │
│  数据来源: 直接读取第一个内核的物理内存        │     │
│  ◀────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  用户空间工具                                        │
│                                                     │
│  makedumpfile -l -d 31 /proc/vmcore /var/crash/dump │
│      │                                              │
│      ├── 读取 /proc/vmcore                          │
│      ├── 解析 vmcoreinfo 获取内核符号/页表信息      │
│      ├── 过滤: 排除 free pages, cache, user pages   │
│      ├── 压缩 (lzo/zstd/snappy)                    │
│      └── 写入 dumpfile                              │
│                                                     │
│  或: cp /proc/vmcore /var/crash/vmcore              │
│      (完整拷贝，不过滤)                             │
│                                                     │
│  完成后:                                            │
│      systemctl reboot / reboot                      │
└─────────────────────────────────────────────────────┘
```

---

## 关键函数调用链总结

### 加载路径 (Load Path)

```
sys_kexec_load(KEXEC_ON_CRASH)
  └── do_kexec_load()
        ├── kimage_alloc_init()
        │     ├── do_kimage_alloc_init()
        │     ├── sanity_check_segment_list()
        │     └── kimage_alloc_control_pages()
        ├── machine_kexec_prepare()         [arch]
        ├── kimage_crash_copy_vmcoreinfo()
        ├── kimage_load_segment() × N
        ├── kimage_terminate()
        ├── machine_kexec_post_load()       [arch]
        └── xchg(&kexec_crash_image, image)
```

### 触发路径 (Crash Path)

```
panic() / oops_end() / sysrq-c
  └── crash_kexec(regs)
        └── __crash_kexec(regs)
              ├── crash_setup_regs()
              ├── crash_save_vmcoreinfo()
              ├── machine_crash_shutdown()   [arch]
              │     ├── crash_smp_send_stop()
              │     │     └── nmi_shootdown_cpus(kdump_nmi_callback)
              │     │           └── crash_save_cpu() [per remote CPU]
              │     ├── clear_IO_APIC()
              │     ├── lapic_shutdown()
              │     ├── restore_boot_irq_mode()
              │     └── crash_save_cpu() [this CPU]
              └── machine_kexec(kexec_crash_image)   [arch]
                    └── relocate_kernel()    [asm]
                          └── jump to crash kernel entry
```

### Dump 收集路径 (Collection Path - 第二内核)

```
Crash kernel boot
  └── elfcorehdr_alloc() / setup
        └── vmcore_init()               [fs/proc/vmcore.c]
              ├── parse_crash_elf64_headers()
              │     ├── 读取 elfcorehdr
              │     ├── 解析 PT_NOTE → crash_notes (per-cpu regs)
              │     └── 解析 PT_LOAD → RAM ranges
              ├── pfn_is_ram_init()
              └── proc_create("vmcore", ...)
                    └── vmcore_read() / vmcore_mmap()
                          └── copy_oldmem_page() → 读取原始内存
```

---

## 内存布局

```
物理地址空间:
┌──────────────────────────────────────────────────────────┐
│  0x0000_0000                                             │
│  ┌──────────────────────────────┐                        │
│  │     Low 1M (Reserved)        │                        │
│  ├──────────────────────────────┤                        │
│  │                              │                        │
│  │     Normal System RAM        │  ◀── 第一个内核使用    │
│  │     (第一内核运行空间)        │      crash后这些内存   │
│  │                              │      被第二内核通过     │
│  │                              │      /proc/vmcore 读取 │
│  │                              │                        │
│  ├──────────────────────────────┤ ◀── crashk_res.start  │
│  │                              │                        │
│  │    Crash Kernel Reserved     │  ◀── crashkernel=256M  │
│  │    (第二内核运行空间)         │      第二内核被限制    │
│  │                              │      只能使用这块内存  │
│  │  ┌────────────────────────┐  │                        │
│  │  │ control page           │  │  relocate_kernel code  │
│  │  ├────────────────────────┤  │                        │
│  │  │ elfcorehdr             │  │  ELF headers for dump  │
│  │  ├────────────────────────┤  │                        │
│  │  │ vmcoreinfo (safe copy) │  │                        │
│  │  ├────────────────────────┤  │                        │
│  │  │ crash kernel image     │  │  vmlinuz 解压后        │
│  │  ├────────────────────────┤  │                        │
│  │  │ initrd                 │  │                        │
│  │  └────────────────────────┘  │                        │
│  │                              │                        │
│  ├──────────────────────────────┤ ◀── crashk_res.end    │
│  │                              │                        │
│  │     Normal System RAM (cont) │                        │
│  │                              │                        │
│  └──────────────────────────────┘                        │
│  0xFFFF_FFFF_FFFF                                        │
└──────────────────────────────────────────────────────────┘
```

---

## Per-CPU Crash Notes 结构

```
crash_notes (per-cpu):
┌─────────────────────────────────────────┐
│  ELF Note Header                        │
│  ├── namesz = 5 ("CORE\0")             │
│  ├── descsz = sizeof(struct elf_prstatus)│
│  └── type = NT_PRSTATUS                 │
├─────────────────────────────────────────┤
│  struct elf_prstatus                    │
│  ├── pr_pid = current->pid             │
│  └── pr_reg = {                        │
│        rax, rbx, rcx, rdx,             │
│        rsi, rdi, rbp, rsp,             │
│        r8-r15, rip, rflags,            │
│        cs, ss, fs, gs ...              │
│      }                                 │
├─────────────────────────────────────────┤
│  End-of-notes marker (0,0,0)           │
└─────────────────────────────────────────┘

由 crash_save_cpu(regs, cpu) 填充
位于: per_cpu_ptr(crash_notes, cpu)
```

---

## 源文件索引

| 文件 | 功能 |
|------|------|
| `kernel/kexec.c` | `sys_kexec_load` 系统调用入口 |
| `kernel/kexec_file.c` | `sys_kexec_file_load` 系统调用 |
| `kernel/kexec_core.c` | kimage 分配/加载/释放，`machine_kexec()` 调用 |
| `kernel/crash_core.c` | `__crash_kexec()`, `crash_kexec()`, `crash_save_cpu()`, vmcoreinfo |
| `kernel/crash_reserve.c` | crashkernel= 参数解析，内存预留 |
| `kernel/panic.c` | `vpanic()` → 调用 `__crash_kexec()` |
| `arch/x86/kernel/crash.c` | `native_machine_crash_shutdown()`, NMI shootdown |
| `arch/x86/kernel/machine_kexec_64.c` | `machine_kexec()`, `machine_kexec_prepare()` |
| `arch/x86/kernel/relocate_kernel_64.S` | 最终的页面拷贝和跳转汇编 |
| `arch/x86/kernel/dumpstack.c` | `oops_end()` → `crash_kexec()` |
| `fs/proc/vmcore.c` | 第二内核中 `/proc/vmcore` 接口 |
| `include/linux/kexec.h` | `struct kimage`, 宏定义 |
| `include/linux/crash_core.h` | crash 相关声明 |

---

## 时序图 (Panic 触发场景)

```
时间轴 ──────────────────────────────────────────────────────────────────────▶

CPU 0 (panic CPU)                    CPU 1,2,...N (其他 CPU)
─────────────────                    ────────────────────────

 NULL ptr deref!
      │
 oops_end(regs)
      │
 crash_kexec(regs)
      │
 panic_try_start()
 [设置 panic_cpu = 0]
      │
 __crash_kexec(regs)
      │
 crash_setup_regs()
 crash_save_vmcoreinfo()
      │
 machine_crash_shutdown()
      │
 ├─ local_irq_disable()
 │
 ├─ nmi_shootdown_cpus() ──────────▶  收到 NMI ──┐
 │   [发送 NMI IPI]                               │
 │                                   kdump_nmi_callback():
 │                                     crash_save_cpu()
 │                                     [保存寄存器到 note]
 │                                     disable_local_APIC()
 │                                     [CPU 停止/halt]
 │   [等待其他 CPU 响应]  ◀──────────────────────┘
 │
 ├─ clear_IO_APIC()
 ├─ lapic_shutdown()
 ├─ restore_boot_irq_mode()
 ├─ crash_save_cpu(regs, 0)
 │   [保存 CPU0 自己的寄存器]
 │
 └─ machine_kexec(kexec_crash_image)
      │
      ├─ local_irq_disable()
      ├─ load_segments()
      └─ relocate_kernel()
           │
           ├── 关闭分页
           ├── 拷贝 crash kernel 页面
           └── JMP image->start
                │
                ▼
         ╔════════════════════╗
         ║  Crash Kernel 启动 ║
         ║  (新的 Linux 内核)  ║
         ╚════════════════════╝
                │
                ├── 初始化最小硬件
                ├── 挂载 initrd
                ├── /proc/vmcore 可用
                │
                ▼
         makedumpfile → /var/crash/
                │
                ▼
            reboot
```
