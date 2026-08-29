#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为存量 app 生成 sync_merge.py（引擎 + 按 spec 定制的 CONFIG）。
用法: python3 gen_sync_merge.py <output_dir>
"""
import json
import os
import sys

TPL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sync_merge.py.tpl")

STATUS_SQL = """SELECT a.hull_number AS hull, a.name AS name, k.status AS status,
       k.date AS status_date, k.according AS according, a.homeport AS homeport
FROM standard.carrier_attribution a
LEFT JOIN standard.kantian_aircraft_carrier_status k
  ON a.hull_number = k.hull_number
 AND k.date = (SELECT MAX(k2.date) FROM standard.kantian_aircraft_carrier_status k2
               WHERE k2.hull_number = a.hull_number)
ORDER BY a.hull_number"""
STRIKE_SQL = ("SELECT carrier_id AS carrier, equipment_id AS eid, equipment_name AS equip, "
              "equipment_category AS cat, carrier_name AS cname "
              "FROM standard.carrier_strike_track ORDER BY equipment_name")
PERSON_SQL = ("SELECT hull_number AS hull, carrier_name AS cname, person_name AS pname, "
              "person_rank AS rank "
              "FROM standard.person_carrier_relation ORDER BY hull_number")
EVENT_SQL = ("SELECT event_date AS d, event_name AS name, location AS loc, event_type AS type "
             "FROM standard.event WHERE carrier_id IS NOT NULL AND event_name IS NOT NULL "
             "ORDER BY event_date DESC LIMIT 50")


def m(table, key, sql, map_, recompute=None, status_col=2, fmt=None):
    d = {"table": table, "key": key, "sql": sql, "map": map_}
    if recompute:
        d["recompute"] = recompute
        d["status_col"] = status_col
    if fmt:
        d["fmt"] = fmt
    return d


APPS = {
    "carrier-global": {
        "port": 20011,
        "merges": [
            m("carrierTable", 0, STATUS_SQL, {0: "hull", 2: "status", 3: "status_date"},
              recompute=["statusBar"]),
            m("strikeTable", 1, STRIKE_SQL, {0: "cat", 1: "equip", 2: "cname"}),
            m("personTable", 2, PERSON_SQL, {0: "hull", 1: "cname", 2: "pname", 3: "rank"}),
        ],
    },
    "carrier-global-v2": {
        "port": 20012,
        "merges": [
            m("carrierTable", 0, STATUS_SQL, {0: "hull", 2: "status", 3: "status_date"},
              recompute=["statusBar"]),
            m("strikeTable", 1, STRIKE_SQL, {0: "cat", 1: "equip", 2: "cname"}),
            m("personTable", 2, PERSON_SQL, {0: "hull", 1: "cname", 2: "pname", 3: "rank"}),
        ],
    },
    "carrier-global-v3": {
        "port": 20013,
        "merges": [
            m("carrierTable", 0, STATUS_SQL, {0: "hull", 2: "status", 3: "status_date"},
              recompute=["statusBar"]),
            m("strikeTable", 1, STRIKE_SQL, {0: "cat", 1: "equip", 2: "cname"}),
            m("personTable", 2, PERSON_SQL, {0: "hull", 1: "cname", 2: "pname", 3: "rank"}),
        ],
    },
    "carrier-global-v4": {
        "port": 20014,
        "merges": [
            m("carrierTable", 0, STATUS_SQL, {0: "hull", 2: "status", 6: "status_date"},
              recompute=["statusBar", "statusPie"]),
            m("strikeTable", 2, STRIKE_SQL, {0: "carrier", 1: "eid", 2: "equip", 3: "cat"}),
            m("personTable", 1, PERSON_SQL, {0: "hull", 1: "pname", 2: "rank", 4: "cname"}),
        ],
    },
    "global-carrier-dashboard": {
        "port": 20015,
        "merges": [
            m("statusTable", 0, STATUS_SQL, {0: "hull", 2: "status", 3: "status_date", 4: "according"},
              recompute=["statusPie"]),
            m("eventTable", 1, EVENT_SQL, {0: "d", 1: "name", 2: "loc", 3: "type"}),
            m("strikeTable", 0, STRIKE_SQL, {0: "equip", 1: "cat", 2: "cname"}),
        ],
    },
    "carrier-status-monitor": {
        "port": 20016,
        "merges": [
            m("statusTable", 0, STATUS_SQL, {0: "hull", 2: "status", 3: "homeport"},
              recompute=["statusPie"]),
            m("strikeTable", 0, STRIKE_SQL, {0: "equip", 1: "cat", 2: "cname"}),
        ],
    },
}


def config_literal(cfg):
    """把 CONFIG 转成 Python 字面量（JSON 可表达部分）。"""
    return json.dumps(cfg, ensure_ascii=False, indent=4)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    tpl = open(TPL, encoding="utf-8").read()
    marker_begin = "# ================= 由 Agent 按业务定制 ================="
    marker_end = "# ======================================================"
    head = tpl.split(marker_begin)[0]
    foot = tpl.split(marker_end, 1)[1]
    for app_id, cfg in APPS.items():
        full = {"app_id": app_id, "port": cfg["port"],
                "merges": cfg["merges"],
                "status_order": ["作战", "演习", "训练", "停泊", "维修", "新建"],
                "status_colors": {
                    "作战": "#ff3b30", "演习": "#ff9500", "训练": "#00a6ff",
                    "停泊": "#ffd93d", "维修": "#8e8e93", "新建": "#00ff88",
                }}
        body = (head + marker_begin + "\nCONFIG = " + config_literal(full)
                + "\n" + marker_end + foot)
        path = os.path.join(out_dir, app_id + "-sync_merge.py")
        open(path, "w", encoding="utf-8").write(body)
        print("generated", path)


if __name__ == "__main__":
    main()
