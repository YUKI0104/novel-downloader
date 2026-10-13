#!/usr/bin/env bash
# M3-g 取证：榜单 / 搜索失败时的可感知反馈
#   · 造失败：把榜单 URL 指到坏域名（DNS 立即失败，等价「断网」；只换 URL，不动接口/频道/排序）
#   · 自动重试 3 次（1s / 2s / 4s），重试期间状态行「网络不稳，正在重试 n/3…」
#   · 截图：重试中的状态行 / 3 次失败后的「重试」按钮 / 手动重试恢复
#   · 日志：NetworkRetry 记录每次重试的实测等待与最终结果
#
# 启动一律走 Tools/跑.sh（xcodebuild + 自签名 + open/LaunchServices），
# 自检进程的 stdout/stderr 落在 /tmp/fqm-selftest.log / .err。
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
mkdir -p "$SHOTS"
LOG=/tmp/fqm-selftest.log
ERR=/tmp/fqm-selftest.err

kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}

# 窗口列举预编译成二进制：重试中的状态只保持 ~4s，截图不能花在建 swift 脚本上
swiftc -O /tmp/listwin_fqm.swift -o /tmp/listwin_fqm_bin >/dev/null 2>&1 || true

pick_window() {
  if [[ -x /tmp/listwin_fqm_bin ]]; then
    /tmp/listwin_fqm_bin >/tmp/fqm-win-all.txt 2>/tmp/fqm-win-pick.txt
  else
    swift /tmp/listwin_fqm.swift >/tmp/fqm-win-all.txt 2>/tmp/fqm-win-pick.txt
  fi
  sed -n 's/^PICK //p' /tmp/fqm-win-pick.txt | head -1
}

# 瞬态（重试中）截图：0.1s 轮询，命中标记后立刻抓
shot_fast() { # shot_fast <标记> <输出名>
  for _ in $(seq 1 900); do grep -q "FQM_SELFTEST $1" "$LOG" 2>/dev/null && break; sleep 0.1; done
  local wid; wid=$(pick_window)
  echo "  窗口清单: $(paste -sd';' /tmp/fqm-win-all.txt)"
  if [[ -n "$wid" ]]; then
    screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"
  else
    echo "  !! 没有窗口，未截 $2"
  fi
}

# 稳态截图：等 2s 再抓
shot_settle() { # shot_settle <标记> <输出名>
  for _ in $(seq 1 900); do grep -q "FQM_SELFTEST $1" "$LOG" 2>/dev/null && break; sleep 0.2; done
  sleep 2
  local wid; wid=$(pick_window)
  if [[ -n "$wid" ]]; then
    screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"
  else
    echo "  !! 没有窗口，未截 $2"
  fi
}

# 可选标记（如「搜索失败」不一定出现）：最多等 40s，没出现就跳过
shot_optional() { # shot_optional <标记> <输出名>
  local hit=0
  for _ in $(seq 1 200); do grep -q "FQM_SELFTEST $1" "$LOG" 2>/dev/null && { hit=1; break; }; sleep 0.2; done
  [[ "$hit" == 1 ]] || { echo "  (标记未出现，跳过 $2)"; return 0; }
  sleep 2
  local wid; wid=$(pick_window)
  if [[ -n "$wid" ]]; then
    screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"
  else
    echo "  !! 没有窗口，未截 $2"
  fi
}

echo "############ m3g：失败自动重试 ############"
kill_all
# 关键：open --stdout 不保证截断旧日志，不清理会把上一轮标记当成本轮命中
rm -f "$LOG" "$ERR"
echo "构建+启动：bash Tools/跑.sh --selftest m3g --delay 3"
bash Tools/跑.sh --selftest m3g --delay 3
shot_fast   "M3G SHOT retrying" m3g-01-retrying.png
shot_settle "M3G SHOT failed"   m3g-02-failed-retry-button.png
shot_settle "M3G SHOT retried"  m3g-03-retried.png
shot_optional "M3G SHOT search-failed" m3g-04-search-failed.png

# 等自检退出
for _ in $(seq 1 200); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break; sleep 1; done
sleep 1

echo
echo "=== M3G 自检行 ==="
grep -h '^FQM_SELFTEST M3G' "$LOG" "$ERR" 2>/dev/null
echo
echo "=== NetworkRetry 重试日志（间隔与最终结果）==="
grep -h 'M3G ' "$ERR" 2>/dev/null | grep -E '重试|失败' | tail -20
echo
echo "=== 残留进程（应 0 0）==="
echo -n "  FanQieMao: "; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo -n "  内核: "; pgrep -f TomatoNovelDownloader | wc -l | tr -d ' '
echo "=== 截图 ==="
for f in "$SHOTS"/m3g-01-retrying.png "$SHOTS"/m3g-02-failed-retry-button.png "$SHOTS"/m3g-03-retried.png "$SHOTS"/m3g-04-search-failed.png; do
  [[ -f "$f" ]] || { echo "  $f 缺失"; continue; }
  dim=$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  echo "  $(basename "$f")  ${dim}  $(shasum -a 256 "$f" | cut -c1-16)"
done
echo "M3G_VERIFY_DONE"
