#!/usr/bin/env bash
# M1.7 取证：榜单封面模式 / 列表模式 / 加载中 / 失败态(带重试)
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-shots17.log
: > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
sleep 1
FQM_SELFTEST=m17 FQM_SELFTEST_DELAY=3 FQM_DEBUG_METRICS=verbose \
  nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 2
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot rank-album  m17-01-rank-album.png
shot rank-list   m17-02-rank-list.png
shot loading     m17-03-loading.png
shot failed      m17-04-failed.png
shot retried     m17-05-retried.png
for _ in $(seq 1 60); do grep -q "FQM_SELFTEST SHOT done" "$LOG" && break; sleep 0.5; done
echo "=== DUMP / 对齐 / 重试"
grep -E "FQM_SELFTEST (DUMP|RETRY)" "$LOG"
ls -l "$SHOTS"/m17-0*.png
