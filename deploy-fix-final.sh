#!/bin/bash

echo "🚀 推送文章布局修复..."

# 推送到GitHub
if git push origin main; then
    echo "✅ 推送成功！"
    echo ""
    echo "⏳ 等待GitHub Pages更新 (2-3分钟)..."
    echo ""
    echo "🔗 测试链接："
    echo "   首页: https://wangxiaolei12.github.io"
    echo "   文章: https://wangxiaolei12.github.io/blog/2026-01-05-ov5647-driver-modernization/index.html"
    echo ""
    echo "📝 修复内容："
    echo "   ✅ 文章页面现在有完整HTML结构"
    echo "   ✅ 应用深色主题和CSS样式"
    echo "   ✅ 内容居中显示"
    echo "   ✅ 顶部导航栏"
    echo ""
    echo "💡 如果颜色仍然不对，请强制刷新浏览器 (Ctrl+F5)"
else
    echo "❌ 推送失败，请手动推送："
    echo "   git push origin main"
fi
