#!/usr/bin/env bash
# M3-b 取证（命中路径）：无真机登录态，注入短剧后台命中，验证红标/角标/排最前/状态行计数
# 用法：bash Tools/verify_m3b_hits.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-m3b-hit.log; : > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
FQM_SELFTEST=m3b-hit FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  [[ -n "$wid" ]] && screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"
}
shot "M3BHIT SHOT hits-rank"   m3b-hit-01-rank.png
shot "M3BHIT SHOT hits-search" m3b-hit-02-search.png
for _ in $(seq 1 400); do grep -q "FQM_SELFTEST M3BHIT done" "$LOG" && break; sleep 1; done
wait "$PID" 2>/dev/null
echo "=== M3BHIT 数字 ==="; grep '^FQM_SELFTEST M3BHIT' "$LOG"
echo "=== 短剧注入日志 ==="; grep -E "短剧\(注入\)|短剧命中" "$LOG"
echo -n "=== 进程残留（应 0）: "; ps aux | grep -c "[F]anQieMao.app/Contents/MacOS"
echo "M3BHIT_VERIFY_DONE"
