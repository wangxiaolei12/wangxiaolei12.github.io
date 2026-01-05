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

{% for post in site.posts %}
<article>
<header>
<h2><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h2>
</header>
<p>
<time datetime="{{ post.date | date_to_xmlschema }}">
{{ post.date | date: "%eth %B %Y" | replace: "1th", "1st" | replace: "2th", "2nd" | replace: "3th", "3rd" | replace: "21th", "21st" | replace: "22th", "22nd" | replace: "23th", "23rd" | replace: "31th", "31st" }}
</time>
</p>
{% if post.excerpt %}
<p>{{ post.excerpt | strip_html | truncatewords: 50 }}</p>
{% endif %}
</article>
{% endfor %}

</article>
