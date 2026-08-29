# ADR-0001：用 Caddy 网关 + dagu 进程替代 occ2-setup

状态：已接受

## 背景

现有多租户系统 `occ2-setup` 由 FastAPI 管理服务（`occ-user-manager`）和 Caddy 网关组成：门户通过 `POST/DELETE /admin/api/users/{uid}` 同步创建/删除用户容器，Caddy 负责 `/portal/u/{uid}` 门户入口与 Cookie 注入。

目标是用 dagu 工作流编排引擎替换该实现：门户发 HTTP 请求，触发 dagu 的 webhook，由工作流完成"创建用户容器 / 销毁用户容器"等编排操作。接口行为遵循 `OAP任务触发接口.md`（Base URL `/api/v1`、Bearer token、异步触发、`GET /health`）。

部署环境：单台 Ubuntu 主机、完全离线；Docker 仅用于 Caddy 容器和用户容器，dagu 以原生进程运行（不依赖 Python/Go 运行时）。

## 决策

1. 保留 Caddy 作为网关容器：沿用 occ2-setup 的 `caddy-gateway/Caddyfile` 为基础修改，继续负责 `/portal/u/{uid}` 门户入口（写 `ws_user` Cookie、302 到 `/portal`）、`/portal` 门户页、`/app/<port>` App Worker 数据面转发（到宿主机 workerd），并把 `/api/v1/webhooks/*` 转发到 dagu 的 webhook 端点。
2. dagu 以原生进程运行：工作流由 dagu 原生 webhook 触发（`POST /api/v1/webhooks/{fileName}`），DAG 文件命名为 `user_create.yaml`、`user_delete.yaml`，路径与文档一致。
3. 不引入适配层：不做响应体字段翻译。已知偏差——webhook 响应为 dagu 原生 `{dagRunId, dagName}`，与文档示例 `{taskId, message, status}` 不一致；认证用 dagu 生成的 webhook token（`Bearer dagu_wh_...`），满足文档的 Bearer 要求。若门户后续要求严格字段，再评估轻量翻译层。
4. 不引入数据库；用户状态以 Docker 容器 + 数据目录为准，任务日志以 dagu 运行历史为准。
5. 门户不轮询、不等待；创建容器是否就绪属于工作流内部行为，与 HTTP 响应无关。
6. 用户容器就绪判定只看 4096（OpenCode Web）；7010 静态服务（`serve_html.py`）不再使用。

## 后果

- 交付物：一个 Caddy 容器（含 Caddyfile）+ dagu 单二进制 + 两个 DAG 文件 + 模板目录 + 初始化脚本。
- 用户访问入口为 `http://IP:9088/portal/u/{uid}`（写 Cookie → 302 `/portal`），旧 `/u/{uid}`、`/workspace` 入口已随 2026-08-27 路由重构移除。
- 组件最少（Caddy 容器 + dagu 进程），无数据库、无适配层。
- webhook 响应体与文档存在已知字段偏差，门户侧需要接受 `dagRunId`/`dagName`（或将 `dagRunId` 视为 `taskId`）。
- Caddy 容器需能访问宿主机 dagu 端口（转发 `/api/v1/webhooks/*` 时），以及经 dagu-net 解析 `dagu-u-{uid}` 容器名。
