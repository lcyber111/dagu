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
DOT_DIR="$DAGU_ROOT/users/$UID_VAL/workspace/.apps"
[ -f "$REG" ] || { echo "ERROR: no registry" >&2; exit 1; }

# 幂等删除：registry 中已无该 app 也视为成功（重复点击/重试不再被 dagu 记为 failed）
RESULT="$(python3 - "$REG" "$APP_ID" <<'PY'
import json
import sys

reg, app_id = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
before = len(d.get("apps", []))
d["apps"] = [a for a in d.get("apps", []) if a.get("id") != app_id]
if len(d["apps"]) == before:
    print("already-deleted")
else:
    json.dump(d, open(reg, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("removed")
PY
)"
echo "app_delete: registry=$RESULT"

# 清理 .selected：删除的正是当前选中项时，避免悬空指向已删 app
python3 - "$DOT_DIR/.selected" "$APP_ID" <<'PY'
import json
import os
import sys

sel_path, app_id = sys.argv[1], sys.argv[2]
if not os.path.isfile(sel_path):
    sys.exit(0)
try:
    with open(sel_path, encoding="utf-8") as f:
        sel = json.load(f)
except Exception:
    sys.exit(0)
if sel.get("id") == app_id:
    os.remove(sel_path)
    print("app_delete: cleared .selected")
PY

# 归档（目录可能已被上次删除归档，幂等容错）
if [ -d "$APP_DIR" ]; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$DAGU_ROOT/archive/apps"
  mv "$APP_DIR" "$DAGU_ROOT/archive/apps/$UID_VAL-$APP_ID-$STAMP"
  echo "app_delete: archived to archive/apps/$UID_VAL-$APP_ID-$STAMP"
else
  echo "app_delete: app dir already gone"
fi

# 重建 workerd 配置（app_sync 内容无变化时不重写，避免无谓热重载）
DAGU_ROOT="$DAGU_ROOT" bash "$SCRIPT_DIR/app_sync.sh"
