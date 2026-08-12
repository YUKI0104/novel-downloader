#!/bin/bash
# 构建 番茄猫下载器.app(通用二进制: arm64 + x86_64)并打包通用番茄内核。
set -e
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH:$HOME/go/bin"

wails build -platform darwin/universal

APP="build/bin/番茄猫下载器.app/Contents/Resources"
# 内核来源: 通用内核 > TOMATO_BIN > ~/bin > 上一版包内
SRC="${TOMATO_BIN:-$HOME/bin/Tomato-Novel-Downloader-universal}"
if [ ! -f "$SRC" ]; then
    SRC="${TOMATO_BIN:-$HOME/bin/Tomato-Novel-Downloader}"
fi
if [ ! -f "$SRC" ]; then
    OLD="$APP/Tomato-Novel-Downloader"
    if [ -f "$OLD" ]; then SRC="$OLD"; fi
fi
if [ ! -f "$SRC" ]; then
    echo "❌ 未找到番茄内核: $SRC"; exit 1
fi
cp "$SRC" "$APP/Tomato-Novel-Downloader"
chmod +x "$APP/Tomato-Novel-Downloader"
echo "✅ 已打包番茄内核: $SRC"
du -sh build/bin/番茄猫下载器.app
