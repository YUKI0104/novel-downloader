#!/usr/bin/env bash
# M1.5 取证：默认榜单 / 切频道 / 切榜单类型与题材 / 返回榜单
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-shots15.log
: > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
sleep 1
FQM_SELFTEST=rank FQM_SELFTEST_DELAY=3 FQM_DEBUG_METRICS=1 \
  nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 2
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot rank-hot      m15-01-rank-hot.png
shot rank-male     m15-02-rank-male.png
shot rank-male-new m15-03-rank-male-new.png
shot rank-genre    m15-04-rank-genre.png
shot search        m15-05-search-backbtn.png
shot back-rank     m15-06-back-to-rank.png
for _ in $(seq 1 60); do grep -q "FQM_SELFTEST SHOT done" "$LOG" && break; sleep 0.5; done
echo "=== 状态与耗时"
grep -E "FQM_SELFTEST (STATUS|TIMING|RANK|BACK)" "$LOG"
echo "=== 榜单缓存/耗时日志"
grep -E "榜单耗时|榜单命中缓存|榜单频道已加载" "$LOG" | tail -8
ls -l "$SHOTS"/m15-0*.png
