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
  ├── 控制面 /u/*、/api/v1/*  ──► workerd (:9090)   业务逻辑判断（JS）
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
  WebSocket/SSE，处理 `/app-proxy/<port>` 子应用
- 控制面：把 `/u/*`、`/api/v1/*` 原样转发给 workerd(:9090)
- 活动日志：每个请求写一行 JSON，`log_append` 把 Cookie 里的 uid 记进日志
- 启动页：容器不可达（502）且带 Cookie、非 `/api/` 路径时，返回“正在启动”页面
- 兜底：无 Cookie 访问数据面返回 401

### 2. workerd（进程，9090）

控制面业务逻辑，都在 `workerd/worker.js`：

| 路径 | 行为 |
| --- | --- |
| `/u/{uid}` | 校验 uid → 写 `ws_user` Cookie → 302 到 `/`；非法 uid 返回 400 |
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

## 四、各功能的实现要点与举例

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

### 功能 2：用户入口 `/u/{uid}`（写 Cookie + 跳转）

**为什么这样设计**：用户容器是动态命名的 `dagu-u-{uid}`，浏览器直接访问不了容器名，
需要网关按 uid 路由。但 `/u/{uid}` 本身不接触容器，它只做两件事：写 Cookie、跳首页。

**链路**：

```
浏览器 GET /u/usr_test01
  → Caddy 转发给 workerd
  → workerd 校验 uid，返回 302 + Set-Cookie: ws_user=usr_test01
  → 浏览器带着 Cookie 访问 /
  → Caddy 看到 Cookie，代理到 dagu-u-usr_test01:4096
```

**技术要点**：Cookie 是后续所有路由的“钥匙”；`/u/{uid}` 不算“活动”（它没碰容器）。

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

**触发方式**：门户带 token 调 `POST /api/v1/webhooks/user_delete`。

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

## 五、关键约定（领域术语）

| 术语 | 定义 |
| --- | --- |
| uid | 用户唯一标识，`^[A-Za-z0-9_-]{1,64}$`，用于容器名 `dagu-u-{uid}` 和数据目录 `users/{uid}` |
| 活动 | 带 `ws_user` Cookie 且被代理到容器的请求；`/u/{uid}` 入口不算 |
| 最后活动时间 | max(活动日志里该 uid 的最后请求时间, 容器创建时间) |
| 空闲回收 | 空闲超过 `IDLE_TIMEOUT_MINUTES`（默认 360 分钟）→ `docker stop` |
| webhook token | dagu 生成的鉴权 token，存在 `.webhook-tokens/`，门户和 workerd 用它鉴权 |
| 就绪 | 只看 4096（OpenCode Web）端口能应答 |

## 六、一次完整的用户生命周期（贯穿举例）

以 `usr_test01` 为例，串起所有功能：

```
1. 门户创建用户
   POST /api/v1/webhooks/user_create → 创建容器 dagu-u-usr_test01，等 4096 就绪

2. 用户首次进入
   GET /u/usr_test01 → 写 Cookie → 302 → / → 进入 OpenCode 工作区

3. 用户日常使用
   所有请求经 Caddy 代理，不断刷新“最后活动时间”

4. 用户离开，超过 6 小时
   reap_idle → docker stop，释放内存

5. 用户再次回来
   / 代理失败 → 启动页 → 自动触发 user_start → docker start → 回到工作区

6. 用户注销 / 不再需要
   POST /api/v1/webhooks/user_delete → 归档数据 → 删容器 → 删目录
```

## 七、离线交付形态

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

