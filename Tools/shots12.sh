#!/usr/bin/env bash
set -uo pipefail
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
APP=~/Library/Caches/fqm-derived/Build/Products/Release/FanQieMao.app
LOG=/tmp/fqm-shots12.log; : > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS"; sleep 1; pkill -9 -f TomatoNovelDownloader; sleep 1
FQM_SELFTEST=fonts FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
sleep 5; open -a "$APP" >/dev/null 2>&1
shot() {
  for _ in $(seq 1 500); do grep -q "FQM_SELFTEST FONT SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 2
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot home-album  m112-01-home-album.png
shot home-list   m112-02-home-list.png
shot detail-long m112-03-detail-long.png
shot detail-short m112-04-detail-short.png
shot downloads   m112-05-downloads.png
shot settings    m112-06-settings.png
for _ in $(seq 1 120); do grep -q "FQM_SELFTEST FONT done" "$LOG" && break; sleep 1; done
echo "=== 数字"; grep -E "FQM_SELFTEST FONT" "$LOG" | sed 's/FQM_SELFTEST //'
