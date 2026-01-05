#!/bin/bash

echo "🔧 修复Jekyll构建问题..."

# 检查GitHub Pages构建状态
echo "检查构建状态:"
curl -s "https://api.github.com/repos/wangxiaolei12/wangxiaolei12.github.io/pages/builds/latest" | grep -E "status|conclusion"

echo ""
echo "📝 解决方案:"
echo ""
echo "1. 检查仓库根目录是否有_config.yml"
echo "2. 确保source设置正确"
echo "3. 可能需要在根目录添加index.md"
echo ""
echo "4. 或者访问GitHub仓库设置页面重新配置Pages"
echo "   https://github.com/wangxiaolei12/wangxiaolei12.github.io/settings/pages"
echo ""
echo "当前网站显示README内容，说明Jekyll没有正确构建"
