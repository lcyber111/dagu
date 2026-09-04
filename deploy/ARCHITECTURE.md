# dagu-gate 技术路线与实现要点

本文档回答“系统是怎么搭起来的、每个功能具体怎么实现的”。它和另外两份文档互补：

- `README.md` —— 怎么部署、怎么手动测试（操作手册）
- `MIGRATION.md` —— 怎么迁移到新服务器（部署步骤）
- 本文档 —— 技术路线 + 各功能的实现要点、流程和举例（原理手册）

阅读本文不需要看代码，但会讲到“请求经过了哪几层、每一步发生了什么”。

## 一、一句话总览

dagu-gate 是一个**离线单机多租户开发环境网关**：每个用户一个 Docker 容器跑
OpenCode Web，网关负责路由、鉴权、按需创建/销毁/回收这些容器。

四个核心组件，各管一段：

```
浏览器
  │
  ▼
Caddy (:9088)        数据面：把用户流量代理进容器；记录活动日志；容器挂了返回启动页
  │
  ├── 控制面 /portal/*、/api/v1/*、/app/v1/*  ──► workerd (:9090)   业务逻辑判断（JS）
  │                                    │
  │                                    ▼
  │                              dagu (:18080)      任务编排引擎
  │                                    │ 跑 DAG 工作流，调用 bash 脚本
  │                                    ▼
  │                         create_user / delete_user / start_user / reap_idle
  │
  └── 数据面（带 ws_user Cookie）──► dagu-u-{uid}:4096   用户的 OpenCode 容器
```

一句话分工：**Caddy 是执行点，workerd 是决策点，dagu 是执行引擎，Docker 是承载用户环境。**

设计上刻意不引入数据库：用户状态以“Docker 容器 + 数据目录”为准，任务日志以 dagu
运行历史为准。这也让整个交付物保持“最少组件”——两个单二进制（dagu、workerd）

+ 一个 Caddy 容器，离线拷过去就能装。

## 二、技术路线为什么这么选

| 选型 | 理由 |
| --- | --- |
| Caddy 做数据面 | 成熟、反向代理 / WebSocket / SSE 开箱即用，用户容器长连接全走它 |
| workerd 做控制面 | 业务逻辑用 JS 写，比 Caddyfile 表达式好维护；单二进制、无运行时依赖 |
| dagu 做编排 | 创建/删除/恢复/回收是“多步骤任务”，用 DAG 表达比写死脚本清晰 |
| 不用数据库 | 单机离线、无强一致需求，容器和目录本身就是状态 |

关键原则：**数据面和控制面分离**。用户容器流量（高频、长连接）不经过 workerd 这个
JS 层；workerd 只处理低频的控制面请求（跳转、webhook、健康检查）。这样 JS 代码
出 bug 只影响“登录/跳转/触发”，不影响已经在容器里工作的用户。

## 三、组件职责明细

### 1. Caddy（容器，公网 9088）

- 数据面：把带 `ws_user` Cookie 的请求代理到 `dagu-u-{uid}:4096`，透传
  WebSocket/SSE；`/app/<port>` 子应用（App Worker 数据面）转发宿主机 workerd 分发
- 控制面：把 `/portal/*`、`/api/v1/*`、`/app/v1/*` 原样转发给 workerd(:9090)
- 活动日志：每个请求写一行 JSON，`log_append` 把 Cookie 里的 uid 记进日志
- 启动页：容器不可达（502）且带 Cookie、非 `/api/` 路径时，返回“正在启动”页面
- 兜底：白名单之外（无 Cookie / 未知路径）统一返回 404

### 2. workerd（进程，9090）

控制面业务逻辑，都在 `workerd/worker.js`：

| 路径 | 行为 |
| --- | --- |
| `/portal/u/{uid}` | 校验 uid → 写 `ws_user` Cookie → 302 到 `/portal`；非法 uid 返回 400 |
| `/portal`、`/portal/*` | 门户页与静态资产（disk 绑定 `$DAGU_ROOT/portal/`） |
| `/app/v1/*` | 轻应用控制面（list/sync/select/delete/apply/spec，内部校验 Cookie；refresh/apply/www/apply/meta 已删除） |
| `/app/<port>[/...]` | App Worker 数据面：按注册表分发到 app-<uid>-<appId>-<ver> service |
| `/api/v1/health` | 返回 `{"status":"healthy","timestamp":...}` |
| `/api/v1/webhooks/*` | 校验 Bearer token（对照 token 文件）→ 原样透传给 dagu |
| `/api/v1/restart/{uid}` | 浏览器直连、无外部 token → 注入 user_start 的 token → 转发 dagu |
| 其他 | 返回 404 |

workerd 通过两种“绑定”拿到资源：`env.dagu`（dagu 地址，用来转发）、
`env.tokens`（`.webhook-tokens/` 目录，只读，用来读 token）。它默认访问不了任何
网络和文件，必须在配置里显式授予——这就是它的“能力绑定”安全模型。

### 3. dagu（进程，18080）

任务编排引擎，定义了四个 DAG 工作流（`dags/*.yaml`，由模板渲染）：

- `user_create`：创建用户环境
- `user_delete`：销毁用户环境
- `user_start`：恢复被回收的容器
- `reap_idle`：定时回收空闲容器

每个工作流本质上就是“执行一个 bash 脚本”，脚本在 `scripts/` 目录。
门户通过 `POST /api/v1/webhooks/{dagName}`（带 webhook token）触发，异步执行。

### 4. 用户容器（`dagu-u-{uid}:4096`）

每个用户一个独立 Docker 容器，跑 OpenCode Web。创建时挂载用户的 workspace 和
opencode 配置，用 `--cpus`/`--memory` 限制资源。

## 四、访问规则（Caddy 路由）与举例

请求进入 Caddy 后，规则是**从上到下依次匹配、命中即停**。总口诀：
**先认路径（`/api/v1`、`/portal`、`/app`），再认 Cookie（进谁的容器），最后才是统一 404 和启动页两个兜底。**

### 规则 0：全局设置 + 访问日志（影响所有请求）

```caddyfile
auto_https off        # 关闭 HTTPS 自动跳转（纯 HTTP 9088 运行）
admin off             # 关闭 Caddy 管理端口
log_append uid "{http.request.cookie.ws_user}"
```

`log_append` 让**每个请求**都在日志里多记一个 `uid` 字段（从 Cookie 取），
`reap_idle` 靠它判断“最后活动时间”。带 `ws_user=usr_test01` 的请求会记
`"uid":"usr_test01"`，不带 Cookie 记空值。

### 规则 1：`/api/v1/*` → 转发给 workerd

```caddyfile
handle /api/v1/* {
    reverse_proxy 172.17.0.1:9090
}
```

路径以 `/api/v1/` 开头一律转给 workerd（9090），与 Cookie 无关。

举例：

```bash
curl http://192.168.252.131:9088/api/v1/health
# → workerd，返回 {"status":"healthy",...}

curl -X POST http://192.168.252.131:9088/api/v1/webhooks/user_create \
  -H "Authorization: Bearer <token>"
# → workerd，校验 token 后透传给 dagu

curl -X POST http://192.168.252.131:9088/api/v1/restart/usr_test01
# → workerd，注入 token 后转给 dagu 的 user_start
```

### 规则 2：`/portal/*` → 转发给 workerd（门户入口 + 门户页/静态资产）

```caddyfile
handle /portal/* {
    reverse_proxy 172.17.0.1:9090
}
handle /portal {
    reverse_proxy 172.17.0.1:9090
}
```

举例（即使带了 Cookie，也走这条，不会直接进容器）：

```bash
curl -i http://192.168.252.131:9088/portal/u/usr_test01
# → workerd → 302，响应头：Location: /portal 和 Set-Cookie: ws_user=usr_test01

curl -i http://192.168.252.131:9088/portal
 # → workerd → 门户页（左侧智能体对话 + 右侧生成物画廊）
```

### 规则 3：带 `ws_user` Cookie → 进容器（核心规则）

```caddyfile
@get_user header_regexp cookie_user Cookie (?:^|;\s*)ws_user=([a-zA-Z0-9_.-]+)
```

Caddy 用正则从 Cookie 里抠出 uid，拼成 `dagu-u-{uid}` 转发。里面分两种情况：

**5a. `/app/<端口>[/<路径>]` → 宿主机 workerd，App Worker 数据面（根路径与子路径同一规则）**

```bash
curl -H "Cookie: ws_user=usr_test01" http://192.168.252.131:9088/app/20014/svc/health
# → 转发到 workerd(:9090)，按注册表分发到 app-usr_test01-<appId>-v1
curl -H "Cookie: ws_user=usr_test01" http://192.168.252.131:9088/app/20014
# → workerd → App Worker 首页
```

**5b. 其余所有路径 → 容器 4096（OpenCode 主应用）**

```bash
curl -H "Cookie: ws_user=usr_test01" http://192.168.252.131:9088/
curl -H "Cookie: ws_user=usr_test01" "http://192.168.252.131:9088/new-session?draftId=abc"
curl -H "Cookie: ws_user=usr_test01" http://192.168.252.131:9088/global/health
# 以上都到 dagu-u-usr_test01:4096（心跳轮询也走这里）
```

转发时 Caddy 还会改写 `Host: localhost:4096`、`Origin`、`X-Forwarded-*` 等请求头，
让容器里的 OpenCode 以为请求来自本机。

### 规则 6：统一错误兜底（白名单之外 → 404）

门户/控制面/数据面白名单全部未命中（无 Cookie、未知路径）时，
落到最后一个兜底直接返回 404，不保留任何旧路径兼容、不显示引导页：

```caddyfile
handle {
	respond "not found" 404
}
```

举例：

```bash
curl http://192.168.252.131:9088/
# → 404（无 Cookie，白名单之外）
curl http://192.168.252.131:9088/workspace
# → 404（旧路径，无专门路由）
curl http://192.168.252.131:9088/apps
# → 404（旧路径，无专门路由）
```

### 规则 7：出错兜底 handle_errors（502 → 启动页）

这条不是按路径匹配，而是**前面任何一步返回 502 时**触发，三个条件同时满足：

```caddyfile
@stopped expression `{err.status_code} == 502 && {http.request.cookie.ws_user} != "" && ({http.request.uri.path}.startsWith("/api/") == false) && ({http.request.uri.path}.startsWith("/app/") == false) && ({http.request.uri.path}.startsWith("/portal/") == false)`
```

即：错误是 502、带了 `ws_user` Cookie、路径不是 `/api/`、`/app/`、`/portal/` 开头。

举例（容器被回收后用户刷新页面）：

```text
刷新 /new-session?draftId=abc（带 Cookie）
→ 规则 5c 转发容器失败，产生 502
→ 命中 @stopped → 返回“正在启动，资源重新分配中…”页面
→ 页面 JS 自动调 /api/v1/restart/{uid} 触发恢复
```

### 决策顺序图

```text
请求进来
  │
  ├─ /api/v1/*         → workerd（规则1）
  ├─ /app/v1/*         → workerd（规则1b：轻应用控制面）
  ├─ /portal/*、/portal → workerd（规则2）
  ├─ 带 ws_user Cookie（规则3）
  │     ├─ /app/<port>[/...]  → workerd 按注册表分发（5a）
  │     └─ 其他               → 容器:4096（5b，OpenCode 主应用）
  └─ 白名单之外 → 404（规则6，统一错误兜底）
  └─ （任何一步 502）→ 启动页（规则7，/api/ /app/ /portal/ 前缀除外）
```

### 一张表总结

| 路径 | 带 Cookie？ | 最终去向 | 结果 |
| --- | --- | --- | --- |
| `/api/v1/*` | 带或不带都行 | workerd:9090 | dagu 平台控制面 |
| `/app/v1/*` | 带或不带都行 | workerd:9090 | 轻应用控制面（内部校验 Cookie） |
| `/portal/u/{uid}`、`/portal` | 带或不带都行 | workerd:9090 | 门户入口 / 门户页 |
| `/app/<port>[/...]` | 带 | workerd:9090 | App Worker 数据面 |
| `/`、`/new-session...`、静态资源 | 带 | 容器:4096 | OpenCode 工作区页面 |
| 白名单之外任意路径 | 不带 | 无 | 404 |

> 路由面采用**白名单 + 统一错误兜底**：旧路径（`/workspace`、`/app-proxy`、`/u/`、
> `/apps`、`/mdview` 等）在网关层**不做任何专门路由**——带 Cookie 时被 OpenCode 主应用
> （SPA，全路径）吸收，无 Cookie 时落入统一兜底 **404**。门户入口统一为 `/portal/u/{uid}`。

## 五、各功能的实现要点与举例

### 功能 1：创建用户（user_create）

**触发方式**：门户带 webhook token 调 `POST /api/v1/webhooks/user_create`。

**完整链路**：

```
门户 → Caddy(:9088) → workerd(:9090) 校验 token → 透传 dagu(:18080)
     → 触发 user_create DAG → create_user.sh
```

**create_user.sh 干的事**（按顺序）：

1. 校验 uid 格式（`^[A-Za-z0-9_-]{1,64}$`），非法直接失败
2. **幂等检查**：容器已存在且镜像一致 → 若停了就 `docker start` 并等就绪，直接成功
3. 从 `templates.yaml` 按 `template_id` 查到镜像、workspace 模板、opencode 配置、默认资源
4. 把模板拷到 `users/{uid}/`，并注入 `server.json`（写入网关地址，供前端用）
5. `docker run -d`：指定镜像、网络 `dagu-net`、`--cpus`/`--memory`、挂载 workspace 和 opencode.json
6. 等 4096 端口就绪（默认 60 秒超时）
7. 任一步失败 → 清理本次创建的容器和目录，返回失败

**举例**（创建用户 usr_test01）：

```bash
CREATE_TOKEN=$(cat /home/li/dagu-run/.webhook-tokens/user_create.token)
curl -X POST http://192.168.252.131:9088/api/v1/webhooks/user_create \
  -H "Authorization: Bearer $CREATE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"uid":"usr_test01","username":"张三","resources":{"cpu_limit":"2","memory_limit":"4Gi","template_id":"tpl-dev-v2"}}'
# 返回 {"dagName":"user_create","dagRunId":"..."}，容器在后台约 30~60 秒就绪
```

### 功能 2：门户入口 `/portal/u/{uid}`（写 Cookie + 跳转）

**为什么这样设计**：用户容器是动态命名的 `dagu-u-{uid}`，浏览器直接访问不了容器名，
需要网关按 uid 路由。但 `/portal/u/{uid}` 本身不接触容器，它只做两件事：写 Cookie、跳门户。

**链路**：

```
浏览器 GET /portal/u/usr_test01
  → Caddy 转发给 workerd
  → workerd 校验 uid，返回 302 + Set-Cookie: ws_user=usr_test01
  → 浏览器带着 Cookie 访问 /portal（门户：左侧对话 + 右侧生成物）
  → 门户内 iframe 打开工作区/大屏时，Caddy 看到 Cookie 代理到对应目标
```

**技术要点**：Cookie 是后续所有路由的“钥匙”；`/portal/u/{uid}` 不算“活动”（它没碰容器）。

### 功能 3：空闲回收（reap_idle）

**触发方式**：`reap_idle` 工作流按 cron 调度，默认每分钟跑一次（`REAP_CRON`）。

**流程**：

1. `docker ps` 列出正在运行的 `dagu-u-*` 容器，取各自的创建时间
2. 读 Caddy 的 JSON 日志 `logs/access.log`，按 uid 找“最后一次请求时间”
3. 最后活动时间 = max(日志里的最后请求时间, 容器创建时间)
4. 空闲时长 ≥ `IDLE_TIMEOUT_MINUTES`（默认 360 分钟 = 6 小时）→ 进入待停名单
5. **停止前再读一次日志二次确认**，避免误停刚有请求的容器
6. `docker stop -t 30`

**“活动”的定义**：带 `ws_user` Cookie 且被代理到容器的任何请求（页面、静态资源、
WebSocket/SSE 都算）。注意 opencode 前端每 10 秒有 `/global/health` 心跳轮询，
所以“标签页开着”会被持续算作活动——这是当前已知的取舍。

**举例（时间线）**：

| 时间 | 事件 |
| --- | --- |
| 10:00 | 创建容器 usr_test01，最后活动初始值 = 容器创建时间 |
| 10:00~10:20 | 用户工作，每次请求都刷新最后活动时间 |
| 10:20 | 用户关闭页面，流量停止 |
| 10:21~16:19 | 每分钟检查，空闲 < 6 小时，不动 |
| 16:20 | 空闲 = 6 小时 → `docker stop`，释放内存 |

### 功能 4：启动页与自动恢复（user_start）

**场景**：容器被回收后，用户再次访问会触发自动拉起。

**链路**：

```
用户访问 /（带 Cookie）
  → Caddy 代理失败（容器没起，502）
  → Caddy handle_errors 命中，返回“正在启动，资源重新分配中…”页面
  → 页面里的 JS 自动 fetch POST /api/v1/restart/{uid}
  → Caddy 转发给 workerd
  → workerd 从 token 文件读 user_start 的 token，注入后转发 dagu
  → user_start DAG → start_user.sh → docker start + 等 4096 就绪
  → 页面每 5 秒自动刷新（meta refresh），容器就绪后刷新成功，进入工作区
```

**技术要点**：

- 页面不是“跳转”进去的，是靠 meta refresh 轮询同一个 URL，直到代理从 502 变 200
- 恢复请求每 30 秒最多触发一次（防重复轰炸 dagu），失败会自动重试
- `user_start` 是幂等的：`docker start` 对已运行的容器是 no-op
- token 由 workerd 服务端注入，浏览器永远拿不到

**举例**：容器被回收后，浏览器刷新 → 看到“正在启动”页 → 2~3 秒后自动进入工作区。

### 功能 5：删除用户（user_delete）

**触发方式**：门户带 token 调 `POST /api/v1/webhooks/user_delete`

**流程**：

1. `archive_data=true`（默认）时，先把 `users/{uid}/` 打成 tar.gz 存到 `archive/`
2. `docker rm -f` 删容器
3. 删除用户数据目录；符号链接需要 `force=true` 才删
4. 重复删除返回成功（幂等）

**举例**：

```bash
DELETE_TOKEN=$(cat /home/li/dagu-run/.webhook-tokens/user_delete.token)
curl -X POST http://192.168.252.131:9088/api/v1/webhooks/user_delete \
  -H "Authorization: Bearer $DELETE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"uid":"usr_test01","archive_data":true}'
```

## 六、关键约定（领域术语）

| 术语 | 定义 |
| --- | --- |
| uid | 用户唯一标识，`^[A-Za-z0-9_-]{1,64}$`，用于容器名 `dagu-u-{uid}` 和数据目录 `users/{uid}` |
| 活动 | 带 `ws_user` Cookie 且被代理到容器的请求；`/portal/u/{uid}` 入口不算 |
| 最后活动时间 | max(活动日志里该 uid 的最后请求时间, 容器创建时间) |
| 空闲回收 | 空闲超过 `IDLE_TIMEOUT_MINUTES`（默认 360 分钟）→ `docker stop` |
| webhook token | dagu 生成的鉴权 token，存在 `.webhook-tokens/`，门户和 workerd 用它鉴权 |
| 就绪 | 只看 4096（OpenCode Web）端口能应答 |

## 七、一次完整的用户生命周期（贯穿举例）

以 `usr_test01` 为例，串起所有功能：

```
1. 门户创建用户
   POST /api/v1/webhooks/user_create → 创建容器 dagu-u-usr_test01，等 4096 就绪

2. 用户首次进入
   GET /portal/u/usr_test01 → 写 Cookie → 302 → /portal → 门户（对话 + 生成物）

3. 用户日常使用
   所有请求经 Caddy 代理，不断刷新“最后活动时间”

4. 用户离开，超过 6 小时
   reap_idle → docker stop，释放内存

5. 用户再次回来
   / 代理失败 → 启动页 → 自动触发 user_start → docker start → 回到工作区

6. 用户注销 / 不再需要
   POST /api/v1/webhooks/user_delete → 归档数据 → 删容器 → 删目录
```

## 八、离线交付形态

交付包 = 两个单二进制 + 一个 Caddy 镜像 + 脚本/模板/配置：

- `dist/dagu-linux-amd64`：dagu 编排引擎
- `dist/workerd-linux-amd64`：workerd 控制面逻辑服务
- `caddy.2.11.4.tar`、`opencode-*.tar.gz`：离线镜像（现场提供）
- `scripts/install.sh`：一键安装，渲染模板、启动 dagu/workerd/Caddy、初始化 token
- `deploy/dags/*.tpl`、`workerd/config.capnp.tpl`：机器相关的配置由 install.sh 渲染

部署根目录（本机为 `/home/li/dagu-run`）下：

```
dagu-run/
├── dagu                      # dagu 二进制
├── dags/*.yaml               # 渲染后的工作流
├── scripts/*.sh              # 工作流调用的脚本
├── gateway/                  # Caddy 配置 + docker-compose
├── workerd/                  # workerd 二进制 + 渲染后的 config.capnp + worker.js
├── templates/ + templates.yaml  # 用户环境模板
├── users/{uid}/              # 每个用户的数据目录
├── archive/                  # 删除用户时的归档
├── logs/access.log           # Caddy 活动日志（reap_idle 依赖）
├── logs/workerd-access.log   # workerd 日志（仅排障）
└── .webhook-tokens/*.token   # webhook 鉴权 token
```

## 九、App Worker 运行时（C+，2026-08-24）

### 定位

大屏从"生成期静态快照"演进为"运行时应用"：**每个大屏 = 宿主机 workerd 内的一个 App Worker（独立 service/isolate）**，agent 编写完整 ES 模块（worker.js），前端经 disk 绑定托管、数据存 DO SQLite（快照模式：仅一行 spec）、spec 经 /svc/spec 入库并由页面运行时拉取渲染、实时推送走 /svc/events（SSE，内部 WebSocket 桥接 Hub DO）。控制面 workerd 兼任 router（按注册表分发）。详见 ADR-0003。

### 架构图（叠加在既有链路上）

``
浏览器（/portal 门户页 · 新标签页打开大屏）
   │  /portal、/api/v1/*、/app/v1/*、/app/2xxxx
Caddy :9088 ──────────────────────────────
   ├─ /api/v1/*、/portal/*、/app/v1/*、/app/2xxxx → workerd :9090（单进程）
   │     ├─ gatewayWorker：控制面 + router（每请求读 apps.json）
   │     ├─ app-<uid>-<appId>-<version> × N（独立 service/isolate）
   │     │     ├─ worker.js（agent 编写；页面 + /svc/spec + SQLite + /svc/events SSE）
   │     │     ├─ www/（disk）· lib（共享 app-libs）· data-<ver>（SQLite, writable）
   │     │     └─ DO：AppStore（enableSql）+ Hub（WebSocket Hibernation，供 /svc/events 内部桥接）
   │     └─ 守护/监控/审计：workerd_guard · app_monitor · app_audit
   └─ 容器 dagu-u-{uid}：opencode(4096)（agent 编辑端）+ 存量 serve_html（过渡）

dagu 定时 DAG：app_sync_data（跑各 app 的 sync_merge.py 快照合并）· app_monitor · workerd_guard · app_audit
``

### 关键机制

- **注册表驱动路由**：gateway 每请求读 users/<uid>/workspace/.apps/apps.json；发布/切版本/回滚 = 改 manifest，零 config 零重启（新 app/新版本首次出现才经 app_sync 重建 config + 热加载）；
- **每 app/版本独立 isolate**：数据/代码/故障域隔离；SQLite 按版本独立目录；
- **实时数据**：app_sync_data 每 5 分钟在容器内跑各 app 的 `sync_merge.py`（查 Doris/MySQL → 按 key 合并进 spec，旧数据保留、不新增行）→ POST `/svc/spec` → SSE（内部 WebSocket 桥接 Hub DO Hibernation）推送前端无感刷新；
- **安全**：Cookie（uid 级）鉴权 + app 归属校验；不启用 per-app token（M3 曾引入，本轮按需求移除）；
- **生命周期**：pp_sync（发布）、pp_delete（删除+归档+重建）、版本文件不覆盖；
- **可靠性与可观测**：config 先 workerd compile 校验再覆盖；workerd_guard 自动拉起；pp_monitor 巡检配额/同步；pp_audit 汇总操作审计。

### 数据流

- 生成期：需求理解 → db_query 查库 → 构造 spec → 写 .apps/（www + v1.js + sync_merge.py + apps.json 登记 sync）→ app_sync 发布 → POST /svc/spec 入库；
- 运行期：前端 /svc/spec 拉取渲染 + 轮询兜底 + /svc/events（SSE）实时推送；pp_sync_data 每 5 分钟跑各 app 的 sync_merge.py（快照合并，旧数据保留）写回 /svc/spec；
- 版本：direct 测试 → manifest 切默认版本（零重启，在途 v1 自然完成）。

### 边界与约束（实现要点）

- capnp embed 相对配置文件目录、不支持绝对路径；disk 路径相对 workerd CWD；
- DO 数据盘 writable=true；.apps 访问需 allowDotfiles=true；DO namespace 需显式绑定；
- DO 存储锁：同一数据目录单实例；workerd 重启须等旧进程退出；
- --watch 只监听 config：改 worker.js 必须发布（app_sync）。
