#!/usr/bin/env bash
# M2-c 取证：七猫入口默认开放
#   第 1 段（清空偏好 = 首次打开）：默认启动应为番茄 + 两个 chip 都在 → 切七猫男生榜 → 七猫搜索/详情/下载 TXT → 留七猫退出
#   第 2 段（重启）：应仍是七猫 → 切回番茄，榜单回到综合热榜
#   第 3 段：chain 自检
# 用法：bash Tools/verify_m2c.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
DOMAIN=com.yuki.fanqiemao
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 1; }

LOG=""
kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null
  sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null
  sleep 1
}
shot() { # shot <标记> <输出名>
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  if [[ -n "$wid" ]]; then screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"; else echo "  !! 没找到窗口，未截到 $2"; fi
}
wait_for() { for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && return 0; sleep 1; done; return 1; }

echo "############ 第 1 段：首次打开（清空 novelPlatform）默认启动 ############"
kill_all
defaults delete "$DOMAIN" novelPlatform 2>/dev/null
echo "  清空后 novelPlatform=$(defaults read "$DOMAIN" novelPlatform 2>/dev/null || echo '(无记录)')"
LOG=/tmp/fqm-m2c-phase1.log; : > "$LOG"
FQM_SELFTEST=m2c FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
shot "M2C SHOT default-fanqie" "m2c-01-default-fanqie.png"
shot "M2C SHOT qimao-rank"     "m2c-02-qimao-rank.png"
shot "M2C SHOT qimao-search"   "m2c-03-qimao-search.png"
shot "M2C SHOT qimao-detail"   "m2c-04-qimao-detail.png"
wait_for "M2C done-leave-qimao" >/dev/null 2>&1
wait "$PID" 2>/dev/null
echo "=== 第 1 段 FQM_SELFTEST 行 ==="; grep '^FQM_SELFTEST' "$LOG"
echo "=== 第 1 段结束后持久化（应为 qimao）==="; echo "  novelPlatform=$(defaults read "$DOMAIN" novelPlatform 2>/dev/null || echo '(无记录)')"

echo
echo "############ 第 2 段：重启（应仍是七猫）→ 切回番茄 ############"
kill_all
LOG=/tmp/fqm-m2c-phase2.log; : > "$LOG"
FQM_SELFTEST=m2c-resume FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
shot "M2CRESUME SHOT resume-qimao" "m2c-05-resume-qimao.png"
shot "M2CRESUME SHOT fanqie-back" "m2c-06-fanqie-back.png"
wait_for "M2CRESUME done" >/dev/null 2>&1
wait "$PID" 2>/dev/null
echo "=== 第 2 段 FQM_SELFTEST 行 ==="; grep '^FQM_SELFTEST' "$LOG"
echo "=== 第 2 段结束后持久化（应为 fanqie）==="; echo "  novelPlatform=$(defaults read "$DOMAIN" novelPlatform 2>/dev/null || echo '(无记录)')"

echo
echo "############ 第 3 段：chain 回归 ############"
kill_all
LOG=/tmp/fqm-m2c-chain.log; : > "$LOG"
FQM_SELFTEST=chain FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
PID=$!
wait_for "自检链路结束" >/dev/null 2>&1 || true
wait "$PID" 2>/dev/null
grep '^FQM_SELFTEST' "$LOG"

echo
echo "=== 进程残留（应为 0 0）==="
echo -n "  FanQieMao: "; ps aux | grep -c "[F]anQieMao.app/Contents/MacOS"
echo -n "  内核: "; ps aux | grep -c "[T]omatoNovelDownloader"
echo "=== 截图 ==="; ls -l "$SHOTS"/m2c-0*.png 2>/dev/null
echo "M2C_VERIFY_DONE"
