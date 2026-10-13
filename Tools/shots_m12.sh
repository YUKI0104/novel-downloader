#!/usr/bin/env bash
# M12-b 取证：详情页下载按钮状态机 + 动作行/后台两行重排
#
#   ① m12b-idle        未下载：动作行无「共 N 章」、按钮蓝底「下载」、两行紧贴按钮右侧、
#                      榜单框整块已删（该位置不留空框/空行）
#   ② m12b-downloading 下载中：按钮内从左到右绿色填充（真实 saved/total）
#   ③ m12b-done        下载完成：整体绿 + **文件夹图标**（无「打开」文字、右侧无放大镜按钮）
#   ④ m12b-deleted     删掉文件后按钮回到蓝色「下载」
#   ⑤ m12b-failed      落盘失败：按钮仍蓝「下载」+ M11 红字错误提示
#
# 同一次运行里跑完 5 张图 + 行为/几何数字；随后跑回归（chain / windowsize / margins）。
# 用法：bash Tools/shots_m12.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS=/Users/yuki/.hermes/cache/scratch/shots
SUPPORT="$HOME/Library/Application Support/novel-downloader"
ALL=/tmp/fqm-m12-all.log
LOG=/tmp/fqm-m12.log
ERR=/tmp/fqm-m12.err
mkdir -p "$SHOTS" "$SUPPORT"
APP="$HOME/Library/Caches/fqm-derived/Build/Products/Release/FanQieMao.app"
[ -d "$APP" ] || { echo "app not found: $APP（先跑 bash Tools/跑.sh）" >&2; exit 1; }

# —— 窗口列举助手（只按 owner 过滤，拿窗口号给 screencapture -l）——
LW=/tmp/listwin_m12.swift
LWB=/tmp/listwin_m12_bin
cat > "$LW" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var rows: [(Int, Int)] = []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("番茄") || owner.contains("FanQie") else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (b["Width"] as? NSNumber)?.intValue ?? 0
    let height = (b["Height"] as? NSNumber)?.intValue ?? 0
    rows.append((num, width * height))
}
rows.sort { $0.1 > $1.1 }
for r in rows { print(r.0) }
SWIFT
swiftc -O "$LW" -o "$LWB" >/dev/null 2>&1 || true
pick_window() { "$LWB" 2>/dev/null | head -1; }

kill_all() {
  pkill -9 -f "FanQieMao.app/Contents/MacOS" 2>/dev/null; sleep 1
  pkill -9 -f TomatoNovelDownloader 2>/dev/null; sleep 1
}

restore_settings() {
  python3 - "$SUPPORT/settings.json" <<'PY'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data["shortdramaIgnored"] = True
data["shortdramaPrompted"] = True
# 自检中途崩了也不会把用户的下载目录留在测试用的不可写路径上
if str(data.get("downloadDir", "")).startswith("/System/fqm-m12"):
    data["downloadDir"] = os.path.expanduser("~/Downloads")
open(path, "w").write(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
print("settings:", data.get("shortdramaIgnored"), data.get("shortdramaPrompted"))
PY
  defaults write com.yuki.fanqiemao novelPlatform fanqie 2>/dev/null || true
}

echo "############ 预置状态 ############"
kill_all
restore_settings
: > "$ALL"
echo "== 自检前 ps（FlaskQieMao 进程，应为空）=="
ps -Ao pid,command | grep -E "FanQieMao.app/Contents/MacOS|TomatoNovelDownloader" | grep -v grep || echo "  （无）"
TE_BEFORE=$(pgrep -x TextEdit | wc -l | tr -d ' ')
lsappinfo list 2>/dev/null > /tmp/fqm-m12-apps-before.txt || true

echo
echo "############ bash Tools/跑.sh --selftest m12 ############"
: > "$LOG"; : > "$ERR"
# 下载阶段要用同一个已签名 app 启动（LaunchServices）。内核只在「保存」阶段报进度
# （saved_chapters/chapter_total），抓 200 章是为了让保存阶段足够长、能拍到几十个百分点的绿色填充。
open -n "$APP" \
  --env FQM_SELFTEST=m12 --env FQM_SELFTEST_DELAY=3 --env FQM_DOWNLOAD_LIMIT=200 \
  --stdout "$LOG" --stderr "$ERR"
capture() { # capture <marker> <file> <delay>
  local marker="$1" file="$2" delay="$3"
  for _ in $(seq 1 1500); do grep -q "FQM_SELFTEST $marker" "$LOG" 2>/dev/null && break; sleep 0.2; done
  sleep "$delay"
  local wid=""; wid=$(pick_window)
  for _ in $(seq 1 20); do [[ -n "$wid" ]] && break; sleep 1; wid=$(pick_window); done
  if [[ -n "$wid" ]]; then
    screencapture -x -o -l "$wid" "$SHOTS/$file" && echo "  captured $file (window $wid)"
  else
    echo "  !! 没有窗口，未截 $file"
  fi
}
capture "M12 SHOT m12-idle"        m12b-01-idle.png          2
capture "M12 SHOT m12-downloading" m12b-02-downloading.png   0.3
capture "M12 SHOT m12-done"        m12b-03-done-finder.png   2
capture "M12 SHOT m12-deleted"     m12b-04-deleted-back.png  2
capture "M12 SHOT m12-failed"      m12b-05-failed.png        2
for _ in $(seq 1 600); do pgrep -f "FanQieMao.app/Contents/MacOS" >/dev/null || break; sleep 1; done
sleep 1
grep -hE '^FQM_SELFTEST' "$LOG" "$ERR" 2>/dev/null >> "$ALL"

# M12-b 起完成态 = 打开访达（activateFileViewerSelecting），**不再**拉起 .txt 的默认应用，
# 所以没有需要收尾关掉的外部应用；仍打印一次旧行为会打开的默认应用做对照。
OPEN_APP=$(grep -o '默认应用=[^ ]*' "$ALL" | tail -1 | cut -d= -f2)
echo "  （旧行为会打开的默认应用=${OPEN_APP:-?}；M12-b 不再打开它）"

echo
echo "=== M12 自检行 ==="
grep -hE '^FQM_SELFTEST M12' "$ALL" 2>/dev/null

echo
echo "############ 回归 ############"
for mode in chain windowsize margins; do
  echo "---- selftest $mode ----"
  out=$(FQM_DOWNLOAD_LIMIT=3 bash Tools/selftest.sh "$mode" 2>&1)
  echo "$out" | grep -hE '^FQM_SELFTEST|进程残留数' | sed 's/^/  /'
  echo "$out" | grep -hE '^FQM_SELFTEST' >> "$ALL"
done

echo
echo "=== 收尾：settings 还原 + 平台=番茄 + 普通启动 ==="
restore_settings
kill_all
open -n "$APP"
sleep 4
echo -n "  实例数（应 1）: "; pgrep -f "FanQieMao.app/Contents/MacOS" | wc -l | tr -d ' '
echo "  平台=$(defaults read com.yuki.fanqiemao novelPlatform 2>/dev/null || echo -)"
echo "  settings: $(python3 -c "import json;d=json.load(open('$SUPPORT/settings.json'));print('shortdramaIgnored=%s shortdramaPrompted=%s'%(d.get('shortdramaIgnored'),d.get('shortdramaPrompted')))")"
echo
echo "=== 截图 ==="
for f in m12b-01-idle m12b-02-downloading m12b-03-done-finder m12b-04-deleted-back m12b-05-failed; do
  p="$SHOTS/$f.png"
  [[ -f "$p" ]] || { echo "  $p 缺失"; continue; }
  dim=$(sips -g pixelWidth -g pixelHeight "$p" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  echo "  $p  ${dim} $(shasum -a 256 "$p" | cut -c1-16)"
done
echo
echo "=== 源码取证 ==="
echo "-- 榜单框：详情页已无 ShortdramaStrip(...) 调用 --"
grep -n "ShortdramaStrip(" Sources/Features/Detail/BookDetailView.swift || echo "  （详情页已无 ShortdramaStrip(...) 调用 → 榜单框不再渲染）"
grep -n '共 \\(info.chapterCount) 章' Sources/Features/Detail/BookDetailView.swift || true
echo "-- M12-b：完成态 = 文件夹图标 + 打开访达；右侧放大镜按钮 / openDownloadedFile 已删 --"
grep -n 'folderSymbolName\|revealDownloadedFile\|detail-reveal-button\|openDownloadedFile\|doneButtonHelp\|activateFileViewerSelecting' Sources/Features/Detail/BookDetailView.swift
