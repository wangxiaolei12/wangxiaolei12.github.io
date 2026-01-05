#!/bin/bash

# Xiaolei Wang (wangxiaolei12) 博客部署脚本

echo "🚀 部署 Xiaolei Wang 的技术博客..."
echo "GitHub用户名: wangxiaolei12"
echo "仓库地址: https://github.com/wangxiaolei12/wangxiaolei12.github.io"

# 检查Git配置
if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
    echo "⚠️  配置Git用户信息:"
    git config user.name "Xiaolei Wang"
    git config user.email "xiaolei.wang@windriver.com"
    echo "✅ Git配置完成"
fi

# 初始化git仓库
if [ ! -d ".git" ]; then
    git init
    echo "✅ Git仓库已初始化"
fi

# 添加所有文件
git add .

# 提交
git commit -m "Deploy Xiaolei Wang's technical blog

- GitHub username: wangxiaolei12
- Jekyll blog with professional design
- Linux kernel development focus
- Technical articles about OV5647 driver and media subsystem
- Ready for GitHub Pages deployment"

echo "✅ 文件已提交"

# 添加远程仓库
git remote remove origin 2>/dev/null
git remote add origin https://github.com/wangxiaolei12/wangxiaolei12.github.io.git

echo "✅ 远程仓库已配置"

echo ""
echo "📝 接下来的步骤:"
echo ""
echo "1. 在GitHub创建仓库 'wangxiaolei12.github.io'"
echo "   访问: https://github.com/new"
echo "   仓库名: wangxiaolei12.github.io"
echo "   设为Public，不要初始化任何文件"
echo ""
echo "2. 推送代码:"
echo "   git branch -M main"
echo "   git push -u origin main"
echo ""
echo "3. 启用GitHub Pages:"
echo "   访问: https://github.com/wangxiaolei12/wangxiaolei12.github.io/settings/pages"
echo "   Source: Deploy from a branch"
echo "   Branch: main"
echo "   Folder: / (root)"
echo ""
echo "4. 等待几分钟后访问:"
echo "   https://wangxiaolei12.github.io"
echo ""
echo "🎉 配置完成！"
