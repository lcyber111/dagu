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
   opener.open(gw + "/u/" + uid)
   req = urllib.request.Request(gw + "/api/v1/apps/sync",
       data=json.dumps({"payload": {"uid": uid}}).encode(),
       headers={"Content-Type": "application/json"}, method="POST")
   print(opener.open(req, timeout=15).read().decode())
   PY
   ```
   （网关校验 Cookie 后注入 app_sync token 转发 dagu → 扫描注册表 → 生成 `workerd/config.capnp` → 校验 → 覆盖 → workerd 热加载。）
5. 验证：`{baseUrl}/app-proxy/<port>/api/health` 输出含 `"ok": true`。
6. 版本切换 / direct 测试：
   - direct：`/app-proxy/<port>/api/health?version=v2`；
   - 切默认：改 `apps.json` 的 `defaultVersion`（零 config、零重启）。

接口约定：`/`（页面）、`/api/health`、`/api/data`（GET 列表）、
`/api/data/<id>`（GET/PUT/POST/DELETE）、`/api/refresh`（POST 批量刷新种子数据）；
`www/` 内非首页静态文件（图片等）按原路径直接访问（worker 静态路由），
页面图片用相对路径 `uploads/<文件名>` 引用（worker 已内置静态路由）。

前端资产：页面通过 `/lib/...` 引用**平台共享资产**（`$DAGU_ROOT/app-libs`，由 install.sh 从模板
安装；含 echarts、fontawesome、dashboard.css 等），agent 无需自带 lib，改页面即改文件。

分钟级实时同步（M2）：在版本配置里加 `sync: {db, sql}`（SQL 输出 `id/value` 列），
dagu 定时 DAG `app_sync_data`（默认每 5 分钟）会在用户容器内跑 `db_query.py` 查上游，
再经 `POST /api/v1/apps/<appId>/refresh` 写回 App SQLite；页面同时支持 SSE
（`/api/events`）数据变化即推，无需轮询等待。

生成物元数据（门户展示用，agent 生成时写入 apps.json）：
- `title`：大屏名称（必填，门户卡片主标题）；
- `description`：一句话简介（推荐）；
- `createdAt`：生成时间（ISO 8601，推荐）；
- `type`：默认 `dashboard`，未来可扩展（报表/小应用）。

汇报规范：主推大屏链接 `http://IP:9088/app-proxy/<port>/`，并附带工作台入口
`http://IP:9088/workspace`（对话 + 生成物切换展示）。

**禁止外网请求（硬性规则）**：worker 与页面 JS 不得发起任何外部网络请求（fetch/WebSocket/外部
CDN/外部 API 一律禁止）；只允许 workerd 内部绑定（`http://lib`、`http://files`）与应用内相对路径
（`lib/`、`uploads/`、`/api/...`）；数据仅来自应用 SQLite/内嵌数据或平台只读网关。

修改现有大屏（门户联动）：
- 用户在门户点选卡片后，系统写 `users/<uid>/workspace/.apps/.selected`（JSON：id/ts）。
- 当用户说"改当前大屏/这个卡片/调整布局"时，agent 先读 `.selected` 确认目标，
  再修改该 app 的 `www/`（页面，即时生效）或 `v2.js`（逻辑），发布（app_sync）后
  门户预览自动刷新；改完向用户汇报新链接。
