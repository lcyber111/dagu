# ADR-0003：运行时实时态势大屏 —— 宿主机 workerd 统一承载 App Worker（C+ 路线）

状态：已接受（2026-08-24 设计评审定稿；M0/M1/M2 核心能力与 M3 加固已实测通过，单进程定稿）
日期：2026-08-24

## 背景

### 现状

- 态势大屏是"生成期快照"：`build_dashboard.py` 把 `db_query.py`（Doris / MySQL）的查询结果
  写死进 HTML 的 `window.DASHBOARD_SPEC`，`serve_html.py` 只做静态托管，页面运行期不连任何后端。
- 数据时效 = 生成时刻；agent 改页面只能重新构建整个 HTML，无法运行时实时变化。
- 现有网关链路：Caddy(:9088) 数据面 → 用户容器（opencode:4096 + serve_html 子应用）；
  控制面 `/u/*`、`/api/v1/*` → 宿主机 workerd(:9090)。

### 新需求目标

1. 运行时实时拉取/展示数据：前端与后端交互，后端承载数据增删改查业务逻辑；
2. 每个态势大屏 = 一个轻量级后端微服务（App Worker），自带数据存储；
3. 与 agent 对话可实时改动页面（依赖 workerd 热加载）；
4. 同一会话可生成多个 App Worker，各对应一个前端页面；
5. 复用 workerd 的配置热加载与多服务（nanoservice）能力；
6. 未来交付物可扩展为"前后端 + 数据库"的小应用（不在本阶段实现，架构要留出通路）。

### 已验证事实（2026-08-24，只读核查）

- 生产 workerd 二进制（`dist/workerd-linux-amd64`，版本 2026-08-14）含 `enableSql` /
  `storage.sql` / `actor-sqlite` 符号（DO SQLite 持久化支持），含 `FileWatcher` / `--watch` /
  "Noticed configuration change, reloading shortly"（配置热加载支持）。
- workerd `durableObjectStorage` 支持 `localDisk`（SQLite 文件，按 DO 类/uniqueKey 建子目录），
  命名空间可开 `enableSql` 使用 `state.storage.sql` API（`sql.exec` / `sql.prepare`）。
- workerd `moduleFallback` 存在但为实验特性（需 `--experimental`，外部 HTTP 模块源，
  官方注释"仅本地开发"）；`unsafeEval` 绑定存在（`env.unsafe.newAsyncFunction`），
  可动态执行代码但共享 isolate 且代码受"函数体契约"限制。
- opencode 页面 CSP 无 `frame-ancestors` 限制（可被 iframe 嵌入）；opencode Web UI
  含 preview/panel/sidebar/iframe 字符串（具备内嵌预览面板能力迹象）。
- 用户 workspace 宿主路径 `users/<uid>/workspace` 与容器内 `/workspace` 同源挂载：
  agent 在容器里写的文件，宿主机立即可见。

## 技术路线决策（C+）

**结论：每 App 一个独立 workerd service（独立 isolate，完整 ES 模块能力）+ 平台注册表
（app_sync 自动化发布 + 磁盘 manifest 路由/版本）。** 对比过的备选路线：

- X（App Runtime 壳 + unsafeEval 动态执行）：动态性最好（零 config 零重启），但共享 isolate
  导致单点可用性风险（一个 app 死循环拖垮全部）、agent 代码受"函数体契约"限制
  （不能 import/完整模块/自由 DO）、unsafeEval 是 workerd 明示"非硬沙箱"的最大雷区。
  结论：作为 PoC 对照组验证后归档，不做生产基线。
- C（原始版）：每 app 独立 service，隔离/能力最佳，但新 app/新版本需改 config + reload。
  结论：采用，并用平台自动化补齐短板，即 C+。

## 已确认决策（2026-08-24 评审定稿）

### 目标与模型

1. 大屏数据"实时"验收目标：**分钟级**（上游库更新后 1~5 分钟内大屏可见）。
2. 每个大屏 = 一个 **App Worker（深模块，agent 编写完整 ES 模块 worker.js）**：
   对外小接口（页面 + `/api/data` CRUD + 可选推送）；内部实现路由/业务/SQLite/前端渲染；
   一个 app = 一个大屏（多视图是 app 内部数据接口）。
3. 数据模型：agent 在 worker.js 中定义（标准脚手架模板 + DO SQLite），不做声明式限制。

### 承载与进程

4. **App Worker 由宿主机 workerd 统一承载**（不放用户容器）：workspace 同源挂载、
   大屏独立于容器生命周期、部署零新增组件。
5. **单 workerd 进程**（控制面 :9090 + App Workers 同进程，控制面兼任 router）暂定；
   M0 实测"发布新版本 reload 对在途请求的影响"后定稿：若单次 reload 影响 < 2s 且
   期间请求允许失败重试 → 单进程，否则拆双进程。
6. workerd 进程守护：沿用 **nohup + 重启脚本**（与现有 dagu/workerd 一致），M3 再评估 systemd。

### 存储与数据

7. 存储用 **SQLite（DO storage.sql，enableSql）**，不用 LevelDB；每 app 一个 DO namespace，
   SQLite 文件落 `users/<uid>/workspace/.apps/<appId>/data.sqlite`（按 uniqueKey 子目录）。
8. 上游数据（Doris/MySQL）不直接进 worker：M1 生成期 `db_query.py` 灌种子数据 + 手动 refresh；
   M2 由 **dagu 定时 DAG（`app_sync_data`）直接查库写 SQLite**（零新增组件，分钟级同步）。
9. 配额默认：每 uid ≤ 20 个 app、单 app SQLite ≤ 100MB、workerd 进程内存 ≤ 1GB；
   超限**报错拒绝**，不隐式回收。

### 前端与呈现

10. 前端复用现有 dashboard 渲染引擎（组件白名单 + spec 驱动），允许少量自定义脚本；
    不裸写任意页面。
11. 页面资产用 **disk 绑定**：HTML/JS/CSS 放 `users/<uid>/workspace/.apps/<appId>/www/`，
    agent 改文件即时生效（不用 reload）；worker 逻辑改动才走发布流程。
12. M1 实时呈现标准：发布/切换后**整页自动刷新**；无感局部热更（SSE）放 M2。
13. UX：**M1 = 大屏列表页 + 新标签页打开**；M2 评估/启用 opencode 内嵌 iframe 面板
    （贴近 Codex 桌面版侧边栏浏览器；iframe 技术已验证可行）。

### 路由、注册与版本（C+ 核心）

14. 路由：Caddy `/app-proxy/*` → workerd:9090，控制面 worker 按端口/appId 分发
    （service bindings）；`/u/*`、`/api/v1/*` 原逻辑不动。
15. **平台注册表**：`users/<uid>/workspace/.apps/apps.json` 为唯一事实源
    （appId → port / 版本列表 / 默认版本 / worker 文件 / www 目录 / sqlite / 状态）。
    控制面 router **每请求读取（短缓存）**，发布/切版本/回滚 = 改 manifest，零 config。
16. **app_sync 自动化发布**（dagu webhook，与 user_create 同模式）：agent 写
    `.apps/<appId>/` 后调 `POST /api/v1/webhooks/app_sync` → 扫描 manifest →
    生成 config.capnp（新增/更新 app-<appId>-v<ver> service 与绑定）→ 先校验
    （`workerd compile`/capnp 检查）→ 覆盖配置 → FileWatcher 热加载。发布低频
    （新 app / 新版本首次出现才发生），版本切换不触发。
17. **版本化**：版本文件不覆盖（`v1.js`、`v2.js` 并存）；每个版本一个独立 service /
    isolate；manifest 的"默认版本"决定新请求路由；切换 = 改 manifest，零重启，
    在途 v1 请求在 v1 service 内自然完成；**direct 测试** = 路由带显式版本参数
    （`/app-proxy/<port>?version=v2`）先跑单测，通过后再切默认版本。
18. App 归属 **uid 级**：`users/<uid>/workspace/.apps/`，跨会话可见。
19. 存量大屏**不处理、不兼容**；serve_html 随自然淘汰。
20. App 删除：**归档**（`archive/apps/<uid>-<appId>-<ts>.tar.gz`）；`user_delete` 归档整个
    workspace 并触发 `app_sync` 摘除该用户 app。
21. M1 不引入"草稿/发布"两态（manifest 里即线上）。

### 安全

22. 访问控制：`ws_user` Cookie + app 归属校验（uid 级）；M3 升级 per-app token。
23. workerd 以非 root 运行；App Worker 默认无网络绑定，disk 绑定仅指向本 app 目录；
    workerd 非硬沙箱为已记录风险（内网离线可信环境可接受，每 app 独立 isolate 缓解）。
24. **不用 unsafeEval 作为生产执行机制**（共享 isolate + 任意代码执行风险）。

## 架构图

```
浏览器（opencode Web / 列表页 / 新标签页）
   │  /app-proxy/<port>/...（ws_user Cookie）
Caddy :9088 ───────────────────────────────── 数据面路由
   ├─ /u/*、/api/v1/*、/app-proxy/* → workerd :9090（单进程）
   │     ├─ gatewayWorker：控制面 + router（每请求读 apps.json 短缓存）
   │     ├─ app-<appId>-v1 / v2 …（每版本独立 service/isolate）
   │     │     ├─ worker.js（agent 编写，完整 ES 模块）
   │     │     ├─ www/（disk 绑定，页面资产）
   │     │     └─ DO + SQLite（每 app 一个命名空间，enableSql）
   │     └─ FileWatcher：app_sync 发布时整体热加载
   └─ 容器 dagu-u-{uid}：opencode(4096) + 过渡期 serve_html（存量）

agent 写 workspace/.apps/<appId>/{v1.js, v2.js, www/, apps.json}
   → POST /api/v1/webhooks/app_sync（dagu）
   → 校验 → 生成 config.capnp → FileWatcher 热加载（仅新 app/新版本首次发布）
版本切换 / direct 测试 / 回滚 = 改 apps.json（零 config、零重启）
M2：dagu 定时 DAG app_sync_data → db_query 查 Doris/MySQL → 写 App SQLite
```

## 组件职责

| 组件 | 职责 | 变化 |
| --- | --- | --- |
| Caddy（容器，:9088） | 数据面路由、Cookie 校验、启动页、活动日志；`/app-proxy/*` 改指宿主机 workerd | 小改 |
| 控制面 workerd（:9090） | 既有 `/u`、`/api/v1`、webhook、restart；新增 router（读 apps.json 分发） | 扩展 |
| App Worker（每 app/版本一个 service） | 页面托管（disk）+ 数据 CRUD + SQLite + 业务规则（agent 代码） | 新增 |
| dagu `app_sync` DAG | 扫描 `apps.json` → 校验 → 生成/更新 config.capnp | 新增 |
| dagu `app_sync_data` DAG（M2） | 定时查上游库 → 写 App SQLite | 新增 |
| 用户容器 | opencode 会话 + workspace（agent 编辑端）；serve_html 过渡期保留 | 基本不变 |

## App Worker 接口约定

- `GET /` → 大屏页面（HTML，复用 lib/dashboard）
- `GET /api/health` → 就绪探针
- `GET /api/data?view=<viewId>` → 数据（JSON）
- `POST/PUT/DELETE /api/data/<collection>/<id>` → 增删改（写 SQLite）
- `POST /api/refresh` → 手动触发上游同步（M1）
- `GET /api/events` → SSE/WebSocket 推送（可选，M2）

脚手架模板（worker.js 骨架 + DO/SQLite 用法 + 页面示例）由模板仓库提供，agent 在其上实现业务。

## 目录与配置约定

```
users/<uid>/workspace/.apps/
  apps.json                     # 注册表/事实源：appId → port/版本列表/默认版本/文件/状态
  <appId>/
    v1.js / v2.js …             # 版本文件（不覆盖，agent 编写）
    spec.json                   # 页面/数据模型参考（可选）
    data.sqlite                 # DO SQLite 持久化（按 appId 命名空间）
    www/                        # 前端页面资产（disk 绑定，改文件即时生效）
```

宿主 `config.capnp` 由 `app_sync` 从 `apps.json` 生成（每 app/版本一个 service + DO namespace +
disk bindings + gateway 的 routes 绑定），不手工维护；端口由 manifest 原子分配（预留区间）。

## 数据流

- 生成期：需求理解 → `db_query.py` 查库 → 种子数据写入 App SQLite → 生成 worker.js/www →
  `app_sync` 发布 → 热加载生效。
- 运行期（M1）：前端轮询 `fetch(/api/data)` → App Worker 读 SQLite → 局部更新；
  agent 改 worker.js → `app_sync`（新版本）或 manifest 切换（既有版本）→ 页面刷新。
- 运行期（M2）：dagu `app_sync_data` 定时同步上游 → App SQLite；SSE 推送 → 无感热更。

## 生命周期

- 创建/发布：agent 写 `.apps/<appId>/` → `app_sync` → 校验 → 生成 config → 热加载。
- 版本迭代：新增 `v2.js` → `app_sync`（一次）→ manifest 切默认版本（零重启）；direct 先测后切。
- 切换/回滚：改 `apps.json` 默认版本，零 config、零重启，在途请求自然完成。
- 删除：从 `apps.json` 摘除 + 归档 sqlite → `app_sync` 重新生成 config。
- 空闲回收：容器 stop 不影响宿主机 App Worker（大屏仍可访问）。
- 用户删除：`user_delete` 归档 `users/<uid>`（含 `.apps`），并触发 `app_sync` 摘除。

## 分阶段实施

- **M0 PoC**：宿主 workerd 单进程跑控制面 + 示例 app（静态页 / SQLite CRUD，含 v1/v2）；
  验证：① DO sqlite 落盘持久化（进程重启不丢）；② `app_sync` 生成 config + FileWatcher 热加载；
  ③ 版本切换 / direct 测试走 manifest 零重启，在途 v1 完成；④ Caddy `/app-proxy/*` 转发与
  Cookie 鉴权；⑤ **发布新版本 reload 对在途请求的影响**（<2s 且可重试 → 单进程定稿）；
  ⑥ opencode 内嵌面板入口摸底（M2 UX）；⑦ unsafeEval 壳对照组（验证后归档）。
- **M1 MVP**：大屏生成流程产出 App Worker（脚手架 v1 模板 + app_sync 闭环）；前端从
  `/api/data` 拉数据替代快照；种子数据灌入 + 手动 refresh；大屏列表页 + 新标签页；
  配额校验；删除归档。
- **M2 实时化**：dagu `app_sync_data` 定时同步（分钟级）；SSE 推送 + 无感热更；
  opencode 内嵌 iframe 面板；多 app 管理。
- **M3 加固**：per-app token、配额强制与监控、热加载失败回退、审计日志。

## M0 PoC 验证结果（2026-08-24，VM .131）

已完成（全部实测通过）：

- C+ 架构闭环：控制面 router（每请求读 `apps.json`）+ 每 app/版本独立 workerd service +
  DO SQLite（enableSql / storage.sql）；
- CRUD（PUT/GET/列表）与 v2 direct（`?version=v2`）正常；v1/v2 数据隔离（各自 sqlite 文件）；
- SQLite 落盘持久化：进程重启后数据不丢（`data/<appId>/<uniqueKey>/<id>.sqlite`）；
- manifest 版本切换：`defaultVersion` v1↔v2 仅改 `apps.json`，零 config、零 reload，立即生效；
- app_sync 发布：重新生成 config.capnp（先 `workerd compile` 校验）→ FileWatcher 自动热加载；
- reload 影响：发布 reload 期间 40/40 请求全部 200，未见断连；
- Caddy 路由：`/app-proxy/2xxxx` → 宿主机 workerd:19090（带 ws_user Cookie 正常访问；无 Cookie 401）。

关键实测发现（写入设计约束）：

- workerd `--watch` 只监听 config.capnp 及其嵌入文件路径，**只改 worker.js 不触发 reload**；
  改代码必须走 app_sync（重新生成 config）或发布新版本后 manifest 切换——与 C+ 设计一致；
- DO storage 的 disk 服务必须 `writable = true`（`disk = (path = "...", writable = true)`）；
- DO namespace 需显式 binding（`durableObjectNamespace`）才能在 `env` 中访问；
- 运行中删除 DO 数据目录会导致 SQLITE_CANTOPEN，需重启恢复（运维约束：数据目录只增不改）。

待验证 / 后续：

- 单进程 vs 双进程最终定稿：当前 reload 影响极小（40/40 OK），M1 前做一次带负载/长请求的
  reload 压力测试后定稿；
- opencode 内嵌面板入口（M2 UX）未做实测；
- unsafeEval 壳对照组未构建（该路线已定不采用，可不做）。

## M1 验证结果（2026-08-24，VM .131）

已完成并实测通过：

- **发布闭环（agent 一条命令）**：`POST /api/v1/apps/sync`（带 ws_user Cookie，网关注入
  `app_sync` token 转发 dagu，agent 无需持密钥）→ dagu `app_sync` DAG →
  `scripts/app_sync.sh` 扫描注册表 → 生成 config.capnp（先 `workerd compile` 校验）→
  FileWatcher 热加载。经 Caddy 端到端验证（config mtime 更新、dagRunId 返回、app 持续可用）。
- **大屏列表页**：`/apps`（Caddy 路由 → 网关），展示当前 uid 所有 app 与版本链接。
- **配额校验**：app_sync 内置 每 uid ≤ 20 app、单 app SQLite ≤ 100MB，超限报错退出；
  支持 `WEBHOOK_PAYLOAD.uid` 范围同步。
- **reload 压力测试**：连续 5 次发布 reload 期间，60/60 请求全部 200，
  health 平均 0.8ms / 最大 2.7ms —— **单进程定稿**（控制面 + App Workers 同进程 +
  `--watch` 热加载），不再拆分双进程。
- **控制面兼容**：新 worker.js 保留 /u、health、webhook、restart 全部原逻辑。

实现要点（已写入代码注释与脚手架文档）：

- capnp `embed` 相对配置文件目录且不支持绝对路径；disk 路径相对 workerd CWD；
- DO 数据盘需 `writable = true`，磁盘服务访问 `.apps` 目录需 `allowDotfiles = true`；
- DO namespace 必须显式绑定到 `env`；
- workerd DO 存储锁：同一数据目录只能被一个实例持有，重启前须确认旧进程已退出；
- `--watch` 只监听 config 文件：改 worker.js 必须走 `app_sync` 发布。

M1 剩余（下一迭代）：

- 模板 SOP（agents_gen）固化"生成大屏 app"流程（脚手架引用 dagu-gate/templates/app-scaffold）；
- 大屏页面接入现有 lib/dashboard 渲染资产（当前脚手架为简化页面）；
- 种子数据灌入演示（脚手架已提供 `/api/refresh`）；
- M2：dagu `app_sync_data` 定时同步、SSE 推送、opencode 内嵌面板。

## M2 验证结果（2026-08-24，VM .131）

- **分钟级定时同步**：`app_sync_data` DAG（默认 `*/5 * * * *`）按各 app 的
  `sync: {db, sql}` 配置，在用户容器内跑 `db_query.py` 查上游（Doris 实测 265 行），
  经网关 `POST /api/v1/apps/<appId>/refresh` 写回 App SQLite（主键去重后 12 艘航母），
  页面轮询刷新可见。零新增组件、宿主无需 DB 驱动。
- **实时推送**：页面经 WebSocket `/api/ws` 连接 **DO Hub（Hibernation）**；
  PUT/删除/refresh 后 `Hub.broadcast` 推送，前端收到即刷新（无感热更）。
  实测：客户端收到 `{"type":"data","reason":"put","id":...}` 推送帧。
- 经验：workerd 不支持跨请求向 ReadableStream enqueue（SSE 方案不成立）；
  WebSocket 跨请求广播必须用 DO Hibernation（`acceptWebSocket` / `getWebSockets`）。
- **app_sync_data 接入**：`deploy/dags/app_sync_data.yaml.tpl`（`{{SYNC_CRON}}` 渲染，
  默认 5 分钟）；install.sh 同步支持。

M2 剩余：

- opencode 内嵌 iframe 面板（见下方摸底结论）；
- 监控告警（M3）。

## M2 尾项结果（2026-08-24）

**opencode 内嵌面板摸底**：解析 opencode Web UI 前端 bundle（`index-*.js`）后确认——
该版本**没有**用户可用的"侧边栏浏览器/内嵌预览面板"入口（webview 仅为桌面壳内部实现、
preview 为主题/图片预览、链接一律新标签页打开）。结论：M2 UX 维持"列表页 + 新标签页"；
"内嵌 iframe 面板"列为 M3 待定项，需定制 opencode UI（fork/插件）才能实现。

**多 app 管理（删除）**：`/apps` 页新增"删除"按钮 → `DELETE /api/v1/apps/<appId>`
（Cookie 鉴权）→ 网关注入 `app_delete` token 转发 dagu `app_delete` DAG →
`scripts/app_delete.sh` 从注册表摘除 + 归档 `archive/apps/<uid>-<appId>-<ts>` +
重建 workerd 配置。实测：发布临时 app → 删除 → 列表移除、旧端口 404、归档落盘、
其它 app 不受影响。install.sh webhook 循环已含 `app_delete`。


## M3 第一批加固（2026-08-24，VM .131）

- **per-app token（可选开启）**：manifest 版本项 `token: true`（自动派生，HMAC 于平台
  `.apps-secret` + uniqueKey）或 `token: "xxx"`（显式）。开启后：
  `/api/data`、`/api/refresh`、CRUD、`/api/ws` 均要求 `X-App-Token`（WS 走 `?token=`），
  页面自动注入 `window.APP_TOKEN`；`app_sync_data` 自动派生 token 随 refresh 透传（网关透传头）。
  实测：无 token 401、带 token 全通、定时同步在 token 开启后仍正常、WS 推送正常。
- **监控巡检**：`app_status.sh` + `app_monitor` DAG（默认每 10 分钟）——app 数量/配额、
  SQLite 体积、最后同步时间（`app_sync_data` 写 `_meta.lastSync`），异常输出 WARN/ERROR。
- **workerd 守护**：`workerd_guard.sh` + `workerd_guard` DAG（默认每 1 分钟）——进程不在或
  9090 未监听时自动拉起（等待旧进程退出以避开 DO 存储锁）。实测：kill 后自动恢复、health 正常。
- **热加载失败回退**：app_sync 生成 config 前 `workerd compile` 校验，失败保留旧配置（M1 已实现）。
- **审计现状**：发布/删除/刷新均为 dagu DAG 运行记录（dagRunId）；Caddy 访问日志含 uid；
  workerd console 记录关键操作。
- **审计日志落地**：`app_audit.sh` + `app_audit` DAG（默认每 5 分钟）从 Caddy 访问日志增量提取 App 生命周期操作（发布/删除/refresh/webhook），汇总到 `logs/app-audit.log`（ts/uid/method/uri/status），偏移标记防重复。实测：首次全量 + 增量去重正常。

## 生成物门户（/workspace，2026-08-24 定稿并实测）

- **形态**：左侧固定 OpenCode 对话（可折叠，CSS 隐藏保留会话；分隔条可拖拽调比例 15%–85%，Pointer 捕获 + 全屏遮罩防 iframe 抢事件，比例记忆 localStorage）；右侧生成物画廊 + 切换展示区（同一时间一个，切换销毁旧 iframe）。
- **生成物语义**：每个生成物 = 一个 App Worker（后端 CRUD + 前端 HTML + SQLite），manifest 元数据 title/description/createdAt/type（agent 声明），门户自动补版本/端口/状态（轻量探活）/最近同步时间。
- **选中→修改闭环**：点卡片 → 网关 PUT /api/v1/apps/selected → dagu pp_select DAG 写 .apps/.selected；agent 改当前大屏前读标记 → 改 www/ 或新版本 → 发布（app_sync）→ _meta.lastPublish 更新 → 门户自动刷新预览。
- **交互**：默认选中最近生成物（正在看的不打断）；空态引导；删除（归档，二次确认）；新标签打开；列表 5s 轮询。
- **清单接口**：GET /api/v1/apps（uid 鉴权；含 title/desc/createdAt/type/版本/状态/lastPublish，不含 token）。
- **门户实现**：静态页 $DAGU_ROOT/portal/（index.html/app.js/app.css），网关经 disk 绑定托管，改文件即时生效；/workspace、/portal/* 由 Caddy 指向 workerd:9090。
- 无头 UI 逻辑测试 22/22；Windows↔VM 关键文件哈希一致。
## 风险与开放问题

1. 发布新版本时**整进程 reload 对在途请求的影响**（M0 实测后定单/双进程与发布窗口）。
2. 每 app/版本一个 isolate：app 数量增长时内存/进程内线程占用（配额 20/uid 兜底）。
3. 端口与版本并发分配需原子化（`app_sync` 加锁或 manifest 统一分配）。
4. agent 依赖脚手架与 SOP（不能从零写 capnp；worker.js 模板随模板仓库交付）。
5. opencode 内嵌面板的最终入口形态待 M0 摸底（字符串存在 ≠ 用户入口现成）。

## 明确不做（当前阶段）

- 不在用户容器内运行 workerd。
- 不用 LevelDB、不用 moduleFallback、不用 unsafeEval 作为生产执行机制。
- 不引入独立数据网关进程（数据同步走 dagu 定时 DAG）。
- 不让 App Worker 直连 Doris/MySQL。
- 不兼容/迁移存量静态大屏。
- M1 不做草稿/发布、不做 SSE 无感热更、不做内嵌面板。

## 后果

- 交付物不变：仍是一个 Caddy 容器 + dagu 单二进制 + workerd 单二进制 + 模板目录。
- 大屏从"静态快照"演进为"运行时应用"，前端框架（spec/渲染引擎）可复用；
  agent 编写完整 ES 模块 worker.js，能力不受说明书限制。
- 控制面新增 router 与 app 分发职责；发布自动化（app_sync / app_sync_data）；
  版本管理与回滚变成纯 manifest 操作。
- 架构定稿后进入 M0 PoC；ADR 状态随验证结果更新。
