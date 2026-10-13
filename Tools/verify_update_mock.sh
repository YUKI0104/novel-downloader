#!/usr/bin/env bash
# 内核自动更新链路取证（规格 6 / 任务书「更新链路用 mock 跑通」）。
#
# mock A：真·HTTP 下载（官方 v2.4.15 asset）+ 假版本号 v9.9.9
#         → 证明「下载 → --version 校验」会拦住版本对不上的包
# mock B：假内核（只会打印 v9.9.9，不提供服务）
#         → 证明「下载→校验→替换→重启→健康检查失败 → 自动回滚」
# mock C：包装内核（--version 报 v9.9.9，其余参数转交真内核）
#         → 证明完整成功链「下载→校验→替换→重启→健康检查通过→保留版本」
# 跑完会把 current 指针恢复回 v2.4.15 并删除 mock 版本。
set -uo pipefail
cd "$(dirname "$0")/.."

OUT=/tmp/fqm-update-verify.txt
: > "$OUT"
log() { echo "$@" | tee -a "$OUT"; }
section() { echo "" | tee -a "$OUT"; echo "===== $* =====" | tee -a "$OUT"; }

APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app
BIN="$APP/Contents/MacOS/FanQieMao"
AS="$HOME/Library/Application Support/FanQieMao"
KROOT="$AS/kernel"
REAL_KERNEL="$KROOT/2.4.15/TomatoNovelDownloader"
ASSET="TomatoNovelDownloader-macOS_arm64-v2.4.15"

cleanup() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS/FanQieMao" 2>/dev/null
  pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null
  sleep 1
}
show_state() {
  log "--- $1"
  log "  current -> $(readlink "$KROOT/current" 2>/dev/null || echo '(无)')"
  log "  kernel 目录：$(ls "$KROOT" 2>/dev/null | tr '\n' ' ')"
  log "  内核进程：$(ps -eo pid,ppid,command | grep -E 'TomatoNovelDownloader|mock-kernel' | grep -v grep | head -3 | tr '\n' '|')"
  log "  端口：$(lsof -nP -iTCP:18423 -sTCP:LISTEN 2>/dev/null | tail -1)"
}

run_update() { # run_update <描述>
  local label="$1"
  : > /tmp/fqm-update-run.log
  FQM_SELFTEST=update FQM_SELFTEST_DELAY=3 nohup "$BIN" > /tmp/fqm-update-run.log 2>&1 &
  sleep 45
  log "--- $label 更新相关日志"
  grep -E "更新|内核|mock|校验|回滚|SIGKILL|current 指针" /tmp/fqm-update-run.log | sed 's/^/  /' | tee -a "$OUT"
  cleanup
}

# ---------------------------------------------------------------------------
section "准备：确保当前是出厂内核 v2.4.15"
cleanup
[[ -x "$REAL_KERNEL" ]] || { log "缺少 $REAL_KERNEL"; exit 1; }
if [[ "$(readlink "$KROOT/current")" != "2.4.15/TomatoNovelDownloader" ]]; then
  rm -rf "$KROOT"/9.9.9
  ln -sfn "2.4.15/TomatoNovelDownloader" "$KROOT/current"
fi
show_state "起点"

# ---------------------------------------------------------------------------
section "mock A：真 HTTP 下载 + 版本号对不上 → 必须拒绝安装"
# 用本地 HTTP 服务提供官方原样 arm64 内核（真链路：URLSession 下载 → chmod → --version 校验），
# 但声称远端是 v9.9.9，因此必须在「--version 校验」那一步被拦下。
python3 -m http.server 18777 --directory /tmp >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1
log "本地 HTTP 服务：http://127.0.0.1:18777/official-arm64（官方原样内核，sha=$(shasum -a 256 /tmp/official-arm64 | cut -c1-16)…）"
FQM_MOCK_RELEASE_TAG=v9.9.9 \
FQM_MOCK_ASSET_URL="http://127.0.0.1:18777/official-arm64" \
  run_update "mock A"
kill $HTTP_PID 2>/dev/null
show_state "mock A 之后（current 必须仍是 2.4.15）"

section "网络可达性（GitHub 直连 / 加速镜像，仅报告不改状态）"
for u in \
  "https://api.github.com/repos/zhongbai2333/Tomato-Novel-Downloader/releases/latest" \
  "https://ghfast.top/https://api.github.com/repos/zhongbai2333/Tomato-Novel-Downloader/releases/latest" \
  "https://github.com/zhongbai2333/Tomato-Novel-Downloader/releases/download/v2.4.15/$ASSET" ; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -I "$u" 2>/dev/null || echo "timeout")
  log "  HTTP $code  $u"
done

# ---------------------------------------------------------------------------
section "mock B：假内核起不来 → 替换后健康检查失败 → 必须自动回滚"
cat > /tmp/mock-kernel-fail.sh <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Tomato Novel Downloader v9.9.9"; exit 0; fi
echo "mock kernel: refuse to serve" >&2
exit 1
EOF
chmod 755 /tmp/mock-kernel-fail.sh
FQM_MOCK_RELEASE_TAG=v9.9.9 FQM_MOCK_ASSET_PATH=/tmp/mock-kernel-fail.sh run_update "mock B"
show_state "mock B 之后（current 必须回到 2.4.15，9.9.9 目录应被清掉）"

# ---------------------------------------------------------------------------
section "mock C：包装内核（--version 报 v9.9.9，其余转交真内核）→ 完整成功链"
cat > /tmp/mock-kernel-ok.sh <<EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "Tomato Novel Downloader v9.9.9"; exit 0; fi
exec "$REAL_KERNEL" "\$@"
EOF
chmod 755 /tmp/mock-kernel-ok.sh
FQM_MOCK_RELEASE_TAG=v9.9.9 FQM_MOCK_ASSET_PATH=/tmp/mock-kernel-ok.sh run_update "mock C"
show_state "mock C 之后（current 应为 9.9.9，且内核健康在跑）"

# ---------------------------------------------------------------------------
section "收尾：恢复出厂内核 v2.4.15，并再启动一次确认可用"
pkill -9 -f "TomatoNovelDownloader --server" 2>/dev/null; sleep 1
rm -rf "$KROOT/9.9.9"
ln -sfn "2.4.15/TomatoNovelDownloader" "$KROOT/current"
show_state "恢复后"
FQM_SELFTEST=quit FQM_SELFTEST_DELAY=6 nohup "$BIN" > /tmp/fqm-update-final.log 2>&1 &
sleep 16
grep -E "内核|SIGKILL" /tmp/fqm-update-final.log | sed 's/^/  /' | tee -a "$OUT"
cleanup
show_state "最终"
log ""
log "完整输出：$OUT"
