---
layout: default
title: "Latest Posts"
description: "Xiaolei Wang's blog about Linux kernel development, graphics programming, and embedded systems"
---

<article>
<header>
<h1>Xiaolei's Blog</h1>
<p><em>Linux kernel development & embedded systems</em></p>
</header>

<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 1.5rem; margin-top: 2rem;">

<a href="/category/camera-media/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">📷 Camera / Media</h2>
<p>Camera sensor, ISP, VPU, DRM, MIPI CSI-2, Linux Media 子系统</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'camera-media/'" | size }} 篇文章</p>
</div>
</a>

<a href="/category/system-internals/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">⚙️ System Internals</h2>
<p>调度器、内存管理、中断、softirq、kdump、设备模型</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'system-internals/'" | size }} 篇文章</p>
</div>
</a>

<a href="/category/drm-gpu/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">🖥️ DRM / GPU</h2>
<p>DRM/KMS 显示流水线、GEM 内存管理、GPU Scheduler、DMA-fence</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'drm-gpu/'" | size }} 篇文章</p>
</div>
</a>

<a href="/category/arm-architecture/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">🏗️ ARM Architecture</h2>
<p>ARMv8-A, AArch64 内存管理, Cortex-A55/A72 TRM</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'arm-architecture/'" | size }} 篇文章</p>
</div>
</a>

<a href="/category/memory-subsystem/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">🧠 内存子系统</h2>
<p>物理内存、虚拟内存、伙伴系统、SLUB、mmap、vmalloc</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'memory-subsystem/'" | size }} 篇文章</p>
</div>
</a>

<a href="/category/networking/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">🌐 网络子系统</h2>
<p>TSN 时间敏感网络、CBS/TAPRIO/ETF 调度、帧抢占、PTP 时钟</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'networking/'" | size }} 篇文章</p>
</div>
</a>

<a href="/category/interview/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">📝 Interview</h2>
<p>BSP/内核开发面试题、算法题</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'interview/'" | size }} 篇文章</p>
</div>
</a>

</div>
</article>
