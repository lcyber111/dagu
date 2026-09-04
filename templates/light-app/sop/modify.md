# 修改现有大屏（门户联动，强制第一步）

用户提出"修改/调整/更新/改这个卡片/改这个大屏"时，**第一步必须先确认目标 app**：

1. 读 `/workspace/.apps/.selected`（JSON：`{"id": "<appId>", "ts": ...}`）——这是门户当前选中的生成物
2. 若用户明确点名其他 app → **先把 `.selected` 写为目标 app**（`{"id": "<appId>", "ts": <当前秒>}`），再继续；未点名 → 目标即 `.selected`；`.selected` 缺失 → 读 `apps.json` 列候选请用户确认，**禁止猜测**
3. **动手前先在回复中明示目标**（如"将修改 `carrier-global-v4` 的标题为 Test"），用户可据此判断是否正确
4. **禁止直接编辑 `/workspace/.apps/<appId>/`**。修改必须经平台接口，目标由平台按 `.selected` 强制（agent 传参无效）：
   - **大屏内容（布局/数据/标题，统一走 spec）**：HTML 骨架生成时已定稿，后续修改只改 spec 值。
     把修改后的完整 spec JSON 写入 `/workspace/light-app-work/modify-spec.json`，调用
     `POST /app/v1/apply/spec`（body 直接传 spec 对象或 `{"spec": ...}`；平台按 `.selected`
     强制目标 app，结构校验后写 SQLite + SSE 广播，已打开的页面自动重绘，无需刷新）。
     **改 spec 即生效，无需重建 HTML**：`dashboard.js` 按 spec 幂等重建 KPI/表格/图表，
     静态 HTML 只是首屏骨架。验证时看浏览器渲染后的 DOM（KPI 卡数量、表格行数），
     不要看 HTML 源码（源码骨架不实时反映 spec）。
   - **只改标题/简介**：同样走 `POST /app/v1/apply/spec`（改 `spec.title` / `spec.subtitle`），
     门户卡片标题从 spec 读取（单一来源）
   - 发布接口示例：
     ```python
     python3 - <<'PY'
     import json, os, urllib.request
     def _gw():
         try:
             g = json.load(open("/workspace/.platform/gateway.json", encoding="utf-8"))
             return (g.get("internalBaseUrl") or g.get("baseUrl")).rstrip("/")
         except Exception:
             return (os.environ.get("GATEWAY_INTERNAL_BASE_URL")
                     or os.environ.get("GATEWAY_PUBLIC_BASE_URL")
                     or json.load(open("config/server.json", encoding="utf-8"))["baseUrl"]).rstrip("/")
     gw = _gw()
     uid = os.environ.get("WS_USER") or ""
     if not uid:
         try:
             uid = json.load(open("/workspace/.platform/gateway.json", encoding="utf-8")).get("uid") or ""
         except Exception:
             uid = ""
     opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
     opener.open(gw + "/portal/u/" + uid)
     spec = json.load(open("/workspace/light-app-work/modify-spec.json", encoding="utf-8"))
     req = urllib.request.Request(gw + "/app/v1/apply/spec",
         data=json.dumps({"spec": spec}).encode(),
         headers={"Content-Type": "application/json"}, method="POST")
     print(opener.open(req, timeout=15).read().decode())
     PY
     ```
5. **结构性变化例外**：只有新增/删除**整个页面区块容器**（如整行图表容器、整张表格容器）时，
   才用 `LIB_BASE=lib/ RUNTIME_SPEC=1 OUT_BASE=/workspace/light-app-work python3 /workspace/version0802/light-app/scripts/build_dashboard.py` 重建 HTML
   替换 `www/index.html`，且替换后仍必须再走一次 apply/spec 保证数据一致。
6. 平台返回实际应用的 appId 后，**用简体中文**向用户汇报新链接（页面改动即时生效，门户自动刷新预览）
