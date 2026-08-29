# App Worker 脚手架（M1）

agent 生成"大屏应用"的固定流程：

1. 在 `/workspace/.apps/<appId>/` 下（容器内视角）：
   - `v1.js`：从 `worker.js.tpl` 复制并按业务修改（表结构/接口/页面）；
   - `www/`：页面资产（从 `www/index.html` 起步，改文件即时生效）；
   - 需要时新建 `v2.js`（新版本，独立数据目录，不覆盖旧版本）。
2. 在 `/workspace/.apps/apps.json` 登记：
   - `port` 从预留区间取（20000-29999），不重复；
   - `defaultVersion` 指向当前默认版本。
3. **修正属主**（容器 root 运行、宿主机发布进程是 uid 1000，不执行则发布报 PermissionError）：`chown -R 1000:1000 /workspace/.apps`
4. 发布（容器内无 curl，用 python3；uid 取 `WS_USER` 或 `config/server.json` 的 `uid`）：
   ```python
   python3 - <<'PY'
   import json, urllib.request, os
   cfg = json.load(open("config/server.json"))
   gw = cfg["baseUrl"].rstrip("/")
   uid = os.environ.get("WS_USER") or cfg.get("uid")
   opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
   opener.open(gw + "/portal/u/" + uid)
   req = urllib.request.Request(gw + "/app/v1/sync",
       data=json.dumps({"payload": {"uid": uid}}).encode(),
       headers={"Content-Type": "application/json"}, method="POST")
   print(opener.open(req, timeout=15).read().decode())
   PY
   ```
   （网关校验 Cookie 后注入 app_sync token 转发 dagu → 扫描注册表 → 生成 `workerd/config.capnp` → 校验 → 覆盖 → workerd 热加载。）
5. 验证：`{baseUrl}/app/<port>/svc/health` 输出含 `"ok": true`。
6. 版本切换 / direct 测试：
   - direct：`/app/<port>/svc/health?version=v2`；
   - 切默认：改 `apps.json` 的 `defaultVersion`（零 config、零重启）。

接口约定：`/`（页面）、`/svc/health`（探活）、
`/svc/spec`（GET 读取 / POST 写入大屏 spec，**快照唯一数据源**）、
`/svc/events`（SSE 实时推送订阅）；
`www/` 内非首页静态文件（图片等）按原路径直接访问（worker 静态路由），
页面图片用相对路径 `uploads/<文件名>` 引用（worker 已内置静态路由）。

前端资产：页面通过 `/lib/...` 引用**平台共享资产**（`$DAGU_ROOT/app-libs`，由 install.sh 从模板
安装；含 echarts、fontawesome、dashboard.css 等），agent 无需自带 lib，改页面即改文件。

运行时大屏（spec 入库 + SSE 实时更新）：
1. 生成：`LIB_BASE=lib/ RUNTIME_SPEC=1 python3 scripts/build_dashboard.py <spec.json>`
   → 产出 `html/<name>.html`（页面运行时拉取 spec）与 `html/<name>.spec.json`（侧车 spec）；
2. 部署：把 `index.html` 放入 `.apps/<appId>/www/`，发布（app_sync）后
   `POST /app/<port>/svc/spec` 将侧车 spec 写入 SQLite（`{"spec": <spec>}` 或直接传 spec 对象）；
3. 页面加载：`fetch('/svc/spec')` 拿 spec 渲染（不再写死 `window.DASHBOARD_SPEC` 常量）；
4. 实时更新：页面 `new EventSource('/svc/events')` 订阅，worker 收到
   `/svc/spec` 数据变更后经内部 Hub 广播 → SSE 推送 →
   前端重拉 spec 并 `window.DashboardRender()` 无刷新重渲染。

定时数据同步（**每个轻应用必备**，快照合并）：生成大屏时必须复制 `scripts/sync_merge.py.tpl`
为 `.apps/<appId>/sync_merge.py` 并按业务定制（查询 SQL、合并表 key、联动图表），在 `apps.json`
登记 `"sync": {"script": "sync_merge.py"}`；`app_sync_data` 到点执行：取当前 spec → 查库 →
**按 key 合并**（只更新已有行对应单元格，缺失旧行保留、不新增行）→ 写 `sync_at` → POST `/svc/spec` → SSE 广播。
缺失视为交付不完整（app_sync_data 报 ERROR）。

**修改已有大屏（硬性规则）**：HTML 骨架生成时已定稿，后续修改统一走
**`POST /app/v1/apply/spec`**（body 传 `{"spec": ...}`；平台按 `.selected` 强制目标 app，
结构校验后写库 + SSE 广播，页面自动重绘）。标题/简介同样走 apply/spec（改 `spec.title`），
门户卡片标题从 spec 读取（单一来源）。

生成物元数据（门户展示用，agent 生成时写入 apps.json）：
- `title`：大屏名称（必填，门户卡片主标题）；
- `description`：一句话简介（推荐）；
- `createdAt`：生成时间（ISO 8601，推荐）；
- `type`：默认 `dashboard`，未来可扩展（报表/小应用）。

汇报规范：主推大屏链接 `http://IP:9088/app/<port>/`，并附带门户入口
`http://IP:9088/portal`（对话 + 生成物切换展示）。

**禁止外网请求（硬性规则）**：worker 与页面 JS 不得发起任何外部网络请求（fetch/WebSocket/EventSource/外部
CDN/外部 API 一律禁止）；只允许 workerd 内部绑定（`http://lib`、`http://files`）与应用内相对路径
（`lib/`、`uploads/`、`/svc/...`，含 `/svc/events` SSE 订阅）；数据仅来自应用 SQLite/内嵌数据或平台只读网关。

修改现有大屏（门户联动）：
- 用户在门户点选卡片后，系统写 `users/<uid>/workspace/.apps/.selected`（JSON：id/ts）。
- 当用户说"改当前大屏/这个卡片/调整布局"时，agent 先读 `.selected` 确认目标，把修改后的
  完整 spec JSON 写 `temp/modify-spec.json` 并调 `POST /app/v1/apply/spec`；平台按
  `.selected` 强制目标、校验后写库 + SSE 广播，已打开页面自动重绘，改完汇报新链接。
