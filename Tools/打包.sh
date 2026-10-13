#!/usr/bin/env bash
# 定稿打包：Release 构建 → 本机证书签名（FanQieMao Dev）→ 安装到「应用程序」/番茄猫.app。
# 用法：bash Tools/打包.sh
#
# 红线：
#   · 与旧版 /Applications/番茄猫下载器.app（com.wails.番茄猫下载器）**并存**，绝不覆盖/删除/改动旧版；
#   · 只签名、绝不把证书加进系统信任（和 Tools/dev-sign-setup.sh 一致）；
#   · 只安装到 /Applications/番茄猫.app（bundle id 保持 com.yuki.fanqiemao）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release
DEST="/Applications/番茄猫.app"
OLD="/Applications/番茄猫下载器.app"
KEYCHAIN="$(pwd)/Tools/fqmdev.keychain-db"
BUILD_LOG=/tmp/fqm-package-build.log

echo "== 1/4 Release 构建（通用二进制 arm64 + x86_64）=="
# 必须给 generic/platform=macOS：否则 xcodebuild 挑本机 arch 的 destination，
# 只会编出 arm64 一片（project.yml 里的 ARCHS 被 destination 压掉）。
xcodebuild -scheme FanQieMao -configuration "$CONFIG" -destination 'generic/platform=macOS' \
  -derivedDataPath "$HOME/Library/Caches/fqm-derived" \
  build >"$BUILD_LOG" 2>&1 || {
  tail -40 "$BUILD_LOG"
  exit 1
}
grep -E '^\*\* BUILD' "$BUILD_LOG" | tail -1

APP="$(xcodebuild -scheme FanQieMao -configuration "$CONFIG" \
  -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app"
[[ -d "$APP" ]] || { echo "构建产物不存在：$APP" >&2; exit 1; }
echo "产物：$APP"

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VER" == "2.5.0" ]] || { echo "!! CFBundleShortVersionString=$VER（应为 2.5.0）" >&2; exit 1; }

echo "== 2/4 本机证书签名（FanQieMao Dev）=="
[[ -f "$KEYCHAIN" ]] || { echo "缺少签名钥匙串 $KEYCHAIN，先跑 bash Tools/dev-sign-setup.sh" >&2; exit 1; }
security unlock-keychain -p "" "$KEYCHAIN" 2>/dev/null || true
codesign --force --deep --identifier com.yuki.fanqiemao \
  --keychain "$KEYCHAIN" --sign "FanQieMao Dev" "$APP"
codesign --verify --deep --strict "$APP"
echo "签名：$(codesign -dvvv "$APP" 2>&1 | grep -m1 '^Authority=')"

echo "== 3/4 安装到 $DEST =="
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
if [[ -d "$OLD" ]]; then
  echo "旧版仍在、未改动：${OLD}（$(defaults read "$OLD/Contents/Info" CFBundleIdentifier)）"
fi

echo "== 4/4 自证 =="
echo "bundle id  : $(defaults read "$DEST/Contents/Info" CFBundleIdentifier)"
echo "版本       : $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString)"
echo "图标       : $(defaults read "$DEST/Contents/Info" CFBundleIconFile 2>/dev/null || echo '-')  Assets.car=$([[ -f "$DEST/Contents/Resources/Assets.car" ]] && echo 有 || echo 无)"
codesign -dv "$DEST" 2>&1 | sed -n '1,4p'
du -sh "$DEST"
