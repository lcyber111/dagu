#!/usr/bin/env bash
# dagu-gate app_delete —— 从注册表摘除并归档一个 app，然后重建 workerd 配置
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

REG="$DAGU_ROOT/users/$UID_VAL/workspace/.apps/apps.json"
APP_DIR="$DAGU_ROOT/users/$UID_VAL/workspace/.apps/$APP_ID"
[ -f "$REG" ] || { echo "ERROR: no registry" >&2; exit 1; }
[ -d "$APP_DIR" ] || { echo "ERROR: app dir missing" >&2; exit 1; }

python3 - "$REG" "$APP_ID" <<'PY'
import json
import sys

reg, app_id = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
before = len(d.get("apps", []))
d["apps"] = [a for a in d.get("apps", []) if a.get("id") != app_id]
if len(d["apps"]) == before:
    print("app not found in registry")
    sys.exit(1)
json.dump(d, open(reg, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("removed from registry")
PY

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DAGU_ROOT/archive/apps"
mv "$APP_DIR" "$DAGU_ROOT/archive/apps/$UID_VAL-$APP_ID-$STAMP"
echo "app_delete: archived to archive/apps/$UID_VAL-$APP_ID-$STAMP"

DAGU_ROOT="$DAGU_ROOT" bash "$SCRIPT_DIR/app_sync.sh"
