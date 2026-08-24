#!/usr/bin/env bash
# dagu-gate app_select —— 记录"用户当前选中的生成物"标记（供 agent 感知上下文）
# 写 users/<uid>/workspace/.apps/.selected = {"id","ts"}
# 入参：WEBHOOK_PAYLOAD={"payload":{"uid":"...","appId":"..."}}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"

if [ -z "${WEBHOOK_PAYLOAD:-}" ]; then
  echo "ERROR: WEBHOOK_PAYLOAD empty" >&2
  exit 1
fi

eval "$(python3 - "$WEBHOOK_PAYLOAD" <<'PY'
import json
import shlex
import sys

p = json.loads(sys.argv[1])
p = p.get("payload", p)
print("UID_VAL=%s" % shlex.quote(str(p.get("uid", ""))))
print("APP_ID=%s" % shlex.quote(str(p.get("appId", ""))))
PY
)"

[[ "$UID_VAL" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "ERROR: invalid uid" >&2; exit 2; }
[[ "$APP_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "ERROR: invalid appId" >&2; exit 2; }

DOT_DIR="$DAGU_ROOT/users/$UID_VAL/workspace/.apps"
REG="$DOT_DIR/apps.json"
[ -f "$REG" ] || { echo "ERROR: no registry" >&2; exit 1; }

python3 - "$REG" "$APP_ID" <<'PY'
import json
import sys

reg, app_id = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
found = [a for a in d.get("apps", []) if a.get("id") == app_id]
if not found:
    print("app not found")
    sys.exit(1)
PY

cat > "$DOT_DIR/.selected" <<EOF
{"id": "$APP_ID", "ts": $(date +%s)}
EOF
echo "app_select: selected=$APP_ID (uid=$UID_VAL)"
