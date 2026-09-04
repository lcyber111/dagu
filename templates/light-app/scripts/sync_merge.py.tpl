#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sync_merge.py —— 大屏定时数据同步（快照合并）引擎模板

每个轻应用必备：Agent 生成大屏时复制本模板为 .apps/<appId>/sync_merge.py，
并填写 CONFIG（查询 SQL、合并表、key 列、联动图表），在 apps.json 登记
"sync": {"script": "sync_merge.py"}。app_sync_data DAG 到点执行本脚本。

约定（快照唯一数据源）：
  1) GET /app/<port>/svc/spec 取当前 spec；
  2) 对每个 merge 配置查上游库（db_query.py）；
  3) 按 key 合并：新数据覆盖它有的行，缺失旧行原样保留（避免数据不全导致大屏残缺）；
  4) 可选：从合并后的表重算联动图表（如状态分布）；
  5) 写 spec["sync_at"] 时间戳；
  6) POST /app/<port>/svc/spec 写回 → SSE 广播 → 页面无刷新重绘。
"""
import json
import os
import subprocess
import time
import urllib.request
from http.cookiejar import CookieJar


# ================= 由 Agent 按业务定制 =================
CONFIG = {
    "app_id": "APP_ID",
    "port": 20000,
    "merges": [
        # {
        #     "table": "carrierTable",          # spec.tables 中要合并的表 id
        #     "key": 0,                          # 行内 key 列下标（如 0=舷号）
        #     "sql": "SELECT ...",               # 查询（结果列名与 map 对应）
        #     "map": {0: "hull", 1: "name", 2: "status"},  # spec 列下标 -> 查询列名
        #     "fmt": {2: lambda r: str(r["status"])},       # 可选：值格式化
        #     "recompute": ["statusBar", "statusPie"],      # 从该表重算的图表 id
        #     "status_col": 2,                   # 重算图表用的状态列下标
        # },
    ],
    "status_order": ["作战", "演习", "训练", "停泊", "维修", "新建"],
    "status_colors": {
        "作战": "#ff3b30", "演习": "#ff9500", "训练": "#00a6ff",
        "停泊": "#ffd93d", "维修": "#8e8e93", "新建": "#00ff88",
    },
}
# ======================================================


def resolve_server_config():
    # 平台注入的网关配置优先：容器内 API 用 internalBaseUrl（caddy-gateway 可达），
    # agents_gen/config/server.json 是旧 serve_html 静态配置（可能指向公网/错误机器），仅作回退。
    gw_path = "/workspace/.platform/gateway.json"
    if os.path.isfile(gw_path):
        return json.load(open(gw_path, encoding="utf-8"))
    for p in ("config/server.json",
              "/workspace/version0802/agents_gen/config/server.json",
              "/workspace/config/server.json"):
        if os.path.isfile(p):
            return json.load(open(p, encoding="utf-8"))
    raise SystemExit("ERROR: gateway.json / config/server.json not found")


def api_opener(cfg):
    gw = (cfg.get("internalBaseUrl") or cfg.get("baseUrl")).rstrip("/")
    uid = os.environ.get("WS_USER") or cfg.get("uid")
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
    opener.open(gw + "/portal/u/" + uid, timeout=10)
    return opener, gw


def db_query(sql):
    dbq = "/workspace/version0802/agents_gen/scripts/db_query.py"
    r = subprocess.run(
        ["python3", dbq, "--source", "doris", "--sql", sql, "--limit", "5000"],
        capture_output=True, text=True, timeout=120)
    res = {}
    try:
        res = json.loads(r.stdout or "{}")
    except Exception:
        pass
    if r.returncode != 0 or not res.get("ok"):
        raise RuntimeError("db_query failed: %s"
                           % (res.get("error") or r.stderr[-300:] or r.stdout[:300]))
    cols = res.get("columns", [])
    return [dict(zip(cols, row)) for row in res.get("rows", [])]


def merge_rows(old_rows, new_rows, key_idx, mapped_cols):
    """按 key 单元格合并（部分数据安全）：
    - 只更新已存在行的 mapped 列（新值非 None 时覆盖）；
    - 未映射的列保持旧值；新数据里没有的旧行保持原样；
    - spec 里不存在的新 key 不新增（布局生成时已定稿）。"""
    by_key = {row[key_idx]: row for row in old_rows}
    updated = 0
    for nr in new_rows:
        key = nr[key_idx]
        if key not in by_key:
            continue
        row = by_key[key]
        for spec_idx in mapped_cols:
            val = nr[spec_idx]
            if val is None:
                continue
            # 值类型强转：dict/list 等复杂值转 JSON 字符串，避免页面显示 [object Object]
            if not isinstance(val, (str, int, float, bool)):
                val = json.dumps(val, ensure_ascii=False)
            row[spec_idx] = val
            updated += 1
    return old_rows, updated


def recompute_status_charts(spec, rows, status_col):
    from collections import Counter
    cfg = CONFIG
    # 值类型强转：避免 dict/list 等不可哈希值让 Counter 崩溃（坏数据防护）
    cnt = Counter(str(r[status_col]) for r in rows)
    cats = [s for s in cfg["status_order"] if cnt.get(s)]
    vals = [cnt.get(s, 0) for s in cats]
    unknown = sum(v for k, v in cnt.items() if k not in cfg["status_order"])
    if unknown:
        cats.append("其他")
        vals.append(unknown)
    colors = [cfg["status_colors"].get(s, "#8e8e93") for s in cats]
    for cs in spec.get("charts", []):
        if cs.get("id") == "statusBar" and cs.get("data") is not None:
            cs["data"]["categories"] = cats
            cs["data"]["values"] = vals
            cs["data"]["colors"] = colors
        if cs.get("id") == "statusPie" and cs.get("data") is not None:
            cs["data"]["values"] = [
                {"name": s, "value": vals[i],
                 "color": cfg["status_colors"].get(s, "#8e8e93")} for i, s in enumerate(cats)]


def main():
    cfg = resolve_server_config()
    opener, gw = api_opener(cfg)
    base = "%s/app/%d" % (gw, CONFIG["port"])

    cur = json.load(opener.open(base + "/svc/spec", timeout=10))
    spec = cur.get("spec")
    if not spec:
        raise SystemExit("ERROR: no spec in db (请先生成并 POST spec)")

    for m in CONFIG["merges"]:
        rows = db_query(m["sql"])
        if not rows:
            print("skip %s: 查询为空（保留现有数据）" % m["table"])
            continue
        # CONFIG 经 JSON 序列化后 map/fmt 的 key 为字符串，统一转 int
        spec_map = {int(k): v for k, v in m["map"].items()}
        fmt = {int(k): v for k, v in (m.get("fmt") or {}).items()}
        key_idx = int(m["key"])
        new_rows = []
        for r in rows:
            row = [None] * (max(spec_map.keys()) + 1)
            for spec_idx, col in spec_map.items():
                val = r.get(col)
                if spec_idx in fmt:
                    val = fmt[spec_idx](r)
                # 值类型强转：dict/list 等复杂值转 JSON 字符串，避免页面显示 [object Object]
                if val is not None and not isinstance(val, (str, int, float, bool)):
                    val = json.dumps(val, ensure_ascii=False)
                row[spec_idx] = val
            new_rows.append(row)
        for t in spec.get("tables", []):
            if t.get("id") == m["table"]:
                old = t.get("rows", [])
                t["rows"], updated = merge_rows(
                    old, new_rows, key_idx, list(spec_map.keys()))
                print("merged %s: 行数 %d（不变），更新单元格 %d（新查询 %d 行）"
                      % (m["table"], len(t["rows"]), updated, len(new_rows)))
                if m.get("recompute"):
                    recompute_status_charts(spec, t["rows"], m.get("status_col", 2))

    spec["sync_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    req = urllib.request.Request(
        base + "/svc/spec", data=json.dumps({"spec": spec}).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    r = json.load(opener.open(req, timeout=20))
    print("sync_merge OK %s sync_at=%s title=%s"
          % (CONFIG["app_id"], spec["sync_at"], (r.get("spec") or {}).get("title")))


if __name__ == "__main__":
    main()
