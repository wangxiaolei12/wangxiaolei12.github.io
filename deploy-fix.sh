#!/bin/bash

# 修复部署脚本 - 支持自定义用户名

if [ -z "$1" ]; then
    echo "使用方法: ./deploy-fix.sh your-github-username"
    echo "例如: ./deploy-fix.sh wangxiaolei"
    echo ""
    echo "请提供你的真实GitHub用户名"
    exit 1
fi

USERNAME=$1
REPO_URL="https://github.com/$USERNAME/$USERNAME.github.io.git"

echo "🔧 修复博客部署..."
echo "用户名: $USERNAME"
echo "仓库: $REPO_URL"

# 更新配置文件
sed -i "s/xiaolei-wang/$USERNAME/g" _config.yml
sed -i "s/xiaolei-wang/$USERNAME/g" _src/about-me.md
sed -i "s/xiaolei-wang/$USERNAME/g" README.md

echo "✅ 配置已更新为用户名: $USERNAME"

# Git操作
git add .
git commit -m "Fix GitHub username configuration"

# 更新远程仓库
git remote remove origin 2>/dev/null
git remote add origin $REPO_URL

echo ""
echo "📝 接下来的步骤:"
echo "1. 在GitHub创建仓库: $USERNAME.github.io"
echo "2. 运行: git push -u origin main"
echo "3. 在仓库设置中启用GitHub Pages"
echo "4. 访问: https://$USERNAME.github.io"
echo ""
