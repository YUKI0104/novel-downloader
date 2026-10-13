#!/usr/bin/env bash
# M3-f 补拍：真实命中搜索页/详情数据条 + 教程弹窗 + 检测登录态成功态
# 窗口选择：列出所有「番茄猫」窗口，按面积取最大的那个（不用 head -1）。
# 启动走 LaunchServices（open），番茄猫才用自己的 TCC 身份（能读 Safari 登录态）。
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-m3f.log

kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}
wait_app() { for _ in $(seq 1 400); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || return 0; sleep 1; done; return 1; }
shot() { # shot <标记> <输出名>
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  swift /tmp/listwin_fqm.swift >/tmp/fqm-win-all.txt 2>/tmp/fqm-win-pick.txt
  local wid; wid=$(sed -n 's/^PICK //p' /tmp/fqm-win-pick.txt)
  echo "  窗口清单: $(paste -sd';' /tmp/fqm-win-all.txt)"
  if [[ -n "$wid" ]]; then screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"; else echo "  !! 没有窗口，未截 $2"; fi
}

echo "############ m3f 补拍 ############"
kill_all
: > "$LOG"; : > "${LOG}.err"
open -n "$APP" --env FQM_SELFTEST=m3f --env FQM_SELFTEST_DELAY=3 --stdout "$LOG" --stderr "${LOG}.err"
shot "M3F SHOT settings-login-ok" m3f-01-settings-login-ok.png
shot "M3F SHOT tutorial"          m3f-02-tutorial.png
shot "M3F SHOT search-hit"        m3f-03-search-hit.png
shot "M3F SHOT detail-strip"      m3f-04-detail-strip.png
wait_app
echo "=== M3F 数字 ==="; grep -h '^FQM_SELFTEST M3F' "$LOG" "${LOG}.err" 2>/dev/null
echo "=== 进程残留（应 0）==="; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo "M3F_VERIFY_DONE"
