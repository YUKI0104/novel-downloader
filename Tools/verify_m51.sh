#!/usr/bin/env bash
# M5.1 取证：「最近查看」新排版（标题/分段左对齐 + liquidglass 分段 + 清空记录右侧同一行 +
#            平台标签两色 + 时间靠右同行 + 空状态分两段）+ 记录语义「甲」
#            （按 ID / 书页链接直达只进详情记录，主文本=解析出来的书名）
#
# 步骤：
#   1. 预置：settings 关短剧（避免干扰）；平台=番茄
#   2. 启动一律走 Tools/跑.sh --selftest m51（xcodebuild + 自签名 + open/LaunchServices）
#   3. 截图：搜索记录段 / 详情记录段 / 两段空状态
#   4. 打印所有 FQM_SELFTEST M51 行（含几何数字与语义断言）
#   5. 收尾：history.json 复位为空；settings 还原 shortdramaIgnored=true/shortdramaPrompted=true；平台=番茄
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
SUPPORT="$HOME/Library/Application Support/novel-downloader"
LOG=/tmp/fqm-selftest.log
ERR=/tmp/fqm-selftest.err
mkdir -p "$SHOTS" "$SUPPORT"
APP=$(xcodebuild -scheme FanQieMao -configuration Release -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app

# 窗口列举助手（复用/编译成二进制，截图不花在建脚本上）
if [[ ! -x /tmp/listwin_fqm_bin ]]; then
  cat > /tmp/listwin_fqm.swift <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var rows: [(Int, Int, String)] = []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("番茄") || owner.contains("FanQie") else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (b["Width"] as? NSNumber)?.intValue ?? 0
    let height = (b["Height"] as? NSNumber)?.intValue ?? 0
    let x = (b["X"] as? NSNumber)?.intValue ?? 0
    let y = (b["Y"] as? NSNumber)?.intValue ?? 0
    rows.append((num, width * height, "id=\(num) \(width)x\(height)@(\(x),\(y))"))
}
rows.sort { $0.1 > $1.1 }
for r in rows { print(r.2) }
if let first = rows.first { FileHandle.standardError.write(Data("PICK \(first.0)\n".utf8)) }
SWIFT
  swiftc -O /tmp/listwin_fqm.swift -o /tmp/listwin_fqm_bin >/dev/null 2>&1 || true
fi

pick_window() {
  if [[ -x /tmp/listwin_fqm_bin ]]; then
    /tmp/listwin_fqm_bin >/tmp/fqm-win-all.txt 2>/tmp/fqm-win-pick.txt
  else
    swift /tmp/listwin_fqm.swift >/tmp/fqm-win-all.txt 2>/tmp/fqm-win-pick.txt
  fi
  sed -n 's/^PICK //p' /tmp/fqm-win-pick.txt | head -1
}

shot_settle() { # shot_settle <FQM_SELFTEST 标记> <输出名>
  for _ in $(seq 1 900); do grep -q "FQM_SELFTEST $1" "$LOG" 2>/dev/null && break; sleep 0.2; done
  # 把窗口拉到最前再截：被遮挡的窗口不重绘，screencapture -l 会拿到陈旧内容
  [[ -d "$APP" ]] && open -a "$APP" >/dev/null 2>&1 || true
  sleep 2
  local wid; wid=$(pick_window)
  echo "  窗口清单: $(paste -sd';' /tmp/fqm-win-all.txt)"
  if [[ -n "$wid" ]]; then
    screencapture -x -o -l "$wid" "$SHOTS/$2" && echo "  captured $2 (window $wid)"
  else
    echo "  !! 没有窗口，未截 $2"
  fi
}

kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}

echo "############ 预置状态 ############"
kill_all
if [[ -f "$SUPPORT/history.json" ]]; then
  cp "$SUPPORT/history.json" "/tmp/history.json.bak.$(date +%Y%m%d-%H%M%S)"
fi
# settings：关短剧，避免首启询问/教程弹窗干扰（历史与短剧互不相干）
python3 - "$SUPPORT/settings.json" <<'PY'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data["shortdramaIgnored"] = True
data["shortdramaPrompted"] = True
open(path, "w").write(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
print("settings: shortdramaIgnored=true shortdramaPrompted=true")
PY
defaults write com.yuki.fanqiemao novelPlatform fanqie 2>/dev/null || true

echo
echo "############ 构建+启动：bash Tools/跑.sh --selftest m51 --delay 3 ############"
rm -f "$LOG" "$ERR"
bash Tools/跑.sh --selftest m51 --delay 3
shot_settle "M51 SHOT history-search"       m51-01-history-search.png
shot_settle "M51 SHOT history-detail"       m51-02-history-detail.png
shot_settle "M51 SHOT history-empty-search" m51-03-history-empty-search.png
shot_settle "M51 SHOT history-empty-detail" m51-04-history-empty-detail.png

for _ in $(seq 1 200); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break; sleep 1; done
sleep 1

echo
echo "=== M5.1 自检行 ==="
grep -h '^FQM_SELFTEST M51' "$LOG" "$ERR" 2>/dev/null

echo
echo "=== 记录写盘日志（最近查看）==="
grep -hE '最近查看' "$LOG" "$ERR" "$HOME/Library/Application Support/FanQieMao/logs/app.log" 2>/dev/null | tail -30

echo
echo "=== 收尾：history.json 复位为空 + settings 还原 + 平台=番茄 ==="
printf '[]\n' > "$SUPPORT/history.json"
python3 - "$SUPPORT/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["shortdramaIgnored"] = True
data["shortdramaPrompted"] = True
open(path, "w").write(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
print("settings:", data.get("shortdramaIgnored"), data.get("shortdramaPrompted"))
PY
defaults write com.yuki.fanqiemao novelPlatform fanqie 2>/dev/null || true

echo
echo "=== 残留进程（应 0 0）==="
echo -n "  FanQieMao: "; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo -n "  内核: "; pgrep -f TomatoNovelDownloader | wc -l | tr -d ' '
echo "=== 截图 ==="
for f in m51-01-history-search m51-02-history-detail m51-03-history-empty-search m51-04-history-empty-detail; do
  p="$SHOTS/$f.png"
  [[ -f "$p" ]] || { echo "  $p 缺失"; continue; }
  dim=$(sips -g pixelWidth -g pixelHeight "$p" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  echo "  $(basename "$p")  ${dim}  $(shasum -a 256 "$p" | cut -c1-16)"
done
echo "M51_VERIFY_DONE"
