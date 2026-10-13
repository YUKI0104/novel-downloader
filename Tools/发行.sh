#!/usr/bin/env bash
# 发行件：给外部机器（含 Intel Mac）试用。
# 用法：bash Tools/发行.sh
#
# 流程：
#   1. bash Tools/打包.sh —— Release 通用二进制（arm64 + x86_64）→ 本机证书签名
#      → 安装到 /Applications/番茄猫.app；
#   2. 从 /Applications/番茄猫.app 直接取材（保证「装的就是这个包」），
#      和中文安装说明一起放进临时目录；
#   3. 产 ~/Desktop/番茄猫-2.5.0-macOS14+.dmg（内含 番茄猫.app + 安装说明.txt）；
#   4. 再产 ~/Desktop/番茄猫-2.5.0-macOS14+.zip 兜底（微信 / AirDrop 传得动）。
#
# 红线：不改 bundle id（com.yuki.fanqiemao）、不改版本（2.5.0）、不改签名方式，
#       不做 Developer ID / 公证。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/番茄猫.app"
VER="2.5.0"
APP_NAME="番茄猫.app"
TXT_NAME="安装说明.txt"
BASE="$HOME/Desktop/番茄猫-${VER}-macOS14+"
DMG="${BASE}.dmg"
ZIP="${BASE}.zip"
VOLNAME="番茄猫 ${VER}"
STAGE="$(mktemp -d)/stage"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "== 1/4 打包（Release 通用二进制 + 签名 + 安装）=="
bash Tools/打包.sh

[[ -d "$APP" ]] || { echo "找不到 $APP" >&2; exit 1; }
ARCH_INFO="$(lipo -info "$APP/Contents/MacOS/FanQieMao")"
echo "$ARCH_INFO" | grep -q x86_64 || { echo "!! 产物缺 x86_64 切片：$ARCH_INFO" >&2; exit 1; }
echo "$ARCH_INFO"
for k in TomatoNovelDownloader-macOS_arm64 TomatoNovelDownloader-macOS_amd64; do
  [[ -x "$APP/Contents/Resources/Kernel/$k" ]] || { echo "!! 包内缺可执行内核 $k" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP" || { echo "!! 签名校验失败" >&2; exit 1; }

echo "== 2/4 准备 DMG 内容（${APP_NAME} + ${TXT_NAME}）=="
mkdir -p "$STAGE"
cat > "${STAGE}/${TXT_NAME}" <<'TXT'
番茄猫 2.5.0（macOS 14 及以上）
================================

一、系统要求
  需要 macOS 14 或更高版本。低于 macOS 14 打不开。

二、第一次打开（重要，只需做一次）
  本版本是未公证的自签名版本，macOS 首次会拦住，二选一处理：
  · 在「访达」里右键点「番茄猫.app」→ 选「打开」→ 弹窗里再点「打开」；
    若仍被拦：打开「系统设置 › 隐私与安全性」，拉到底，
    在“已阻止使用‘番茄猫’”旁边点「仍要打开」。
  · 或者打开「终端」，执行下面这行，之后就能正常双击打开：
      xattr -dr com.apple.quarantine /Applications/番茄猫.app

三、Intel 机器不用额外装东西
  这个包是通用二进制（arm64 + x86_64），包内自带两份内核（arm64 / amd64），
  Intel 机器上装的就是同一个包，不会另外要求装组件或内核。

四、首次启动会申请权限
  ·「完全磁盘访问」：用于读取浏览器登录态，只有短剧模式才需要，按需授权；
  · 其余权限按系统提示按需允许即可，拒绝也不影响普通小说下载。
TXT
ditto "$APP" "${STAGE}/${APP_NAME}"

echo "== 3/4 生成 DMG =="
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/tmp/fqm-dmg.log 2>&1 \
  || { tail -20 /tmp/fqm-dmg.log; exit 1; }

echo "== 4/4 生成 ZIP（兜底）=="
rm -f "$ZIP"
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"

echo
echo "== 产物自证 =="
for f in "$DMG" "$ZIP"; do
  printf '%s\n  大小 %s  sha256 %s\n' "$f" "$(du -h "$f" | cut -f1)" "$(shasum -a 256 "$f" | awk '{print $1}')"
done
echo "-- DMG 内容 --"
hdiutil imageinfo "$DMG" >/dev/null 2>&1 && echo "DMG 可挂载（UDZO）"
echo "-- ZIP 内容（应为 番茄猫.app/ 与 安装说明.txt）--"
unzip -l "$ZIP" | awk 'NR<=3 || /番茄猫.app\/Contents\/Info.plist|安装说明.txt/' | head -8
