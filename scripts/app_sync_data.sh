#!/usr/bin/env bash
# dagu-gate app_sync_data —— 定时同步：按每个 app 的 sync 配置（db + sql）查上游库，
# 经网关 /api/v1/apps/<appId>/refresh 写回 App SQLite（分钟级实时）。
#
# 由 dagu 定时 DAG（app_sync_data）触发；支持 WEBHOOK_PAYLOAD 范围（{"payload":{"uid":...}}）。
# 查询在用户容器内执行（容器有 DB 驱动与 db_sources.json），宿主无需安装驱动。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"
GATEWAY="${GATEWAY:-http://127.0.0.1:9090}"

SCOPE_UID=""
if [ -n "${WEBHOOK_PAYLOAD:-}" ]; then
  SCOPE_UID="$(python3 -c 'import json,sys
p=json.loads(sys.argv[1]); p=p.get("payload",p); print(p.get("uid",""))' "$WEBHOOK_PAYLOAD")"
  echo "app_sync_data: scope uid=$SCOPE_UID"
fi

python3 - "$DAGU_ROOT" "$GATEWAY" "$SCOPE_UID" <<'PY'
import json
import hashlib
import os
import subprocess
import sys
import time
import urllib.request

root, gateway, scope_uid = sys.argv[1], sys.argv[2], sys.argv[3]
users_root = os.path.join(root, "users")

for uid in sorted(os.listdir(users_root)):
    if scope_uid and uid != scope_uid:
        continue
    reg = os.path.join(users_root, uid, "workspace", ".apps", "apps.json")
    if not os.path.isfile(reg):
        continue
    try:
        manifest = json.load(open(reg, encoding="utf-8"))
    except Exception as e:
        print(f"WARN: bad registry {reg}: {e}")
        continue
    for app in manifest.get("apps", []):
        app_id = app.get("id")
        version = app.get("defaultVersion")
        v = (app.get("versions") or {}).get(version) or {}
        sync = v.get("sync") or app.get("sync")
        if not sync:
            continue
        # per-app token（M3）：版本开启 token 时派生并随 refresh 提交
        app_token = ""
        tok = v.get("token")
        if tok is True:
            secret_file = os.path.join(root, ".apps-secret")
            if os.path.isfile(secret_file):
                secret = open(secret_file, encoding="utf-8").read().strip()
                unique_key = "app-%s-%s-%s" % (uid, app_id, version)
                app_token = hashlib.sha256((secret + "|" + unique_key).encode()).hexdigest()[:32]
        elif isinstance(tok, str) and tok:
            app_token = tok
        sql = sync.get("sql", "")
        db = sync.get("db", "doris")
        if not sql:
            print(f"SKIP {uid}/{app_id}: sync.sql empty")
            continue
        print(f"SYNC {uid}/{app_id} v{version} db={db}")
        cmd = [
            "docker", "exec", f"dagu-u-{uid}", "python3",
            "/workspace/version0802/agents_gen/scripts/db_query.py",
            "--source", db, "--sql", sql, "--limit", "5000",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except Exception as e:
            print(f"ERROR {uid}/{app_id}: query exec failed: {e}")
            continue
        try:
            res = json.loads(out.stdout)
        except Exception:
            print(f"ERROR {uid}/{app_id}: bad db_query output: {out.stdout[:200]}")
            continue
        if not res.get("ok"):
            print(f"ERROR {uid}/{app_id}: db_query not ok: {out.stdout[:200]}")
            continue
        items = [dict(zip(res.get("columns", []), row)) for row in res.get("rows", [])]
        body = json.dumps({"items": items}).encode()
        url = f"{gateway}/api/v1/apps/{app_id}/refresh"
        hdrs = {"Content-Type": "application/json", "Cookie": f"ws_user={uid}"}
        if app_token:
            hdrs["X-App-Token"] = app_token
        req = urllib.request.Request(url, data=body, headers=hdrs, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                print(f"OK {uid}/{app_id}: refresh status={r.status} rows={len(items)}")
                # 记录最后同步时间（供 app_status 巡检）
                meta = manifest.get("_meta") or {}
                meta["lastSync"] = time.time()
                manifest["_meta"] = meta
                json.dump(manifest, open(reg, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        except Exception as e:
            print(f"ERROR {uid}/{app_id}: refresh failed: {e}")
PY
