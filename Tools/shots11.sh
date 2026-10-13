#!/usr/bin/env bash
# M1.11 取证：详情弹窗固定 950×600（简介长/短两本）
set -uo pipefail
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
APP=~/Library/Caches/fqm-derived/Build/Products/Release/FanQieMao.app
LOG=/tmp/fqm-shots11.log; : > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS"; sleep 1; pkill -9 -f TomatoNovelDownloader; sleep 1
FQM_SELFTEST=detailfixed FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
sleep 5; open -a "$APP" >/dev/null 2>&1
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST FIXED SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot 简介长 m111-01-detail-long.png
shot 简介短 m111-02-detail-short.png
for _ in $(seq 1 120); do grep -q "FQM_SELFTEST FIXED done" "$LOG" && break; sleep 1; done
echo "=== 数字"; grep -E "FQM_SELFTEST FIXED" "$LOG"
