#!/usr/bin/env bash
# dagu-gate app_apply —— 把修改应用到"当前选中"的生成物（平台强制目标，agent 不能自选）
# 入参：WEBHOOK_PAYLOAD={"payload":{"uid":"...","appId":"...","mode":"www|meta","title":"...","description":"..."}}
#   mode=www : 把用户工作区 temp/modify-www.html 应用到 .apps/<appId>/www/index.html
#   mode=meta: 更新 apps.json 的 title/description（含 versions.<defaultVersion>.title）
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
print("MODE=%s" % shlex.quote(str(p.get("mode", ""))))
print("TITLE=%s" % shlex.quote(str(p.get("title", ""))))
print("DESC=%s" % shlex.quote(str(p.get("description", ""))))
PY
)"

[[ "$UID_VAL" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "ERROR: invalid uid" >&2; exit 2; }
[[ "$APP_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "ERROR: invalid appId" >&2; exit 2; }
if [ "$MODE" != "www" ] && [ "$MODE" != "meta" ]; then
  echo "ERROR: invalid mode=$MODE" >&2
  exit 2
fi

APP_DIR="$DAGU_ROOT/users/$UID_VAL/workspace/.apps/$APP_ID"
[ -d "$APP_DIR" ] || { echo "ERROR: app dir missing $APP_ID" >&2; exit 1; }

if [ "$MODE" = "www" ]; then
  SRC="$DAGU_ROOT/users/$UID_VAL/workspace/version0802/agents_gen/temp/modify-www.html"
  [ -f "$SRC" ] || { echo "ERROR: staged file missing $SRC" >&2; exit 1; }
  cp "$SRC" "$APP_DIR/www/index.html"
  chown "$(id -u):$(id -g)" "$APP_DIR/www/index.html"
  echo "app_apply: www applied to $APP_ID (uid=$UID_VAL)"
  exit 0
fi

# mode=meta
python3 - "$DAGU_ROOT/users/$UID_VAL/workspace/.apps/apps.json" "$APP_ID" "$TITLE" "$DESC" <<'PY'
import json
import sys

reg, app_id, title, desc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(reg, encoding="utf-8"))
found = None
for a in d.get("apps", []):
    if a.get("id") == app_id:
        found = a
        break
if found is None:
    print("app not found: %s" % app_id)
    sys.exit(1)
if title:
    found["title"] = title
    for v in (found.get("versions") or {}).values():
        v["title"] = title
if desc:
    found["description"] = desc
json.dump(d, open(reg, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("app_apply: meta applied to %s" % app_id)
PY
