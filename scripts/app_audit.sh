#!/usr/bin/env bash
# dagu-gate app_audit —— 从 Caddy 访问日志增量提取 App Worker 生命周期操作，汇总审计日志
# 记录：发布(apps/sync)、修改大屏(apps/apply/spec)、选中(apps/select)、删除(apps/delete)、
#       直接 webhook(app_sync/app_delete)。
# 增量标记：logs/.app-audit.offset（处理到的字节偏移）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"
ACCESS_LOG="${ACCESS_LOG:-$DAGU_ROOT/logs/access.log}"
AUDIT_LOG="${AUDIT_LOG:-$DAGU_ROOT/logs/app-audit.log}"
MARKER="$DAGU_ROOT/logs/.app-audit.offset"

mkdir -p "$(dirname "$AUDIT_LOG")"
touch "$ACCESS_LOG" "$AUDIT_LOG" "$MARKER"

OFFSET=$(cat "$MARKER" 2>/dev/null || true)
OFFSET=${OFFSET:-0}
SIZE=$(wc -c < "$ACCESS_LOG" | tr -d ' ')
SIZE=${SIZE:-0}
if [ "$SIZE" -lt "$OFFSET" ]; then
  # 日志轮转：重置偏移
  OFFSET=0
fi
if [ "$SIZE" -eq "$OFFSET" ]; then
  echo "app_audit: no new lines"
  exit 0
fi

tail -c +$((OFFSET + 1)) "$ACCESS_LOG" > /tmp/app-audit.new
echo "$SIZE" > "$MARKER"

python3 - "$AUDIT_LOG" <<'PY'
import json
import re
import sys

OPS = re.compile(
    r"^/app/v1/(list|sync|select|delete|apply/spec)$"
)

lines = []
for line in open("/tmp/app-audit.new", encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    uri = d.get("request", {}).get("uri", "")
    if not OPS.match(uri):
        continue
    ts = d.get("ts")
    uid = d.get("uid", "")
    method = d.get("request", {}).get("method", "")
    status = d.get("status")
    lines.append(f"{ts}\t{uid}\t{method}\t{uri}\t{status}")

if lines:
    with open(sys.argv[1], "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"app_audit: appended {len(lines)} lines")
else:
    print("app_audit: no app operations in new lines")
PY
