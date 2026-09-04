# CONTEXT.md — dagu-gate 领域术语与约定

## 术语表

| 术语 | 定义 |
| --- | --- |
| 门户 | 第三方门户后端，通过 HTTP webhook 调用本系统的接口（接口文档中的"用户管理系统"）。 |
| OAP 系统 | 本系统（dagu-gate），负责接收门户请求并编排环境自动化任务。 |
| 工作流 / DAG | dagu 中的一次可编排任务，用 YAML 定义（`user_create.yaml`、`user_delete.yaml`）。 |
| 网关（Caddy） | 一个 Caddy 容器，负责两件事：`/portal/u/{uid}` 门户入口（写 `ws_user` Cookie、302 到 `/portal`），以及把 `/api/v1/webhooks/*` 转发到 dagu 的 webhook 端点。配置以 occ2-setup 的 `caddy-gateway/Caddyfile` 为基础修改。 |
| 用户容器 | 每个租户独立的 Docker 容器，命名 `dagu-u-{uid}`，内部运行 OpenCode Web（4096）。不再启动 7010 静态文件服务。 |
| 模板 | 创建用户容器时复制的初始数据：workspace 目录 + opencode 配置，按 `template_id` 区分。 |
| UID | 用户唯一标识，格式 `[A-Za-z0-9_-]{1,64}`，用于容器名和数据目录命名（做安全清洗）。 |
| taskId | 一次任务的全局唯一标识，对应 dagu 的 dagRunId。 |
| 活动 | 带 `ws_user` Cookie 且被代理到用户容器的任何请求（页面/静态资源/WS/SSE 都算）；`/portal/u/{uid}` 入口不算。空闲回收以"最后活动时间"为准。 |
| 空闲回收 | `reap_idle` 定时工作流：把空闲超过 `IDLE_TIMEOUT_MINUTES` 的运行中容器 `docker stop`。 |
| 启动页 | 容器不可达（502）时 Caddy 返回的"正在启动，资源重新分配中"页面，自动触发 `user_start` 恢复。 |

## 已确认的约定

- 接口遵循 `OAP任务触发接口.md`：Base URL `/api/v1`，Bearer token 鉴权（使用 dagu 生成的 webhook token），异步触发。
- 已知偏差：webhook 响应体为 dagu 原生格式 `{dagRunId, dagName}`，与文档示例 `{taskId, message, status}` 字段不一致；已确认 Caddy 配置文件无法改写响应体，不引入适配层翻译。若门户后续要求严格字段，再评估轻量翻译层。
- `GET /api/v1/health` 由 Caddy 直接响应文档格式：`{"status":"healthy","timestamp":"{time.now}"}`。
- Caddy 容器转发 `/api/v1/webhooks/*` 到宿主机 `172.17.0.1:18080`（dagu 监听 `0.0.0.0:18080`）。
- 工作流共四个：`user_create`（创建用户及环境）、`user_delete`（销毁用户及回收资源）、`user_start`（webhook 恢复被回收容器）、`reap_idle`（定时回收空闲容器）。
- 创建流程（user_create）：校验 uid 格式 → 幂等检查（容器已存在且就绪 → 直接成功）→ 复制模板 → 注入配置 → `docker run`（`--cpus/--memory`、网络 `dagu-net`、容器名 `dagu-u-{uid}`）→ 等 4096 就绪（超时 60s）→ 成功；任一步失败 → 清理本次创建的容器和目录再报失败。
- 删除流程（user_delete）：`archive_data=true`（默认）时先打包用户目录到 `dagu-gate/archive/{uid}-{时间戳}.tar.gz` 再删；`force=true` 时即使容器/目录不完整也强制清理并幂等成功；重复删除返回成功。
- 不引入数据库；用户状态以 Docker 容器 + 数据目录为准，任务日志以 dagu 运行历史为准。
- 资源参数真实生效：`cpu_limit` → `--cpus`，`memory_limit` → `--memory`，`template_id` → 模板目录选择；`extra_config`（如 `enable_gpu`、`idle_timeout_hours`）本期仅透传记录、不生效。
- 模板清单 `dagu-gate/templates.yaml`：`template_id → {镜像, workspace 模板路径, opencode 配置模板路径, 默认 cpu/memory}`；默认 `tpl-dev-v2`；模板目录 `/opt/dagu-gate/templates/`，数据沿用 occ2-setup 的 user01（workspace + opencode.json）。
- 部署形态：单台 Ubuntu 主机、完全离线；Caddy 以容器方式运行（加入 dagu-net），dagu 以进程方式运行（单个静态二进制）；Docker 仅用于 Caddy 和用户容器。
- 用户访问入口：用户通过 `http://IP:9088/portal/u/{uid}` 进入生成物门户（Caddy 写 `ws_user` Cookie 后 302 到 `/portal`）；门户左侧为智能体对话（内嵌 opencode Web）、右侧为生成物列表与切换展示。
- 就绪判定只看 4096（OpenCode Web）；7010 相关（Python 静态服务 `serve_html.py`）不再使用。
- 容器管理直接用 `docker run` / `docker rm` 命令，不写 compose 文件。
- 空闲判定：最后活动时间 = max(活动日志中该 uid 的最后请求时间, 容器创建时间 CreatedAt)；阈值默认 360 分钟（6 小时），走 env（`IDLE_TIMEOUT_MINUTES`、`REAP_CRON`、`STOP_TIMEOUT`、`START_PAGE_REFRESH`）。
- 活动日志：Caddy JSON 访问日志（宿主 `logs/access.log`，`log_append` 写入 `uid` 字段），轮转 3 份 × 10MiB；`reap_idle` 读取解析，停止前二次确认避免误停刚有活动的容器。
- 恢复链路：Caddy 代理失败（容器不可达 → 502）且带 Cookie、非 `/api/*` 路径时返回启动页；页面 JS 调内部路由 `/api/v1/restart/{uid}`，Caddy 注入 `user_start` webhook token（env `WH_START_TOKEN`）后转发，token 不暴露给浏览器。
- 恢复动作 `user_start` 幂等：running → 等就绪；stopped → `docker start` + 等就绪；容器不存在 → 报错退出（启动页持续刷新，不影响 create/delete）。
- 本地工单系统：见 `.scratch/`（由 setup-matt-pocock-skills 配置），领域文档见 `docs/adr/`。

## 待确认（当前讨论中）

- 门户对 webhook 响应体已知偏差的最终态度（不影响开发推进）。
- 门户对非法 uid 不返回 400 的接受度（需要门户侧确认，不影响交付）；未知路径已统一返回 404。
