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

<a href="/category/arm-architecture/" style="text-decoration: none; color: inherit;">
<div style="border: 1px solid #444; border-radius: 8px; padding: 1.5rem; transition: transform 0.2s;">
<h2 style="margin-top: 0;">🏗️ ARM Architecture</h2>
<p>ARMv8-A, AArch64 内存管理, Cortex-A55/A72 TRM</p>
<p style="opacity: 0.6;">{{ site.posts | where_exp: "p", "p.path contains 'arm-architecture/'" | size }} 篇文章</p>
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
