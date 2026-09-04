# 轻应用（App Worker）大屏主流程

## 职责边界（先读）

本 SOP 只规范**交付段**：自"spec 已就绪"起的构建 → 打包 → 发布 → spec 入库 →
门户展示。**数据获取/领域分析不属于本 SOP 范围**（由上游/同事与智能体自行完成），
本 SOP 不做任何数据获取规定；数据工作完成后带着 spec 进入本流程即可。

## spec 质量与样式规则（硬性）

- **构建脚本只能用本 light-app 的** `/workspace/version0802/light-app/scripts/build_dashboard.py`
  （必须 `RUNTIME_SPEC=1`，spec 不写死进 HTML，页面从 `/svc/spec` 拉取 + SSE 实时更新）。
  **禁止使用** `agents_gen/scripts/build_dashboard.py`——那是静态内联版（spec 写死进 HTML），
  交付后无法实时更新/对话修改。
- **空数据图禁止上屏**：每张图必须有可绘制数据——map 至少含 markers/circles/lines 之一；
  bar/line/pie/scatter/radar 的数据数组必须非空。无数据的面板**不要放图**，改用文字/表格
  明确写"暂无数据"。发布前 `validate_runtime.py` 会逐图拦截空数据。
- **style 按任务性质自动选择**（写入 `spec.style`；用户明确指定风格时以用户为准）：
  - `command`：态势 / 监控 / 实时（默认）
  - `report-light` / `report-dark`：评估 / 研判 / 简报 / 报告
  - `timeline`：复盘 / 时序 / 演进
  - `terminal`：技术 / 命令 / 日志风
  - `minimal`：极简 / 参考页
  - `report-*` / `timeline` 必须携带对应的 `report` / `timeline` 结构（不能拿 rows 硬套）。

**新生成的大屏一律走 App Worker 流程（页面 + 数据接口 + SQLite 的微服务），自动进入生成物门户（/portal 右侧卡片）。**

新生成的大屏 = 宿主机 workerd 内的独立 App Worker 微服务（页面 + 数据接口 + 每版本独立 SQLite），自动出现在「生成物门户」右侧卡片。

## 目录约定（容器内视角；宿主机对应 `users/<uid>/workspace`）

- 注册表：`/workspace/.apps/apps.json`
- 每个大屏：`/workspace/.apps/<appId>/`
  - `<version>.js`（worker，首个版本 `v1.js`；新版本另存 `v2.js`，不覆盖旧版本）
  - `www/`（页面资产，`index.html` 起步，**改文件即时生效**；图片等静态文件放 `www/uploads/`，按相对路径 `uploads/<文件名>` 引用）
  - 数据按版本自动隔离（`data-<version>` SQLite，无需手动建）
- 脚手架：`light-app/app-scaffold/worker.js.tpl`（复制为 `v1.js` 后按业务修改）；示例页面 `light-app/app-scaffold/www/index.html`、注册表示例 `light-app/app-scaffold/apps.json.example` 同目录
- 构建脚本：`light-app/scripts/build_dashboard.py`（运行时模式）

## 固定流程

1. **生成页面**（运行时模式，spec 不写死进 HTML）：

   ```bash
   mkdir -p /workspace/light-app-work/temp
   LIB_BASE=lib/ RUNTIME_SPEC=1 OUT_BASE=/workspace/light-app-work \
     python3 /workspace/version0802/light-app/scripts/build_dashboard.py \
       /workspace/light-app-work/temp/dashboard_spec_<任务>.json
   python3 /workspace/version0802/light-app/scripts/validate_runtime.py \
     /workspace/light-app-work/<文件名>.html /workspace/light-app-work/<文件名>.spec.json   # 校验侧车 spec + 运行时 HTML
   ```

   - `LIB_BASE=lib/`：页面资源用**相对路径**引用平台共享 app-libs（页面在 `/app/<port>/` 下解析为 `/app/<port>/lib/...`；禁止用根绝对路径 `/lib/...`）
   - `RUNTIME_SPEC=1`：产出运行时 HTML（不内联 spec）+ 侧车 `<name>.spec.json`；页面加载从 `/svc/spec` 拉取渲染
   - `OUT_BASE=/workspace/light-app-work`：构建产物统一落在 `agents_gen` 之外的独立工作区（**禁止写入 agents_gen/ 内**，避免污染同事 git 仓库、被同步 reset 清掉）；spec 输入同样放在该工作区
   - **不要用 `agents_gen/scripts/validate_html.py` 校验运行时版**（它只支持内联 spec 的静态页，会误报）；运行时版一律用上面的 `validate_runtime.py`

2. **打包**：`/workspace/light-app-work/<name>.html` 放入 `/workspace/.apps/<appId>/www/index.html`。

3. **写 worker**：复制脚手架为 `/workspace/.apps/<appId>/v1.js`，按需修改表结构/接口。

4. **登记注册表** `/workspace/.apps/apps.json`：`id`、`port`（20000-29999 唯一）、`defaultVersion`、`versions`，以及门户元数据 `title`（必填）、`description`、`createdAt`、`type`（默认 dashboard），并按 `sync.md` 登记定时同步。

5. **修正属主（容器以 root 运行，宿主机发布进程是 uid 1000；不执行则发布报 PermissionError）**：

   ```bash
   chown -R 1000:1000 /workspace/.apps
   ```

6. **发布**（容器内无 curl，用 python3；uid 取自环境变量 `WS_USER`，否则 `config/server.json` 的 `uid`）：

   ```python
   python3 - <<'PY'
   import json, os, urllib.request
   # 网关地址：优先平台注入 /workspace/.platform/gateway.json（与 agents_gen 解耦）。
   # API 调用用 internalBaseUrl（容器内可直达 caddy-gateway），公网 baseUrl 仅用于给用户汇报链接。
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
   assert uid, "无法确定 uid（WS_USER 或 gateway.json.uid 缺失）"
   opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
   opener.open(gw + "/portal/u/" + uid)               # 建立会话 Cookie
   req = urllib.request.Request(
       gw + "/app/v1/sync",
       data=json.dumps({"payload": {"uid": uid}}).encode(),
       headers={"Content-Type": "application/json"}, method="POST")
   print(opener.open(req, timeout=15).read().decode())
   PY
   ```

7. **验证**（必须输出含 `"ok": true` 才允许汇报）：

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
   print(opener.open(gw + "/app/<port>/svc/health", timeout=10).read().decode())
   PY
   ```

8. **spec 入库（必做）**：`POST /app/<port>/svc/spec`（body 传侧车 spec 或 `{"spec": ...}`），再 `GET /app/<port>/svc/spec` 确认返回非空 spec 才可汇报——否则页面只有骨架没有内容。

9. **汇报**：用**简体中文**汇报；主推大屏链接用**公网地址** `{baseUrl}/app/<port>/`（baseUrl = gateway.json 的 `baseUrl` 字段，不要用 internalBaseUrl 汇报），附门户入口 `{baseUrl}/portal`。

## 接口约定（worker 脚手架内置）

- `/` 页面；`/svc/health` 探活；`/svc/spec`（GET 读取 / POST 写入大屏 spec，快照唯一数据源）；`/svc/events`（SSE 实时推送：页面 EventSource 订阅，spec 更新后自动重绘）
- 页面共享资源走相对路径 `lib/...`（worker 内解析为平台 app-libs：echarts / fontawesome / dashboard.css 等）
- `www/` 内非首页静态文件（图片等）按相对路径直接访问（worker 静态路由）

## 图片与对话式补图

- 图片放入 `/workspace/.apps/<appId>/www/uploads/`，页面用相对路径 `uploads/<文件名>` 引用（worker 静态路由自动服务）
- `photo.src` 指向的文件缺失时，大屏显示"本地照片缺失"占位；文件已存在时刷新即显示
- 用户要求"把图放到大屏"时：把图片放入 `www/uploads/`，修改 `www/index.html` 对应图位 `photo.src` →
  **无需重新发布**（改文件即时生效；注意目录约定第 5 步的属主修正 `chown -R 1000:1000 /workspace/.apps`）

## 禁止外网请求（硬性规则）

轻应用（`v1.js`/`v2.js` worker 与页面 JS）**一律不得发起任何外网请求**：

- **禁止** `fetch`/`XMLHttpRequest`/`WebSocket` 等请求任何外部地址（公网 IP、域名等）
- **禁止**引用外部 CDN / 外部静态资源 / 外部 API
- **允许**：平台内部 workerd service binding（`http://lib`、`http://files` 等内部地址）、页面同应用相对路径（`lib/`、`uploads/`、`/svc/...`）、网关同域接口（`{baseUrl}` 下的 `/app/v1/*` 与 `/api/v1/*`）
- **数据来源仅限**：应用自身 SQLite（DO 存储）、页面内嵌数据、或经平台 `scripts/db_query.py` 只读网关取数后注入
- 发布前自查：worker 与页面中除 `http://lib`、`http://files`、`http://internal` 等内部绑定外，不得出现任何外部 `http(s)://` 引用；违反视为交付失败

## 版本

- **direct 测试新版本**：`{baseUrl}/app/<port>/svc/health?version=v2`；通过后改 `apps.json` 的 `defaultVersion` 切默认（零重启）。
