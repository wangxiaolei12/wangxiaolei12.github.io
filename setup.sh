#!/bin/bash

# Xiaolei Wang's Blog - 快速开始脚本

echo "🔧 设置 Xiaolei Wang 的技术博客开发环境..."

# 检查Ruby是否安装
if ! command -v ruby &> /dev/null; then
    echo "❌ Ruby未安装。请先安装Ruby:"
    echo "   macOS: brew install ruby"
    echo "   Ubuntu: sudo apt install ruby-full build-essential zlib1g-dev"
    echo "   Windows: https://rubyinstaller.org/"
    exit 1
fi

echo "✅ Ruby已安装: $(ruby --version)"

# 检查Bundler是否安装
if ! command -v bundle &> /dev/null; then
    echo "📦 安装Bundler..."
    gem install bundler
fi

echo "✅ Bundler已安装: $(bundle --version)"

# 安装依赖
echo "📦 安装Jekyll和依赖..."
bundle install

echo ""
echo "🎉 开发环境设置完成!"
echo ""
echo "🚀 启动本地服务器:"
echo "   bundle exec jekyll serve"
echo ""
echo "📝 然后访问: http://localhost:4000"
echo ""
echo "💡 开发提示:"
echo "   - 修改文件后会自动重新生成"
echo "   - 修改_config.yml需要重启服务器"
echo "   - 新文章放在_src/_posts/目录"
echo "   - 文章格式: YYYY-MM-DD-title.md"
echo ""
echo "📚 技术博客主题:"
echo "   - Linux内核开发"
echo "   - 设备驱动程序"
echo "   - 图形编程"
echo "   - 嵌入式系统"
echo ""
