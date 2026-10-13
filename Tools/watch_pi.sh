#!/usr/bin/env bash
# 盯 pi(fqm-m1)：连续 3 次非 working 视为交回。用法：bash Tools/watch_pi.sh [pane]
export PATH=/opt/homebrew/bin:$HOME/go/bin:$PATH
PANE="${1:-w1:p19}"
seen=0; calm=0
for i in $(seq 1 360); do
  sleep 20
  st=$(herdr agent get "$PANE" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    a = (d.get('result', d) or {}).get('agent', {})
    print(a.get('agent_status') or 'gone')
except Exception:
    print('gone')")
  if [ "$st" = "working" ]; then seen=1; calm=0; else calm=$((calm + 1)); fi
  if [ "$seen" = "1" ] && [ "$calm" -ge 3 ]; then
    echo "pi $PANE 已交回：连续 3 次非 working（状态 $st），等待约 $((i * 20))s"
    exit 0
  fi
done
echo "pi $PANE 仍在 working（已盯 2 小时）"
