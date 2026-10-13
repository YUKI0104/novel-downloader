#!/usr/bin/env bash
# 弹窗取证截图：把三个弹窗依次摆好，按窗口 id 截图（不截全屏）。
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-shots.log
: > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
sleep 1
FQM_SELFTEST=shots FQM_SELFTEST_DELAY=3 FQM_DOWNLOAD_LIMIT=3 \
  nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
shot() { # shot <标记> <输出名>
  for _ in $(seq 1 240); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2 (window $wid)"
}
shot "SHOT detail"    m11-01-detail.png
shot "SHOT downloads" m11-02-downloads.png
shot "SHOT confirm"   m11-03-confirm.png
for _ in $(seq 1 60); do grep -q "FQM_SELFTEST SHOT done" "$LOG" && break; sleep 0.5; done
grep -E "FQM_SELFTEST SHOT|下载完成" "$LOG" | tail -5
ls -l "$SHOTS"/m11-0*.png
