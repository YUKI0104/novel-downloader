#!/usr/bin/env bash
# M1.9x 取证：主页左右留白相等（封面/列表/搜索页）
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-shots20.log
: > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
sleep 1
FQM_SELFTEST=margins FQM_SELFTEST_DELAY=3 nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
sleep 5; open -a "$APP" >/dev/null 2>&1
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST MARGIN SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 2
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot album  m20-01-album.png
shot list   m20-02-list.png
shot search m20-03-search.png
for _ in $(seq 1 120); do grep -q "FQM_SELFTEST MARGIN done" "$LOG" && break; sleep 0.5; done
echo "=== 数字"; grep -E "FQM_SELFTEST MARGIN" "$LOG"
