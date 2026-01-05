---
layout: default.html
title: "Latest Posts"
description: "Xiaolei Wang's blog about Linux kernel development, graphics programming, and embedded systems"
---

<article>
<header>
<h1>Latest Posts</h1>
<p><em>I write about Linux kernel development and graphics programming</em></p>
</header>

<p><a href="/atom.xml" class="feed">Feed</a></p>

{% for post in site.posts %}
<article>
<header>
<h2><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h2>
</header>
<p>
<time datetime="{{ post.date | date_to_xmlschema }}">
{{ post.date | date: "%d" }}{{ post.date | date: "%B" | slice: 0, 3 }} {{ post.date | date: "%B %Y" }}
</time>
</p>
{% if post.excerpt %}
<p>{{ post.excerpt | strip_html | truncatewords: 50 }}</p>
{% endif %}
</article>
{% endfor %}

</article>
