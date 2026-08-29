#!/usr/bin/env bash
# dagu-gate app_status —— 巡检：app 数量/配额、SQLite 体积、最近同步时间，异常输出 WARN/ERROR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"

python3 - "$DAGU_ROOT" <<'PY'
import json
import os
import sys
import time
import urllib.request
from http.cookiejar import CookieJar

root = sys.argv[1]
users_root = os.path.join(root, "users")
now = time.time()
has_issue = False


def check_spec(uid, port):
    """GET /svc/spec 确认 spec 已入库（空 spec = 页面只有骨架）。"""
    try:
        cj = CookieJar()
        op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
        op.open("http://127.0.0.1:9088/portal/u/%s" % uid, timeout=8)
        r = op.open("http://127.0.0.1:9088/app/%d/svc/spec" % port, timeout=8)
        d = json.loads(r.read().decode("utf-8", "replace"))
        return bool(d.get("spec"))
    except Exception:
        return False

for uid in sorted(os.listdir(users_root)):
    reg = os.path.join(users_root, uid, "workspace", ".apps", "apps.json")
    if not os.path.isfile(reg):
        continue
    try:
        m = json.load(open(reg, encoding="utf-8"))
    except Exception as e:
        print(f"ERROR {uid}: bad registry: {e}")
        has_issue = True
        continue
    apps = m.get("apps", [])
    if len(apps) > 20:
        print(f"WARN {uid}: app count {len(apps)} > 20")
        has_issue = True
    meta = m.get("_meta") or {}
    last = meta.get("lastSync") or 0
    if last and now - last > 12 * 3600:
        print(f"WARN {uid}: last sync stale ({(now - last) / 3600:.1f}h ago)")
        has_issue = True
    for a in apps:
        app_id = a.get("id", "")
        port = a.get("port")
        app_root = os.path.join(users_root, uid, "workspace", ".apps", a.get("id", ""))
        # 必备项：sync 配置 + 脚本存在
        sync = a.get("sync") or {}
        script = sync.get("script", "")
        if not script:
            print(f"ERROR {uid}/{app_id}: 缺 sync 配置（定时刷新必备，需登记 sync.script）")
            has_issue = True
        elif not os.path.isfile(os.path.join(app_root, script)):
            print(f"ERROR {uid}/{app_id}: sync 脚本缺失 {app_root}/{script}")
            has_issue = True
        # 必备项：spec 已入库（页面运行时渲染源）
        if port and not check_spec(uid, port):
            print(f"ERROR {uid}/{app_id}: spec 未入库（页面只有骨架）")
            has_issue = True
        for ver in (a.get("versions") or {}).keys():
            d = os.path.join(app_root, "data-" + ver)
            total = 0
            if os.path.isdir(d):
                total = sum(
                    os.path.getsize(os.path.join(dp, f))
                    for dp, _dn, fn in os.walk(d)
                    for f in fn
                )
            if total > 100 * 1024 * 1024:
                print(f"ERROR {uid}/{a.get('id')}/{ver}: sqlite {total / 1048576:.0f}MB > 100MB")
                has_issue = True
    last_s = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(last)) if last else "never"
    print(f"OK {uid}: apps={len(apps)} lastSync={last_s}")

print("app_monitor: " + ("ISSUES FOUND" if has_issue else "all healthy"))
PY
