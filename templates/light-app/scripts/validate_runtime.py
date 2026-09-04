#!/usr/bin/env python3
# validate_runtime.py — 校验轻应用「运行时模式」交付物（HTML + 侧车 spec）
# 用法: python3 validate_runtime.py <html> <sidecar.spec.json>
# 退出: 0 = OK；1 = 有问题（打印问题清单）
# 说明: 运行时模式 HTML 不含内联 spec（页面加载时 fetch /svc/spec 渲染），
#       因此不能用同事的 validate_html.py（仅支持内联 spec 静态页）做校验；
#       本脚本检查：侧车 spec 完整性 + 运行时标记 + 无外网引用。
import json
import os
import re
import sys


def check_chart_data_nonempty(spec, problems):
    """空数据图禁止上屏：map 需有 markers/circles/lines；bar/line/pie/scatter/radar 数组非空。"""
    charts = spec.get("charts") or []
    for c in charts:
        cid = c.get("id") or "?"
        ctype = c.get("type") or "?"
        d = c.get("data") or {}

        def _list(x):
            return x if isinstance(x, list) else []

        reason = None
        if ctype == "map":
            # 兼容两种形态：数据放 chart 级（schema 约定）或 data 内
            have = (
                len(_list(c.get("markers"))) + len(_list(c.get("circles"))) + len(_list(c.get("lines")))
                or len(_list(d.get("markers"))) + len(_list(d.get("circles"))) + len(_list(d.get("lines")))
            )
            if not have:
                reason = "map 无任何 markers/circles/lines"
        elif ctype in ("bar", "line"):
            cats, vals = _list(d.get("categories")), _list(d.get("values"))
            if not cats or not vals:
                reason = "bar/line 缺 data.categories/data.values"
            elif any(isinstance(v, list) and len(v) == 0 for v in vals):
                reason = "bar/line 存在空序列（data.values 中有空数组）"
        elif ctype == "pie":
            if not _list(d.get("values")):
                reason = "pie data.values 为空"
        elif ctype == "scatter":
            if not _list(d.get("values")):
                reason = "scatter data.values 为空"
        elif ctype == "radar":
            if not _list(d.get("categories")) or not _list(d.get("values")):
                reason = "radar 缺 data.categories/data.values"
        if reason:
            problems.append(
                "chart %s (type=%s) 数据为空：%s —— 空数据图禁止上屏；"
                "请删除该图，或用文字/表格明确写『暂无数据』" % (cid, ctype, reason)
            )


def main():
    if len(sys.argv) != 3:
        print("usage: python3 validate_runtime.py <index.html> <sidecar.spec.json>")
        return 1
    html_path, spec_path = sys.argv[1], sys.argv[2]
    problems = []

    # ---- 侧车 spec ----
    spec = None
    if not os.path.isfile(spec_path):
        problems.append("侧车 spec 缺失: %s" % spec_path)
    else:
        try:
            with open(spec_path, encoding="utf-8") as fh:
                spec = json.load(fh)
        except Exception as e:
            problems.append("侧车 spec 解析失败: %s" % e)
    if spec is not None:
        for key in ("name", "title", "kpis", "charts", "rows"):
            if key not in spec:
                problems.append("spec 缺少字段: %s" % key)
        if isinstance(spec.get("kpis"), list) and not spec["kpis"]:
            problems.append("spec.kpis 为空")
        if isinstance(spec.get("charts"), list) and not spec["charts"]:
            problems.append("spec.charts 为空")
        if not isinstance(spec.get("rows"), list) or not spec["rows"]:
            problems.append("spec.rows 为空")
        check_chart_data_nonempty(spec, problems)

    # ---- 运行时 HTML ----
    html = ""
    if not os.path.isfile(html_path):
        problems.append("HTML 缺失: %s" % html_path)
    else:
        try:
            with open(html_path, encoding="utf-8") as fh:
                html = fh.read()
        except Exception as e:
            problems.append("HTML 读取失败: %s" % e)
    if html:
        # 运行时引导脚本里也有 window.DASHBOARD_SPEC = d.spec（fetch 后赋值），
        # 只有静态内联 spec（等号后直接跟 JSON 对象 {）才算“写死”。
        if re.search(r"window\.DASHBOARD_SPEC\s*=\s*\{", html):
            problems.append("HTML 内联了 DASHBOARD_SPEC（应为运行时模式，spec 走 /svc/spec）")
        if "lib/" not in html:
            problems.append("未发现 lib/ 相对资源引用（应用 LIB_BASE=lib/ 构建）")
        # 运行时引导用 BASE + 'svc/spec' 动态拼 URL（BASE 来自 location.pathname），
        # 静态 HTML 中不出现字面量斜杠前缀，因此只匹配 "svc/spec" / "svc/events"。
        if "svc/spec" not in html:
            problems.append("HTML 未发现 svc/spec 运行时拉取引用")
        if "svc/events" not in html:
            problems.append("HTML 未发现 svc/events（SSE）订阅引用")
        allowed = ("http://lib", "http://files", "http://internal")
        for m in re.findall(r"https?://[^\"')\s]+", html):
            if not m.startswith(allowed):
                problems.append("发现外部 URL 引用: %s" % m)

    if problems:
        print("[ERROR] validate_runtime: %s" % html_path)
        for p in problems:
            print("  - " + p)
        return 1
    rows = len(spec.get("rows", [])) if spec else 0
    print("OK %s (runtime-mode, rows=%d, 无外网引用)" % (html_path, rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
