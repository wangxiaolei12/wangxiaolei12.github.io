---
layout: default
title: "📝 Interview"
permalink: /category/interview/
---

<article>
<header>
<h1>📝 Interview (面试题)</h1>
<p><a href="/">← 返回首页</a></p>
</header>

{% assign posts = site.posts | where_exp: "p", "p.path contains 'interview/'" %}
{% for post in posts %}
<article style="margin-bottom: 1.5rem; padding-bottom: 1rem; border-bottom: 1px solid #333;">
<h2><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h2>
<p><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time></p>
{% if post.excerpt %}<p style="opacity: 0.8;">{{ post.excerpt | strip_html | truncatewords: 40 }}</p>{% endif %}
</article>
{% endfor %}

</article>
