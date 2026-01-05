#!/bin/bash

# 快速添加新文章脚本

if [ -z "$1" ]; then
    echo "使用方法: ./new-post.sh '文章标题'"
    echo "例如: ./new-post.sh 'Linux内核调试技巧'"
    exit 1
fi

TITLE="$1"
DATE=$(date +"%Y-%m-%d")
TIME=$(date +"%Y-%m-%d %H:%M:%S +0800")
FILENAME="_posts/${DATE}-$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g').md"

echo "📝 创建新文章: $TITLE"
echo "📁 文件名: $FILENAME"

cat > "$FILENAME" << EOF
---
layout: post
title: "$TITLE"
date: $TIME
excerpt: "在这里写文章简短描述"
---

# $TITLE

## 介绍

在这里写文章介绍...

## 主要内容

### 子章节

详细内容...

\`\`\`bash
# 代码示例
echo "示例代码"
\`\`\`

## 总结

文章总结...

---

*发布于 $DATE*
EOF

echo "✅ 文章创建完成！"
echo "📝 请编辑文件: $FILENAME"
echo "🚀 完成后运行: git add . && git commit -m 'Add: $TITLE' && git push origin main"
