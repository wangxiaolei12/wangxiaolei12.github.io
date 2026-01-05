---
title: "Latest Posts"
description: "Xiaolei Wang's blog about Linux kernel development, graphics programming, and embedded systems"
---

{% if site.posts.size > 0 %}
  {% for post in site.posts %}
    <article>
      <header>
        <h1><a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a></h1>
        <p><time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%B %d, %Y" }}</time></p>
      </header>
      {% if post.excerpt %}
        <p>{{ post.excerpt | strip_html | truncatewords: 50 }}</p>
      {% endif %}
    </article>
  {% endfor %}
{% else %}
  <p>No posts yet. Check back soon!</p>
{% endif %}
