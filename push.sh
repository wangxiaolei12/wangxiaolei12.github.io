#!/bin/bash

echo "🚀 推送修复到GitHub..."

# 尝试推送
if git push origin main; then
    echo "✅ 推送成功！"
    echo "等待2-3分钟后访问: https://wangxiaolei12.github.io"
else
    echo "❌ 推送失败，请手动推送："
    echo "   git push origin main"
    echo ""
    echo "或者配置认证后推送："
    echo "   git config user.name 'Xiaolei Wang'"
    echo "   git config user.email 'xiaolei.wang@windriver.com'"
    echo "   git push origin main"
fi
