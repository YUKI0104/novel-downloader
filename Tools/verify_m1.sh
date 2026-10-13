#!/usr/bin/env bash
# M1 验收取证脚本：构建 → 三种退出路径 → 孤儿接管 → 内核不自自杀 → 番茄链路。
# 用法：bash Tools/verify_m1.sh            （全部）
#       bash Tools/verify_m1.sh exits      （只跑退出验收）
# 输出同时写到 /tmp/fqm-verify.txt
set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release
DATA_DIR="$HOME/Library/Caches/tomato-novel-downloader"
APP_SUPPORT="$HOME/Library/Application Support/FanQieMao"
OUT=/tmp/fqm-verify.txt
: > "$OUT"

log() { echo "$@" | tee -a "$OUT"; }
section() { echo "" | tee -a "$OUT"; echo "===== $* =====" | tee -a "$OUT"; }

log "== 构建 =="
xcodebuild -scheme FanQieMao -configuration $CONFIG -derivedDataPath "$HOME/Library/Caches/fqm-derived" build > /tmp/fqm-build.log 2>&1
log "构建结果：$(grep -E '^\*\* BUILD' /tmp/fqm-build.log | tail -1)"
APP=$(xcodebuild -scheme FanQieMao -configuration $CONFIG -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
BIN="$APP/Contents/MacOS/FanQieMao"
log "产物：$APP"
log "大小：$(du -sh "$APP" | cut -f1)"
log "出厂内核 SHA（必须与任务书一致）："
shasum -a 256 "$APP/Contents/Resources/Kernel/"* | sed 's/^/  /' | tee -a "$OUT"

ps_kernel() { ps -eo pid,ppid,pgid,state,command | grep -E "FanQieMao\.app/Contents/MacOS/FanQieMao|TomatoNovelDownloader --server" | grep -v grep; }
port_kernel() { lsof -nP -iTCP:18423 -sTCP:LISTEN 2>/dev/null | tail -n +2; }
cleanup_all() { pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null; pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null; sleep 1; }
app_pid() { pgrep -f "FanQieMao.app/Contents/MacOS/FanQieMao" | head -1; }

wait_for_kernel() { # 最多 30s：进程在跑且端口已监听
  for _ in $(seq 1 60); do
    if [[ -n "$(ps -eo command | grep -E 'TomatoNovelDownloader --server' | grep -v grep)" ]] \
       && lsof -nP -iTCP:18423 -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}
wait_for_app_exit() { # 最多 40s
  for _ in $(seq 1 80); do
    [[ -z "$(app_pid)" ]] && return 0
    sleep 0.5
  done
  return 1
}

launch() { # launch <selftest-mode|-> <delay>
  local mode="$1" delay="${2:-8}"
  if [[ "$mode" == "-" ]]; then
    nohup "$BIN" >> /tmp/fqm-app-stdout.log 2>&1 &
  else
    FQM_SELFTEST="$mode" FQM_SELFTEST_DELAY="$delay" nohup "$BIN" >> /tmp/fqm-app-stdout.log 2>&1 &
  fi
  echo $!
}

report_state() { # report_state <label>
  log "--- $1"
  log "ps -eo pid,ppid,pgid,state,command | grep -E 'FanQieMao.app/Contents/MacOS/FanQieMao|TomatoNovelDownloader --server':"
  ps_kernel | sed 's/^/    /' | tee -a "$OUT"
  [[ -z "$(ps_kernel)" ]] && log "    （无残留）"
  log "lsof -nP -iTCP:18423 -sTCP:LISTEN:"
  port_kernel | sed 's/^/    /' | tee -a "$OUT"
  [[ -z "$(port_kernel)" ]] && log "    （端口已释放）"
}

# ---------------------------------------------------------------------------
section "退出路径 1/3：点红叉（performClose → applicationWillTerminate）"
cleanup_all
launch close 10 >/dev/null
if wait_for_kernel; then report_state "启动后：App + 内核都在跑"; else report_state "异常：内核没起来"; fi
wait_for_app_exit
sleep 2; report_state "点红叉退出后（ps 应无残留、端口应释放）"

# ---------------------------------------------------------------------------
section "退出路径 2/3：Cmd+Q（NSApp.terminate）"
cleanup_all
launch quit 10 >/dev/null
if wait_for_kernel; then report_state "启动后：App + 内核都在跑"; else report_state "异常：内核没起来"; fi
wait_for_app_exit
sleep 2; report_state "Cmd+Q 退出后（ps 应无残留、端口应释放）"

# ---------------------------------------------------------------------------
section "退出路径 3/3：kill -9 App（孤儿）→ 重开接管 → 再退出收干净"
cleanup_all
APP_PID=$(launch - )
if wait_for_kernel; then report_state "kill 之前：App + 内核都在跑"; else report_state "异常：内核没起来"; fi
kill -9 "$APP_PID"; sleep 2
report_state "kill -9 App 之后（内核成孤儿，ppid=1）"
log "--- 重开 App 接管孤儿内核"
launch quit 12 >/dev/null
if wait_for_kernel; then report_state "接管后（内核仍是原 PID，App 换新 PID）"; fi
log "内核 PID 文件内容：$(cat "$APP_SUPPORT/kernel.pid" 2>/dev/null)"
wait_for_app_exit
sleep 2; report_state "接管者退出后（孤儿被收干净）"

# ---------------------------------------------------------------------------
section "内核不自自杀：连续启动 3 次，每次「检测到热补丁」计数必须为 0"
cleanup_all
[[ -f "$DATA_DIR/logs/latest.log" ]] && mv "$DATA_DIR/logs/latest.log" "$DATA_DIR/logs/latest.log.bak-$RANDOM"
for i in 1 2 3; do
  launch quit 8 >/dev/null
  wait_for_kernel >/dev/null || true
  wait_for_app_exit >/dev/null || true
  if [[ -f "$DATA_DIR/logs/latest.log" ]]; then
    log "第 $i 次：grep -c 热补丁 $(grep -c 热补丁 "$DATA_DIR/logs/latest.log")"
  else
    log "第 $i 次：日志文件不存在"
  fi
done
report_state "三次启动后"

if [[ "${1:-all}" == "exits" ]]; then
  log ""
  log "（只跑了退出验收）完整输出见 $OUT"
  exit 0
fi

# ---------------------------------------------------------------------------
section "番茄链路：搜索 / ID 直达 / 链接直达 / 详情 / 下载前 3 章"
cleanup_all
rm -f /tmp/fqm-selftest.log
FQM_DOWNLOAD_LIMIT=3 FQM_SELFTEST=chain FQM_SELFTEST_DELAY=3 \
FQM_SELFTEST_KEYWORD="游走神话时代" FQM_SELFTEST_DOWNLOAD_KEYWORD="穿书到八零" \
  nohup "$BIN" > /tmp/fqm-selftest.log 2>&1 &
for _ in $(seq 1 240); do
  grep -q "自检链路结束" /tmp/fqm-selftest.log && break
  sleep 1
done
log "--- 自检输出"
grep "FQM_SELFTEST" /tmp/fqm-selftest.log | sed 's/^/  /' | tee -a "$OUT"
log "--- 下载产物（ls -l）"
PRODUCED=$(sed -n 's/^FQM_SELFTEST 下载完成：\(.*\)（.*/\1/p' /tmp/fqm-selftest.log | tail -1)
if [[ -n "$PRODUCED" ]]; then
  ls -l "$PRODUCED" | sed 's/^/  /' | tee -a "$OUT"
  log "  文件大小：$(stat -f '%z' "$PRODUCED") 字节"
  log "  前 3 行内容：$(head -3 "$PRODUCED" | tr '\n' ' ' | cut -c1-120)"
else
  log "  没找到产物路径"
fi
log "--- 下载记录尾部（downloads.json）"
tail -12 "$HOME/Library/Application Support/novel-downloader/downloads.json" | sed 's/^/  /' | tee -a "$OUT"
sleep 2; report_state "链路跑完后"

log ""
log "完整输出：$OUT"
