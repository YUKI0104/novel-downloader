#!/usr/bin/env bash
# M1.9 取证：① 详情弹窗右栏顺序（作者行在 ID 行下面）+ 封面高 == 右列高
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-shots19.log
: > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
sleep 1
FQM_SELFTEST=shots2 FQM_SELFTEST_DELAY=3 FQM_DEBUG_METRICS=1 \
  nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
sleep 4; open -a "$APP" >/dev/null 2>&1
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 2
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot detail-long  m19-01-detail-long.png
shot detail-short m19-02-detail-short.png
shot downloads    m19-03-downloads.png
for _ in $(seq 1 120); do grep -q "FQM_SELFTEST SHOT done" "$LOG" && break; sleep 0.5; done
echo "=== 尺寸结论"; grep -E "FQM_SELFTEST STATE" "$LOG"
