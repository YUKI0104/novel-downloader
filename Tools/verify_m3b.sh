#!/usr/bin/env bash
# M3-b 取证：短剧 IP 界面联动
#   ① 短剧模式关：七猫榜单 / 设置页（改编书单入口应消失）
#   ② 短剧模式开 + 无登录态：番茄榜单 / 搜索 / 详情三条链路正常（不挂、不弹钥匙串）
#   ③ 短剧模式开：七猫改编书单入口出现 / 设置页
#   回归：chain + 布局（窗口/卡片/弹窗/留白）
# 用法：bash Tools/verify_m3b.sh
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
shot() { # shot <标记> <输出名>
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  if [[ -n "$wid" ]]; then screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"; else echo "  !! 没找到窗口，未截到 $2"; fi
}
wait_for() { for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && return 0; sleep 1; done; return 1; }

echo "############ m3b：短剧界面联动取证 ############"
kill_all
LOG=/tmp/fqm-m3b.log; : > "$LOG"
FQM_SELFTEST=m3b FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
shot "M3B SHOT off-qimao-rank" m3b-01-off-qimao-rank.png
shot "M3B SHOT off-settings"   m3b-02-off-settings.png
shot "M3B SHOT on-fanqie-rank" m3b-03-on-fanqie-rank.png
shot "M3B SHOT on-search"      m3b-04-on-search.png
shot "M3B SHOT on-detail"      m3b-05-on-detail.png
shot "M3B SHOT on-qimao-rank"  m3b-06-on-qimao-rank.png
shot "M3B SHOT on-settings"    m3b-07-on-settings.png
wait_for "M3B done" >/dev/null 2>&1
wait "$PID" 2>/dev/null
echo "=== M3B 数字 ==="; grep '^FQM_SELFTEST M3B' "$LOG"
echo "=== 短剧相关日志（含耗时/钥匙串次数）==="; grep -E "短剧\(|短剧命中|短剧结果已过期" "$LOG" | tail -20

echo
echo "############ chain 回归 ############"
kill_all
LOG=/tmp/fqm-m3b-chain.log; : > "$LOG"
FQM_SELFTEST=chain FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
wait_for "自检链路结束" >/dev/null 2>&1 || true
wait "$PID" 2>/dev/null
grep '^FQM_SELFTEST' "$LOG"

echo
echo "############ 布局回归（窗口/卡片/弹窗/留白）############"
kill_all
LOG=/tmp/fqm-m3b-fonts.log; : > "$LOG"
FQM_SELFTEST=fonts FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
wait_for "FONT done" >/dev/null 2>&1 || true
wait "$PID" 2>/dev/null
grep -E "FQM_SELFTEST FONT (主页封面|详情-长简介|下载管理) " "$LOG"

echo
echo "=== 进程残留（应为 0 0）==="
echo -n "  FanQieMao: "; ps aux | grep -c "[F]anQieMao.app/Contents/MacOS"
echo -n "  内核: "; ps aux | grep -c "[T]omatoNovelDownloader"
echo "=== 截图 ==="; ls -l "$SHOTS"/m3b-0*.png 2>/dev/null
echo "M3B_VERIFY_DONE"
