#!/usr/bin/env bash
# M13 取证：榜单页分段行右侧（☰ 左侧空位）的「刷新榜单」按钮
#
#   ① m13-rank-refresh        榜单页顶栏：刷新按钮在 ☰（显示方式切换）左侧空位
#   ② m13-rank-refreshed      点一次刷新后：卡片重取（短剧开关开着 → 角标照旧按 ID 重查）
#   ③ m13-rank-male-refresh   切到男频再刷新：频道保持（不跳回综合热榜）
#
# 同一次运行里给出行为/几何数字，随后跑回归（chain / windowsize / margins）。
# 用法：bash Tools/shots_m13.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
SUPPORT="$HOME/Library/Application Support/novel-downloader"
ALL=/tmp/fqm-m13-all.log
LOG=/tmp/fqm-m13.log
ERR=/tmp/fqm-m13.err
mkdir -p "$SHOTS" "$SUPPORT"
APP="$HOME/Library/Caches/fqm-derived/Build/Products/Release/FanQieMao.app"
[ -d "$APP" ] || { echo "app not found: $APP（先跑 bash Tools/跑.sh）" >&2; exit 1; }

# —— 窗口列举助手（只按 owner 过滤，拿窗口号给 screencapture -l）——
LW=/tmp/listwin_m13.swift
LWB=/tmp/listwin_m13_bin
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
data["downloadDir"] = os.path.expanduser("~/Downloads")
open(path, "w").write(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
print("settings:", data.get("shortdramaIgnored"), data.get("shortdramaPrompted"), data.get("downloadDir"))
PY
  defaults write com.yuki.fanqiemao novelPlatform fanqie 2>/dev/null || true
}

echo "############ 预置状态 ############"
kill_all
restore_settings
: > "$ALL"
echo "== 自检前 ps（FanQieMao 进程，应为空）=="
ps -Ao pid,command | grep -E "FanQieMao.app/Contents/MacOS|TomatoNovelDownloader" | grep -v grep || echo "  （无）"

echo
echo "############ FQM_SELFTEST=m13 ############"
: > "$LOG"; : > "$ERR"
open -n "$APP" \
  --env FQM_SELFTEST=m13 --env FQM_SELFTEST_DELAY=3 \
  --stdout "$LOG" --stderr "$ERR"
capture() { # capture <marker> <file> <delay>
  local marker="$1" file="$2" delay="$3"
  for _ in $(seq 1 1500); do grep -q "FQM_SELFTEST $marker" "$LOG" 2>/dev/null && break; sleep 0.2; done
  sleep "$delay"
  local wid=""; wid=$(pick_window)
  for _ in $(seq 1 20); do [[ -n "$wid" ]] && break; sleep 1; wid=$(pick_window); done
  if [[ -n "$wid" ]]; then
    screencapture -x -o -l "$wid" "$SHOTS/$file" && echo "  captured $file (window $wid)"
  else
    echo "  !! 没有窗口，未截 $file"
  fi
}
capture "M13 SHOT m13-rank-refresh"      m13-01-rank-refresh.png      2
capture "M13 SHOT m13-rank-refreshed"    m13-02-rank-refreshed.png    2
capture "M13 SHOT m13-rank-male-refresh" m13-03-rank-male-refresh.png 2
for _ in $(seq 1 600); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break; sleep 1; done
sleep 1
grep -hE '^FQM_SELFTEST' "$LOG" "$ERR" 2>/dev/null >> "$ALL"

echo
echo "=== M13 自检行 ==="
grep -hE '^FQM_SELFTEST M13' "$ALL" 2>/dev/null

echo
echo "=== 榜单请求日志（fmLog，stderr）==="
grep -hE '榜单耗时|刷新榜单' "$ERR" 2>/dev/null | tail -12

echo
echo "############ 回归 ############"
for mode in chain windowsize margins; do
  echo "---- selftest $mode ----"
  out=$(FQM_DOWNLOAD_LIMIT=3 bash Tools/selftest.sh "$mode" 2>&1)
  echo "$out" | grep -hE '^FQM_SELFTEST|进程残留数' | sed 's/^/  /'
  echo "$out" | grep -hE '^FQM_SELFTEST' >> "$ALL"
done

echo
echo "=== 收尾：settings 还原 + 平台=番茄 + 普通启动 ==="
restore_settings
kill_all
open -n "$APP"
sleep 4
echo -n "  实例数（应 1）: "; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo "  平台=$(defaults read com.yuki.fanqiemao novelPlatform 2>/dev/null || echo -)"
echo "  settings: $(python3 -c "import json;d=json.load(open('$SUPPORT/settings.json'));print('shortdramaIgnored=%s shortdramaPrompted=%s downloadDir=%s'%(d.get('shortdramaIgnored'),d.get('shortdramaPrompted'),d.get('downloadDir')))")"
echo
echo "=== 截图 ==="
for f in m13-01-rank-refresh m13-02-rank-refreshed m13-03-rank-male-refresh; do
  p="$SHOTS/$f.png"
  [[ -f "$p" ]] || { echo "  $p 缺失"; continue; }
  dim=$(sips -g pixelWidth -g pixelHeight "$p" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  echo "  $p  ${dim} $(shasum -a 256 "$p" | cut -c1-16)"
done
echo
echo "=== 源码取证 ==="
grep -n 'refreshRankButton\|rank-refresh-button\|refreshSymbolName\|arrow.clockwise\|arrow.triangle.2.circlepath\|help("刷新榜单")' Sources/Features/Rank/RankView.swift
echo "-- 搜索页不受影响：刷新按钮只在 RankView 的 channelRow 里 --"
grep -n 'refreshRankButton' Sources/Features/Search/SearchView.swift Sources/Features/Search/ResultsArea.swift || echo "  （搜索页无刷新按钮 → OK）"
echo "-- AppModel：加载态/计数/防并发 --"
grep -n 'rankIsLoading\|rankRequestCount\|lastRankDurationMs\|func refreshRank' Sources/AppModel.swift
