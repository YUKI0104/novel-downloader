#!/usr/bin/env bash
# M3-d 取证：Safari 登录态来源 + 使用教程引导
#   ① 文件不存在  ② 读取被拒（TCC/权限）  ③ 能读但没有 shortdramas cookie
#   开关显示=isEnabled（prompted=false 时为关）；教程弹窗；番茄详情提示条
#   回归：chain + 布局
#
# 启动一律走 LaunchServices（open），番茄猫才用自己的 TCC 身份（FDA 才生效）。
# 用法：bash Tools/verify_m3d.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 1; }
LOG=""

kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}
launch() { # launch <mode> [extra-open-args...]
  local mode="$1"; shift
  LOG="/tmp/fqm-m3d-${mode}.log"; : > "$LOG"; : > "${LOG}.err"
  open -n "$APP" --env FQM_SELFTEST="$mode" --env FQM_SELFTEST_DELAY=3 \
    --stdout "$LOG" --stderr "${LOG}.err" "$@"
}
wait_app() { for _ in $(seq 1 400); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || return 0; sleep 1; done; return 1; }
shot() {
  for _ in $(seq 1 400); do grep -q "FQM_SELFTEST $1" "$LOG" && break; sleep 0.5; done
  sleep 3
  local wid; wid=$(swift /tmp/listwin.swift 2>/dev/null | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
  [[ -n "$wid" ]] && screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"
}

echo "############ 生成 Safari binarycookies 夹具（Python 独立实现）############"
python3 Tools/make_safari_fixture.py /tmp/fqm-m3d
cp /tmp/fqm-m3d/other.binarycookies /tmp/fqm-m3d/noaccess.binarycookies; chmod 000 /tmp/fqm-m3d/noaccess.binarycookies

echo
echo "############ m3d：真机 Safari + 开关一致性 + 教程 ############"
kill_all
launch m3d
shot "M3D SHOT settings-toggle-off" m3d-01-settings-toggle-off.png
shot "M3D SHOT tutorial"            m3d-02-tutorial.png
shot "M3D SHOT detail-hint"         m3d-03-detail-hint.png
wait_app
grep -h '^FQM_SELFTEST M3D' "$LOG" | sed -E 's/(hex=).*/\1…/'

echo
echo "############ chain 回归 ############"
kill_all
launch chain
wait_app
grep -h '^FQM_SELFTEST' "$LOG" | head -12

echo
echo "############ 布局回归 ############"
kill_all
launch fonts
wait_app
grep -h '^FQM_SELFTEST FONT' "$LOG" | grep -E "主页封面|详情-短简介|下载管理" | sed -E 's/｜ 封面 detail-cover=缺失//'

echo
echo "=== 进程残留（应为 0 0）==="
echo -n "  FanQieMao: "; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo -n "  内核: "; pgrep -f TomatoNovelDownloader | wc -l | tr -d ' '
echo "=== 截图 ==="; ls -l "$SHOTS"/m3d-0*.png 2>/dev/null
echo "M3D_VERIFY_DONE"
