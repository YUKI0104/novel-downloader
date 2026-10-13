#!/usr/bin/env bash
# M11 取证截图：设置页 / 详情页 6 行 / 榜单卡片（序号右下+角标右上）/ 下载完成+Finder 图标 /
#             追加只读标签取证 sd-tags 两态
# 用法：bash Tools/shots_m11.sh
#
# 走 LaunchServices（open -n --env），与 Tools/selftest.sh 同一条路：
# 只有经 open 启动，番茄猫才用自己的签名身份（TCC/完全磁盘访问权限才生效）。
set -uo pipefail
cd "$(dirname "$0")/.."

SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
APP=~/Library/Caches/fqm-derived/Build/Products/Release/FanQieMao.app
[ -d "$APP" ] || { echo "app not found: $APP（先跑 bash Tools/跑.sh）" >&2; exit 1; }

# 只截「番茄猫」自己的窗口（按 owner 过滤；窗口 bounds 会被显示器缩放，别拿尺寸当条件）
win_id() {
  swift /tmp/listwin.swift 2>/dev/null \
    | awk '/owner=(番茄猫|FanQieMao)/ {gsub(/id=/,"",$1); print $1; exit}'
}

run_pass() {           # $1 = selftest 模式, 其余 = "marker 文件名" 对
  local mode="$1"; shift
  local log="/tmp/fqm-shots-m11-${mode}.log"
  : > "$log"
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null; sleep 1
  open -n "$APP" --env FQM_SELFTEST="$mode" --env FQM_SELFTEST_DELAY=3 \
    --env FQM_DOWNLOAD_LIMIT=3 \
    --stdout "$log" --stderr "${log}.err"
  echo "== $mode == log: $log"
  while [[ $# -ge 2 ]]; do
    local marker="$1" file="$2"; shift 2
    for _ in $(seq 1 900); do grep -q "FQM_SELFTEST SHOT $marker" "$log" && break; sleep 0.5; done
    sleep 2
    local wid; wid=$(win_id)
    if [[ -n "$wid" ]]; then
      screencapture -x -o -l "$wid" "$SHOTS/$file" && echo "captured $file (win $wid)"
    else
      echo "!! 没找到番茄猫窗口，截图跳过：$file" >&2
    fi
  done
  # 等自检自己退出
  for _ in $(seq 1 150); do
    pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break
    sleep 2
  done
  sleep 1
  grep -h '^FQM_SELFTEST' "$log" "${log}.err" 2>/dev/null
  echo "残留进程=$(pgrep -f 'FanQieMao.app/Contents/MacOS' | wc -l | tr -d ' ')"
  echo "== $mode 完成 =="
}

run_pass m11 \
  m11-settings      m11p-01-settings.png \
  m11-detail        m11p-02-detail-6lines.png \
  m11-download      m11p-03-download-done-finder-icon.png \
  m11-rank-card     m11p-04-rank-card-rank-bottom-right.png \
  m11-detail-sd-off m11p-05-detail-shortdrama-off.png

run_pass sd-tags \
  sd-tags      m11p-06-sd-tags-real.png \
  sd-tags-many m11p-07-sd-tags-many.png
