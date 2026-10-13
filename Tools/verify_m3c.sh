#!/usr/bin/env bash
# M3-c 取证：短剧首启询问
#  ① 首启询问弹窗（prompted=false）  ② 拒绝后设置页状态
#  未问过时三条链路都不查后台（读钥匙串=0）；chain 回归
# 用法：bash Tools/verify_m3c.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 1; }
LOG=""
kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  if [[ -n "$wid" ]]; then screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"; else echo "  !! 没找到窗口，未截到 $2"; fi
}
wait_for() { for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && return 0; sleep 1; done; return 1; }

echo "############ m3c：首启询问 ############"
kill_all
LOG=/tmp/fqm-m3c.log; : > "$LOG"
FQM_SELFTEST=m3c FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
shot "M3C SHOT first-prompt"          m3c-01-first-prompt.png
shot "M3C SHOT after-decline-settings" m3c-02-after-decline-settings.png
wait_for "M3C done" >/dev/null 2>&1
wait "$PID" 2>/dev/null
echo "=== M3C 数字 ==="; grep '^FQM_SELFTEST M3C' "$LOG"
echo "=== 短剧日志（未问过时不应有查询行）==="; grep -E "短剧\(" "$LOG" || echo "  （无短剧查询日志）"

echo
echo "############ chain 回归 ############"
kill_all
LOG=/tmp/fqm-m3c-chain.log; : > "$LOG"
FQM_SELFTEST=chain FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
wait_for "自检链路结束" >/dev/null 2>&1 || true
wait "$PID" 2>/dev/null
grep '^FQM_SELFTEST' "$LOG"

echo
echo "=== 进程残留（应为 0 0）==="
echo -n "  FanQieMao: "; ps aux | grep -c "[F]anQieMao.app/Contents/MacOS"
echo -n "  内核: "; ps aux | grep -c "[T]omatoNovelDownloader"
echo "=== 截图 ==="; ls -l "$SHOTS"/m3c-0*.png 2>/dev/null
echo "M3C_VERIFY_DONE"
