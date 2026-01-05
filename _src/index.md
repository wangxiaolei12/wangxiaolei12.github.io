---
title: "Latest Posts"
description: "Xiaolei Wang's blog about Linux kernel development, graphics programming, and embedded systems"
---

<div class="home">
  {% if site.posts.size > 0 %}
    <ul class="post-list">
      {% for post in site.posts %}
        <li class="post-item">
          <h2 class="post-title">
            <a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a>
          </h2>
          <div class="post-meta">
            <time datetime="{{ post.date | date_to_xmlschema }}">
              {{ post.date | date: "%B %d, %Y" }}
            </time>
          </div>
          {% if post.excerpt %}
            <div class="post-excerpt">
              {{ post.excerpt | strip_html | truncatewords: 50 }}
            </div>
          {% endif %}
        </li>
      {% endfor %}
    </ul>
  {% else %}
    <p>No posts yet. Check back soon!</p>
  {% endif %}
</div>
