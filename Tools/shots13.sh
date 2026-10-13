#!/usr/bin/env bash
# M1.3 取证：封面网格 / 列表 两态截图 + 帧对齐数字 + 重启记住模式
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
LOG=/tmp/fqm-shots13.log
: > "$LOG"
pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
defaults delete com.yuki.fanqiemao novelViewMode 2>/dev/null   # 清掉记录，验证「首次默认封面」
sleep 1
FQM_SELFTEST=shots3 FQM_SELFTEST_DELAY=3 FQM_DEBUG_METRICS=1 \
  nohup "$APP/Contents/MacOS/FanQieMao" > "$LOG" 2>&1 &
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST SHOT $1" "$LOG" && break; sleep 0.5; done
  sleep 2
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "captured $2"
}
shot album m13-01-album.png
shot list  m13-02-list.png
for _ in $(seq 1 60); do grep -q "FQM_SELFTEST SHOT done" "$LOG" && break; sleep 0.5; done
echo "=== 第一次运行（模式 / 对齐 / 卡片尺寸）"
grep -E "FQM_SELFTEST (MODE|FRAMES|ALBUMCARD|RESTART)" "$LOG"

echo "=== 重启（不清 UserDefaults）验证记住"
: > /tmp/fqm-modecheck.log
FQM_SELFTEST=modecheck FQM_SELFTEST_DELAY=3 FQM_DEBUG_METRICS=1 FQM_SET_MODE=album \
  nohup "$APP/Contents/MacOS/FanQieMao" > /tmp/fqm-modecheck.log 2>&1 &
for _ in $(seq 1 120); do grep -q "FQM_SELFTEST SHOT restart" /tmp/fqm-modecheck.log && break; sleep 0.5; done
for _ in $(seq 1 20); do
  sleep 1
  wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  [[ -n "${wid:-}" ]] && screencapture -x -o -l "$wid" "$SHOTS/m13-03-restart-remembered.png" 2>/dev/null && break
done
[[ -f "$SHOTS/m13-03-restart-remembered.png" ]] && echo "captured m13-03-restart-remembered.png"
grep -E "FQM_SELFTEST (RESTART|FRAMES)" /tmp/fqm-modecheck.log
grep -E "显示模式" "$LOG" /tmp/fqm-modecheck.log
ls -l "$SHOTS"/m13-0*.png
