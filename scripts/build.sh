#!/bin/bash
# 构建 番茄猫下载器.app(通用二进制: arm64 + x86_64)并打包通用番茄内核。
set -e
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH:$HOME/go/bin"

wails build -platform darwin/universal

APP="build/bin/番茄猫下载器.app/Contents/Resources"
# 内核来源: TOMATO_BIN > vendor(项目内,稳定) > ~/bin universal > ~/bin 单架构 > 上一版包内
SRC="${TOMATO_BIN:-}"
if [ -z "$SRC" ] && [ -f "kernels/Tomato-Novel-Downloader-universal" ]; then
    SRC="kernels/Tomato-Novel-Downloader-universal"
fi
if [ -z "$SRC" ] && [ -f "$HOME/bin/Tomato-Novel-Downloader-universal" ]; then
    SRC="$HOME/bin/Tomato-Novel-Downloader-universal"
fi
if [ -z "$SRC" ] && [ -f "$HOME/bin/Tomato-Novel-Downloader" ]; then
    SRC="$HOME/bin/Tomato-Novel-Downloader"
fi
if [ -z "$SRC" ]; then
    OLD="$APP/Tomato-Novel-Downloader"
    if [ -f "$OLD" ]; then SRC="$OLD"; fi
fi
if [ -z "$SRC" ]; then
    echo "❌ 未找到番茄内核"; exit 1
fi
cp "$SRC" "$APP/Tomato-Novel-Downloader"
chmod +x "$APP/Tomato-Novel-Downloader"
# 打包后验证: 内核必须带官方 API,否则番茄搜索会硬编码返回空(2026-08-23 v1.3.0 事故)
API_CNT=$(strings "$APP/Tomato-Novel-Downloader" | grep -c 'api5-normal-sinfonlinec')
if [ "$API_CNT" -lt 1 ]; then
    echo "❌ 内核缺官方 API(api5 标记=$API_CNT),搜索会失效,禁止打包: $SRC"
    echo "   请用官方 arm64+amd64 lipo 合成 universal 放到 vendor/"
    exit 1
fi
echo "✅ 已打包番茄内核: $SRC(官方 API 标记=$API_CNT)"
du -sh build/bin/番茄猫下载器.app
