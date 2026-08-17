#!/usr/bin/env bash
# dagu-gate: stop user containers idle longer than IDLE_TIMEOUT_MINUTES.
#
# "Last activity" is the most recent proxied request timestamp found in the
# Caddy JSON access log (field "uid" appended by Caddy log_append). Containers
# without any logged activity fall back to their creation time (docker inspect
# .Created), which gives newly created containers a grace period. Only running
# dagu-u-* containers are considered, and the log is re-read right before
# stopping to avoid racing a request that just arrived.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_GATE_ROOT="${DAGU_GATE_ROOT:-$(dirname "$SCRIPT_DIR")}"

# ---- python3: system interpreter first, bundled portable runtime fallback ----
PYTHON3="${PYTHON3:-}"
if [ -z "$PYTHON3" ] && command -v python3 >/dev/null 2>&1; then
  PYTHON3="$(command -v python3)"
fi
if [ -z "$PYTHON3" ] && [ -x "$DAGU_GATE_ROOT/python/bin/python3" ]; then
  PYTHON3="$DAGU_GATE_ROOT/python/bin/python3"
fi
if [ -z "$PYTHON3" ]; then
  echo "ERROR: python3 not found (install python3 or keep dist/python-linux-x86_64.tar.gz in the package)" >&2
  exit 1
fi

ACTIVITY_LOG="${ACTIVITY_LOG:-$DAGU_GATE_ROOT/logs/access.log}"
IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-360}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"

# Collect running user containers with their creation timestamps (unix sec).
CONTAINER_TS=""
for name in $(docker ps --format '{{.Names}}' | grep '^dagu-u-' || true); do
  created="$(docker inspect --format '{{.Created}}' "$name" 2>/dev/null || true)"
  [ -z "$created" ] && continue
  ts="$(date -d "$created" +%s 2>/dev/null || true)"
  [ -z "$ts" ] && continue
  CONTAINER_TS="$CONTAINER_TS $name $ts"
done

if [ -z "$CONTAINER_TS" ]; then
  echo "reap_idle: no user containers running"
  exit 0
fi

STOP_LIST=$("$PYTHON3" - "$ACTIVITY_LOG" "$IDLE_TIMEOUT_MINUTES" $CONTAINER_TS <<'PYEOF'
import json
import re
import sys
import time

log_path = sys.argv[1]
timeout_sec = int(sys.argv[2]) * 60
args = sys.argv[3:]
created_by_name = {args[i]: int(args[i + 1]) for i in range(0, len(args), 2)}

def read_activity():
    last = {}
    try:
        with open(log_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                uid = rec.get("uid") or ""
                if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", uid):
                    continue
                ts = rec.get("ts")
                if isinstance(ts, (int, float)):
                    last[uid] = max(last.get(uid, 0), int(ts))
    except FileNotFoundError:
        pass
    return last

def is_idle(name, activity, now):
    uid = name[len("dagu-u-"):]
    last = max(activity.get(uid, 0), created_by_name[name])
    # >= 而不是 >：日志 ts 与当前时间可能落在同一秒，int() 截断后差值为 0，
    # 用 > 会把刚有活动的容器误判为"未空闲"（0 > 0 为假）。
    return now - last >= timeout_sec

activity = read_activity()
now = int(time.time())
candidates = [name for name in created_by_name if is_idle(name, activity, now)]

# Second look: skip containers whose activity changed while we were deciding.
if candidates:
    activity = read_activity()
    now = int(time.time())
    candidates = [name for name in candidates if is_idle(name, activity, now)]

for name in candidates:
    print(name)
PYEOF
)

COUNT=0
for name in $STOP_LIST; do
  echo "reap_idle: stopping $name (idle > ${IDLE_TIMEOUT_MINUTES}m)"
  docker stop -t "$STOP_TIMEOUT" "$name" >/dev/null
  COUNT=$((COUNT + 1))
done
echo "reap_idle: done, stopped $COUNT container(s)"
