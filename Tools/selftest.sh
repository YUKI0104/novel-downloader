#!/usr/bin/env bash
# 独立验收：跑一个自检模式并抓 FQM_SELFTEST 行
# 用法：bash Tools/selftest.sh <mode> [keyword] [keyword2]
#
# 重要：用 LaunchServices（open）启动，而不是 nohup 直接在 shell 里跑。
# 直接当 shell 子进程跑时，TCC 会把访问算到「终端」头上；只有经 open 启动，
# 番茄猫才用自己的签名身份（完全磁盘访问权限才生效，M3-d 读 Safari 登录态需要）。
set -uo pipefail
cd "$(dirname "$0")/.."
MODE="$1"; KW="${2:-}"; KW2="${3:-}"
APP=~/Library/Caches/fqm-derived/Build/Products/Release/FanQieMao.app
LOG=/tmp/fqm-selftest-${MODE}-$(date +%H%M%S).log
ERR="${LOG}.err"
pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
: > "$LOG"; : > "$ERR"
open -n "$APP" \
  --env FQM_SELFTEST="$MODE" --env FQM_SELFTEST_DELAY=3 \
  ${KW:+--env FQM_SELFTEST_KEYWORD="$KW"} \
  ${KW2:+--env FQM_SELFTEST_KEYWORD2="$KW2"} \
  ${FQM_SD_SAFARI_COOKIES:+--env FQM_SD_SAFARI_COOKIES="$FQM_SD_SAFARI_COOKIES"} \
  ${FQM_DOWNLOAD_LIMIT:+--env FQM_DOWNLOAD_LIMIT="$FQM_DOWNLOAD_LIMIT"} \
  --stdout "$LOG" --stderr "$ERR"
echo "log: $LOG"
# 自检模式最后都会 NSApp.terminate，等进程退出
for _ in $(seq 1 300); do
  pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break
  sleep 2
done
sleep 2
echo "=== FQM_SELFTEST 行 ==="
grep -h '^FQM_SELFTEST' "$LOG" "$ERR" 2>/dev/null
echo "=== 进程残留数（应为 0）==="
pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
