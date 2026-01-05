#!/bin/bash

# Xiaolei Wang's Blog Deployment Script
# 使用方法: ./deploy.sh

echo "🚀 部署 Xiaolei Wang 的技术博客..."

# 检查是否在正确的目录
if [ ! -f "_config.yml" ]; then
    echo "❌ 错误: 请在博客根目录运行此脚本"
    exit 1
fi

# 检查Git配置
if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
    echo "⚠️  请先配置Git用户信息:"
    echo "   git config --global user.name 'Xiaolei Wang'"
    echo "   git config --global user.email 'xiaolei.wang@windriver.com'"
    exit 1
fi

echo "✅ Git配置检查通过"

# 初始化git仓库
if [ ! -d ".git" ]; then
    git init
    echo "✅ Git仓库已初始化"
fi

# 添加所有文件
git add .

# 提交
git commit -m "Initial blog setup for Xiaolei Wang

- Jekyll blog with clean, minimalist design
- Technical posts about Linux kernel development
- OV5647 driver modernization article
- Linux media subsystem guide
- Professional about page
- Responsive design with dark theme support"

echo "✅ 文件已提交"

# 添加远程仓库 (需要用户手动设置)
echo ""
echo "📝 接下来的步骤:"
echo ""
echo "1. 在GitHub上创建仓库 'xiaolei-wang.github.io'"
echo "2. 运行以下命令添加远程仓库:"
echo "   git remote add origin https://github.com/xiaolei-wang/xiaolei-wang.github.io.git"
echo "   git branch -M main"
echo "   git push -u origin main"
echo ""
echo "3. 在GitHub仓库设置中启用GitHub Pages"
echo "4. 等待几分钟后访问 https://xiaolei-wang.github.io"
echo ""
echo "💡 本地开发:"
echo "   bundle install"
echo "   bundle exec jekyll serve"
echo "   然后访问 http://localhost:4000"
echo ""
echo "✍️  添加新文章:"
echo "   在 _src/_posts/ 目录下创建 YYYY-MM-DD-title.md 文件"
echo ""
echo "🎉 博客已准备就绪!"
