#!/usr/bin/env bash
# M10 取证：短剧命中改按「小说 ID」+ 详情页后台全量数据 + 卡片角标带信息 + 「在后台打开」
#
# 步骤：
#   1. 预置：settings 短剧关闭（自检会自己开/关）、平台=番茄
#   2. 构建+启动一次（bash Tools/跑.sh --selftest sd-id --delay 3）→ 截详情数据块
#   3. 复用同一个已签名 app 跑 sd-fields / sd-hit（与 Tools/selftest.sh 同法：open -n + env）
#   4. 打印全部 FQM_SELFTEST SDID / SDFIELDS / SDHIT 行
#   5. 收尾：settings 还原 shortdramaIgnored=true/shortdramaPrompted=true；平台=番茄；只剩普通启动
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
SUPPORT="$HOME/Library/Application Support/novel-downloader"
LOG=/tmp/fqm-selftest.log
ERR=/tmp/fqm-selftest.err
ALL=/tmp/fqm-m10-all.log
mkdir -p "$SHOTS" "$SUPPORT"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app

# 窗口列举助手（自己编译，避免用到底盘上的旧二进制）
LW=/tmp/listwin_m10.swift
LWB=/tmp/listwin_m10_bin
cat > "$LW" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var rows: [(Int, Int)] = []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("番茄") || owner.contains("FanQie") else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (b["Width"] as? NSNumber)?.intValue ?? 0
    let height = (b["Height"] as? NSNumber)?.intValue ?? 0
    rows.append((num, width * height))
}
rows.sort { $0.1 > $1.1 }
for r in rows { print(r.0) }
SWIFT
swiftc -O "$LW" -o "$LWB" >/dev/null 2>&1 || true
pick_window() { "$LWB" 2>/dev/null | head -1; }

kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}

restore_settings() {
  python3 - "$SUPPORT/settings.json" <<'PY'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data["shortdramaIgnored"] = True
data["shortdramaPrompted"] = True
open(path, "w").write(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
print("settings:", data.get("shortdramaIgnored"), data.get("shortdramaPrompted"))
PY
  defaults write com.yuki.fanqiemao novelPlatform fanqie 2>/dev/null || true
}

run_mode() { # run_mode <mode> <"marker:file"> ...
  local mode="$1"; shift
  local -a shots=("$@")
  echo
  echo "############ bash Tools/跑.sh --selftest $mode ############"
  : > "$LOG"; : > "$ERR"
  bash Tools/跑.sh --selftest "$mode" --delay 3 >/dev/null 2>&1 || true
  # 等第一个 SHOT 标记 → 截对应窗口；标记里的空格换成 __ 传参
  for spec in "${shots[@]}"; do
    local marker="${spec%%::*}" file="${spec##*::}"
    for _ in $(seq 1 300); do grep -q "FQM_SELFTEST $marker" "$LOG" 2>/dev/null && break; sleep 0.2; done
    open -a "$APP" >/dev/null 2>&1 || true
    sleep 2
    local wid=""; wid=$(pick_window)
    for _ in $(seq 1 8); do
      [[ -n "$wid" ]] && break
      sleep 1; wid=$(pick_window)
    done
    if [[ -n "$wid" ]]; then
      screencapture -x -o -l "$wid" "$SHOTS/$file" && echo "  captured $file (window $wid)"
    else
      echo "  !! 没有窗口，未截 $file"
    fi
  done
  for _ in $(seq 1 300); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break; sleep 1; done
  sleep 1
  grep -hE '^FQM_SELFTEST' "$LOG" "$ERR" 2>/dev/null >> "$ALL"
}

echo "############ 预置状态 ############"
kill_all
restore_settings
: > "$ALL"

run_mode sd-id     "SDID SHOT detail-id::m10-01-detail-block.png"
run_mode sd-fields "SDFIELDS SHOT detail-fields::m10-02-detail-fields.png"
run_mode sd-hit    "SDHIT SHOT hits-badges::m10-03-card-badges.png"

echo
echo "=== M10 自检行（SDID / SDFIELDS / SDHIT）==="
grep -hE '^FQM_SELFTEST (SDID|SDFIELDS|SDHIT)' "$ALL" 2>/dev/null

echo
echo "=== 收尾：settings 还原 + 平台=番茄 + 普通启动 ==="
restore_settings
echo "=== 收尾：普通启动（留一个实例）==="
pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
open -n "$APP"
sleep 3
echo -n "  实例数（应 1）: "; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo "=== 截图 ==="
for f in m10-01-detail-block m10-02-detail-fields m10-03-card-badges; do
  p="$SHOTS/$f.png"
  [[ -f "$p" ]] || { echo "  $p 缺失"; continue; }
  dim=$(sips -g pixelWidth -g pixelHeight "$p" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  echo "  $(basename "$p")  ${dim} $(shasum -a 256 "$p" | cut -c1-16)"
done
