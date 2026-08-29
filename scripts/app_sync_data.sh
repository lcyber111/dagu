#!/usr/bin/env bash
# dagu-gate app_sync_data —— 定时数据同步（快照合并模式）
#
# 每个 app 在 apps.json 里声明 sync 配置（agent 生成时写入）：
#   "sync": {"script": "sync_merge.py"}
# sync_merge.py 位于 .apps/<appId>/，在用户容器内执行（容器有 DB 驱动与 db_query.py）：
#   1) GET /app/<port>/svc/spec 取当前 spec（快照，唯一数据源）；
#   2) 查上游库（db_query.py）；
#   3) 按 app 自身合并规则（key 合并，旧数据保留）生成新 spec；
#   4) POST /app/<port>/svc/spec 写回（SSE 广播 → 页面实时重绘）。
# 平台只负责"到点执行 + 汇报 + 记录 lastSync"，合并逻辑归各 app。
#
# 旧格式 sync: {db, sql}（写 items 多行）已废弃：不兼容即告警跳过。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"

SCOPE_UID=""
if [ -n "${WEBHOOK_PAYLOAD:-}" ]; then
  SCOPE_UID="$(python3 -c 'import json,sys
p=json.loads(sys.argv[1]); p=p.get("payload",p); print(p.get("uid",""))' "$WEBHOOK_PAYLOAD")"
  echo "app_sync_data: scope uid=$SCOPE_UID"
fi

python3 - "$DAGU_ROOT" "$SCOPE_UID" <<'PY'
import json
import os
import subprocess
import sys
import time

root, scope_uid = sys.argv[1], sys.argv[2]
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
        sync = app.get("sync")
        if not sync:
            print(f"ERROR {uid}/{app_id}: 缺少 sync 配置（定时刷新必备，请生成 sync_merge.py 并登记 sync.script）")
            continue
        if sync.get("db") or sync.get("sql"):
            print(f"SKIP {uid}/{app_id}: 旧版 sync{{db,sql}} 已废弃，请迁移为 sync.script（快照合并脚本）")
            continue
        script = sync.get("script", "")
        if not script:
            print(f"SKIP {uid}/{app_id}: sync.script empty")
            continue
        script_path = os.path.join(users_root, uid, "workspace", ".apps", app_id, script)
        if not os.path.isfile(script_path):
            print(f"ERROR {uid}/{app_id}: merge script missing {script_path}")
            continue
        print(f"SYNC {uid}/{app_id} script={script}")
        # 容器内执行：/workspace 与宿主机同源挂载
        cmd = [
            "docker", "exec", f"dagu-u-{uid}", "python3",
            f"/workspace/.apps/{app_id}/{script}",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        except Exception as e:
            print(f"ERROR {uid}/{app_id}: exec failed: {e}")
            continue
        if out.returncode != 0:
            print(f"ERROR {uid}/{app_id}: script failed rc={out.returncode}: {out.stdout[-300:]} {out.stderr[-300:]}")
            continue
        print(f"OK {uid}/{app_id}: {out.stdout.strip()[-200:]}")
        meta = manifest.get("_meta") or {}
        meta["lastSync"] = time.time()
        manifest["_meta"] = meta
        json.dump(manifest, open(reg, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
