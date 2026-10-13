#!/usr/bin/env bash
# M2-b 回归：chain + 七猫 TXT/EPUB 下载并与 Go 参考比对
set -uo pipefail
cd /Users/yuki/Documents/FanQieMao
LOG=/tmp/fqm-regress-m2b.log
: > "$LOG"

run() { # run <name> <env assignments...>
  local name="$1"; shift
  echo "=== $name ===" | tee -a "$LOG"
  ( "$@" bash Tools/selftest.sh ) 2>&1 | tee -a "$LOG" >/dev/null || true
}

echo "### 1) chain 自检" >> "$LOG"
bash Tools/selftest.sh chain >> "$LOG" 2>&1

echo "### 2) 七猫 TXT 下载" >> "$LOG"
FQM_QIMAO_ID=195958 FQM_QIMAO_FORMAT=txt FQM_QIMAO_OUTDIR=/tmp/m2b-regress bash Tools/selftest.sh qimao-download >> "$LOG" 2>&1

echo "### 3) 七猫 EPUB 下载" >> "$LOG"
FQM_QIMAO_ID=195958 FQM_QIMAO_FORMAT=epub FQM_QIMAO_OUTDIR=/tmp/m2b-regress bash Tools/selftest.sh qimao-download >> "$LOG" 2>&1

echo "### 4) 与 Go 参考比对" >> "$LOG"
GO_TXT="/tmp/qimao-ref-go/盖世神医 狐颜乱语 [195958].txt"
GO_EPUB="/tmp/qimao-ref-go/盖世神医 狐颜乱语 [195958].epub"
APP_TXT="/tmp/m2b-regress/盖世神医 狐颜乱语 [195958].txt"
APP_EPUB="/tmp/m2b-regress/盖世神医 狐颜乱语 [195958].epub"
{
  for pair in "$APP_TXT|$GO_TXT" "$APP_EPUB|$GO_EPUB"; do
    a="${pair%%|*}"; b="${pair##*|}"
    if [[ -f "$a" && -f "$b" ]]; then
      echo "$(basename "$a"): app=$(stat -f %z "$a") go=$(stat -f %z "$b")"
      if cmp -s "$a" "$b"; then echo "  → 逐字节相同 ✓"; else echo "  → 不同 ✗"; fi
    else
      echo "$(basename "$a"): 缺文件 app=$([[ -f $a ]] && echo yes || echo no) go=$([[ -f $b ]] && echo yes || echo no)"
    fi
  done
} >> "$LOG" 2>&1

echo "### 进程残留（应为 0 0）" >> "$LOG"
{
  echo -n "FanQieMao: "; ps aux | grep -c "[F]anQieMao.app/Contents/MacOS"
  echo -n "内核: "; ps aux | grep -c "[T]omatoNovelDownloader"
} >> "$LOG" 2>&1

echo "REGRESS_DONE" >> "$LOG"
tail -40 "$LOG"
