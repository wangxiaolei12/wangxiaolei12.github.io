---
layout: default
title: "Latest Posts"
description: "Xiaolei Wang's blog about Linux kernel development, graphics programming, and embedded systems"
---

<article>
<header>
<h1>Latest Posts</h1>
<p><em>I write about Linux kernel development and graphics programming</em></p>
</header>

<p><a href="/atom.xml" class="feed">Feed</a></p>

<h2>📷 Camera / Linux Media / VPU</h2>
{% for post in site.posts %}
{% if post.path contains 'camera-media/' %}
<article>
<header>
<h3><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h3>
</header>
<p><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time></p>
</article>
{% endif %}
{% endfor %}

<h2>⚙️ System Internals (内核系统分析)</h2>
{% for post in site.posts %}
{% if post.path contains 'system-internals/' %}
<article>
<header>
<h3><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h3>
</header>
<p><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time></p>
</article>
{% endif %}
{% endfor %}

<h2>🏗️ ARM Architecture</h2>
{% for post in site.posts %}
{% if post.path contains 'arm-architecture/' %}
<article>
<header>
<h3><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h3>
</header>
<p><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time></p>
</article>
{% endif %}
{% endfor %}

<h2>📝 Interview (面试题)</h2>
{% for post in site.posts %}
{% if post.path contains 'interview/' %}
<article>
<header>
<h3><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h3>
</header>
<p><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time></p>
</article>
{% endif %}
{% endfor %}

</article>
