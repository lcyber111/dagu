# dagu-gate 离线交付与部署

## 交付物清单

| 内容 | 位置 | 说明 |
| --- | --- | --- |
| dagu 二进制 | `dist/dagu-linux-amd64` | Linux amd64，交叉编译自 dagu-main |
| workerd 二进制 | `dist/workerd-linux-amd64` | 控制面逻辑服务运行时（Cloudflare 开源 JS 运行时） |
| 工作流定义 | `dags/user_create.yaml`、`dags/user_delete.yaml`、`dags/user_start.yaml`、`dags/reap_idle.yaml` | 创建/删除/恢复用户环境 + 空闲回收 |
| 模板清单 | `templates.yaml` | `template_id` → 镜像/workspace/opencode 配置/默认资源 |
| 模板数据 | `deploy/templates/tpl-dev-v2.tar.gz` | workspace + opencode.json |
| 网关配置 | `gateway/Caddyfile` + `gateway/docker-compose.yml` | Caddy 网关（9088）：数据面代理、活动日志、启动页 |
| 控制面逻辑 | `workerd/config.capnp.tpl` + `workerd/worker.js` | workerd（9090）：`/u/{uid}`、health、webhook 鉴权转发、restart |
| 活动日志 | 安装后生成于 `logs/access.log` | Caddy JSON 访问日志（含 `uid` 字段），供 `reap_idle` 判定活动 |
| 运行脚本 | `scripts/create_user.sh`、`scripts/delete_user.sh`、`scripts/start_user.sh`、`scripts/reap_idle.sh` | 工作流调用的容器操作 |
| dagu 配置 | `deploy/base.yaml`、`deploy/base.dag.yaml` | 扁平 schema；DAG 基础配置与 CLI 配置分离 |
| 安装脚本 | `scripts/install.sh` | 一键离线安装（幂等） |
| 冒烟测试 | `scripts/smoke-test.sh` | 契约 + 创建/访问/空闲回收/恢复/删除全流程 |
| 离线镜像 | 由现场提供 | `opencode-*.tar.gz`、`caddy.2.11.4.tar` |

## 部署步骤（离线 Ubuntu 主机）

1. 准备目录并放入镜像压缩包（路径可用环境变量覆盖，见 `install.sh`）：
   - `/home/li/dagu/opencode-1.17.10-custom-nods-python-pandas.tar.gz`
   - `/home/li/dagu/caddy.2.11.4.tar`
2. 运行安装：
   ```bash
   bash scripts/install.sh
   ```
   安装脚本会：建目录 → 建 `dagu-net` 网络 → 加载镜像 → 拷贝运行文件 → 写 dagu 与 workerd 配置 → 启动 dagu（start-all）→ 初始化 webhook token（存 `.webhook-tokens/`）→ 启动 workerd 并健康检查 → 校验并启动 Caddy 网关。
3. 查看 webhook token 并配置到门户侧：
   ```bash
   cat /home/li/dagu/dagu-gate/.webhook-tokens/user_create.token
   cat /home/li/dagu/dagu-gate/.webhook-tokens/user_delete.token
   ```

## 接口（门户视角，Base URL `http://<IP>:9088/api/v1`）

- `POST /webhooks/user_create`：Bearer token；body `{"uid","username","resources":{"cpu_limit","memory_limit","template_id"}}`
- `POST /webhooks/user_delete`：Bearer token；body `{"uid","force","archive_data"}`
- `GET /health`：`{"status":"healthy","timestamp":...}`
- 用户访问入口：`http://<IP>:9088/u/{uid}`（写 `ws_user` Cookie 后路由到用户容器 4096）
- `POST /api/v1/restart/{uid}`（内部接口）：启动页 JS 触发容器恢复，workerd 注入 token 后转发 `user_start` webhook

## 架构：Caddy 数据面 + workerd 控制面

```
浏览器 → Caddy(:9088) ── 数据面（用户容器流量、WS/SSE、启动页、401 兜底、活动日志）
                     └── 控制面（/u/*、/api/v1/*）→ workerd(:9090) → dagu
```

- Caddy 只做转发和代理，业务判断逻辑（写 Cookie、302、webhook 鉴权、token 注入）全部在
  `workerd/worker.js` 中实现（JS）。
- 用户容器流量不经过 workerd，WebSocket/SSE 长连接由 Caddy 直接代理。
- workerd 以裸进程运行（和 dagu 一样由 `install.sh` 启动），监听 `0.0.0.0:9090`，
  日志在 `$DAGU_ROOT/logs/workerd-access.log`（仅排障用，活动判定仍以 Caddy 日志为准）。
- webhook token 由 workerd 从 `.webhook-tokens/` 目录只读读取，不暴露给浏览器。

## 手动测试（curl 命令）

环境信息：

- 网关入口（门户视角）：`http://192.168.252.131:9088`
- dagu 管理接口（宿主机）：`http://172.17.0.1:18080`
- 管理员账号：`admin` / `dagu-gate-2026`
- webhook token 文件（VM 上）：`/home/li/dagu/dagu-gate/.webhook-tokens/user_create.token`、`user_delete.token`

约定：以下命令在 VM（192.168.252.131）的 bash 里执行；uid 格式 `^[A-Za-z0-9_-]{1,64}$`（如 `usr_10086`）；创建用户是异步的——接口立即返回 200，容器在后台创建（约 30~60 秒就绪）。

### 0) 健康检查

```bash
curl -s http://192.168.252.131:9088/api/v1/health
```

预期：`{"status":"healthy","timestamp":"..."}`

### 1) 管理员登录（拿 JWT，用于管理接口）

```bash
curl -s -X POST http://172.17.0.1:18080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"dagu-gate-2026"}'
```

预期：返回 `{"token":"eyJhbGciOi...","expiresAt":"...","user":{...}}`。保存变量供后续使用：

```bash
ADMIN_TOKEN=$(curl -s -X POST http://172.17.0.1:18080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"dagu-gate-2026"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
```

### 2) 注册新用户（触发 user_create 工作流）

```bash
CREATE_TOKEN=$(cat /home/li/dagu/dagu-gate/.webhook-tokens/user_create.token)

curl -s -w '\nHTTP:%{http_code}\n' -X POST \
  http://192.168.252.131:9088/api/v1/webhooks/user_create \
  -H "Authorization: Bearer $CREATE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "uid": "usr_test01",
    "username": "张三",
    "resources": {
      "cpu_limit": "2",
      "memory_limit": "4Gi",
      "template_id": "tpl-dev-v2"
    },
    "extra_config": {
      "enable_gpu": false
    }
  }'
```

预期：HTTP 200，返回 `{"dagName":"user_create","dagRunId":"..."}`。此接口立即返回，容器异步创建中。

### 2.1) 查看任务是否成功（可选）

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://172.17.0.1:18080/api/v1/dags/user_create/dag-runs | head -c 1200
```

看最新一条的 `statusLabel`：`succeeded` = 成功，`failed` = 失败（可查日志）。

### 2.2) 检查容器是否就绪（可选）

```bash
for i in $(seq 1 30); do
  IP=$(docker inspect --format '{{(index .NetworkSettings.Networks "dagu-net").IPAddress}}' dagu-u-usr_test01 2>/dev/null || true)
  if [ -n "$IP" ] && curl -s -o /dev/null --max-time 2 "http://$IP:4096/"; then
    echo "容器已就绪: $IP:4096"; break
  fi
  sleep 3
done
```

### 3) 访问已创建的用户容器（OpenCode 工作区）

浏览器方式（最直观）：打开 `http://192.168.252.131:9088/u/usr_test01`，网关写入 `ws_user` Cookie 并跳到工作区页面。

curl 方式：

```bash
# 第一步：访问 /u/{uid}，让网关写入 Cookie
curl -s -c /tmp/occ-cookie -o /dev/null -w 'entry HTTP:%{http_code}\n' \
  http://192.168.252.131:9088/u/usr_test01

# 第二步：带上 Cookie 访问工作区根路径，预期 200（代理到 dagu-u-usr_test01:4096）
curl -s -b /tmp/occ-cookie -o /dev/null -w 'page HTTP:%{http_code}\n' \
  --max-time 15 http://192.168.252.131:9088/

# 反例：不带 Cookie 访问，预期 401
curl -s -o /dev/null -w 'no-cookie HTTP:%{http_code}\n' \
  http://192.168.252.131:9088/
```

### 4) 删除用户（触发 user_delete 工作流）

```bash
DELETE_TOKEN=$(cat /home/li/dagu/dagu-gate/.webhook-tokens/user_delete.token)

curl -s -w '\nHTTP:%{http_code}\n' -X POST \
  http://192.168.252.131:9088/api/v1/webhooks/user_delete \
  -H "Authorization: Bearer $DELETE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "uid": "usr_test01",
    "archive_data": true
  }'
```

预期：HTTP 200，返回 `{"dagName":"user_delete","dagRunId":"..."}`。约 10 秒后验证：

```bash
# 容器应不存在
docker ps -a | grep dagu-u-usr_test01 || echo "容器已删除"
# 用户数据目录应不存在
ls /home/li/dagu/dagu-gate/users/usr_test01 2>/dev/null || echo "用户目录已删除"
# 归档文件应存在（archive_data=true 时）
ls -1 /home/li/dagu/dagu-gate/archive/ | tail -3
```

### 5) 重新生成 webhook token（可选，token 泄露时用）

```bash
# 需要先登录拿 ADMIN_TOKEN（见第 1 节）
curl -s -X DELETE \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://172.17.0.1:18080/api/v1/dags/user_create/webhook

curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://172.17.0.1:18080/api/v1/dags/user_create/webhook

# 返回的 token 只在这次显示，记得保存：
# echo "<新token>" > /home/li/dagu/dagu-gate/.webhook-tokens/user_create.token
```

## 空闲回收与按需恢复

用户容器（`dagu-u-{uid}`）空闲超过 `IDLE_TIMEOUT_MINUTES`（默认 360 分钟，即 6 小时）后，`reap_idle` 定时工作流会将其 `docker stop`，释放内存；用户再次访问时，网关检测到容器不可达，返回"正在启动，资源重新分配中"页面并自动触发恢复，就绪后自动进入工作区。

### 活动判定口径

"活动" = 带 `ws_user` Cookie 且被代理到用户容器的任何请求（页面、静态资源、WebSocket/SSE 都算）。

- `/u/{uid}` 入口不算活动：它只写 Cookie 后 302 跳转，不接触容器。
- 最后活动时间 = 最后一次代理请求的时间；容器被 stop 后再次访问，恢复成功后才重新计时。
- 新容器初始值 = 容器创建时间（`docker inspect` 的 CreatedAt），即创建后至少给足 6 小时宽限期；创建后一直没人访问的容器，满 6 小时也会被回收。
- 启动页自愈：页面每 5 秒自动刷新，恢复请求每 30 秒最多触发一次，失败会自动重试（`user_start` 幂等），不会永久卡在"正在启动"页。

三个例子：

1. 用户 10:00 创建容器，之后一直没人访问：16:00 起被回收（初始值 = 创建时间）。
2. 用户 10:00 进入工作区工作到 10:20 后关闭页面：16:20 起被回收（最后活动 ≈ 10:20）。
3. 用户 10:00 进入工作区后把标签页一直挂着（有轮询/心跳）：持续算活动，不会被回收——这是"有流量 = 有人用"口径的已知取舍。

### 完整生命周期

| 时间 | 事件 |
| --- | --- |
| 10:00 | `user_create` 完成，容器创建（最后活动初始值 = 创建时间） |
| 10:00~10:20 | 用户工作，每次代理请求都刷新最后活动时间 |
| 10:20 | 用户关闭页面，流量停止 |
| 10:21~16:19 | `reap_idle` 每分钟检查一次，空闲 < 6 小时，不动 |
| 16:20 | `reap_idle`：空闲 = 6 小时 → `docker stop -t 30`，内存释放 |
| 16:30 | 用户点 `/u/{uid}`（不算活动）→ 302 → Caddy 代理失败（502）→ 返回启动页 → 页面 JS 调 `/api/v1/restart/{uid}` |
| 16:30~16:31 | workerd 注入 token 转发 `user_start` webhook → `docker start` + 等 4096 就绪 |
| 16:31 | 页面自动刷新进入工作区，重新开始记录活动 |

### 相关配置（env）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IDLE_TIMEOUT_MINUTES` | 360 | 空闲阈值（分钟，6 小时） |
| `REAP_CRON` | `* * * * *` | `reap_idle` 的 cron（5 段式，dagu v2 不支持秒字段） |
| `STOP_TIMEOUT` | 30 | `docker stop -t` 超时（秒） |
| `START_PAGE_REFRESH` | 5 | 启动页自动刷新间隔（秒） |
| `GATEWAY_UID` / `GATEWAY_GID` | 1000 / 1000 | Caddy 容器运行 uid/gid（需与宿主部署用户一致，保证日志可读） |

### 手动验证（VM 上执行）

```bash
# 1) 手动模拟空闲回收
docker stop dagu-u-usr_test01

# 2) 带 Cookie 访问工作区 -> 预期 200，返回"正在启动"页面
curl -s -b /tmp/occ-cookie -w '\nHTTP:%{http_code}\n' --max-time 15 http://192.168.252.131:9088/

# 3) 模拟页面 JS，触发恢复
curl -s -b /tmp/occ-cookie -X POST http://192.168.252.131:9088/api/v1/restart/usr_test01 \
  -H 'Content-Type: application/json' \
  -d '{"payload":{"uid":"usr_test01"}}'

# 4) 等就绪后再次访问 -> 预期进入工作区（200）
for i in $(seq 1 20); do
  if curl -s -b /tmp/occ-cookie -o /dev/null --max-time 15 http://192.168.252.131:9088/; then break; fi
  sleep 3
done
curl -s -b /tmp/occ-cookie -o /dev/null -w 'page HTTP:%{http_code}\n' --max-time 15 http://192.168.252.131:9088/
```

### 已知边界

- 标签页开着但人不在：轮询/心跳会持续刷新计时，容器不会被回收。
- `/api/v1/restart/{uid}` 与 `/u/{uid}` 一样无独立鉴权（恢复 token 由 Caddy 注入，不暴露给浏览器）；攻击者最多让已存在的容器重启，容器有资源限制。
- `reap_idle` 每分钟产生一条运行记录（约 1440 条/天），可在 dagu UI 过滤；介意可调大 `REAP_CRON` 间隔。
- 容器不存在/创建中/删除中：启动页统一文案并持续刷新，`user_start` 失败不影响现有 create/delete 流程。
- 活动日志由 Caddy 写入 `logs/access.log`（轮转保留 3 份 × 10MiB）；`docker compose logs` 不再包含访问日志，只含 Caddy 运行日志。

## 已知限制（与接口文档的偏差）

- webhook 响应体为 dagu 原生 `{dagRunId, dagName}`，不是文档示例的 `{taskId, message, status}`（workerd 原样透传，未引入翻译层）。
- webhook 请求体原样透传，不在 HTTP 层校验 uid/字段（校验发生在工作流内部并失败）；`/u/{uid}` 入口的非法 uid 由 workerd 返回 **400**。
- 未知 webhook 路径由 workerd 返回 **404**，与文档一致。
- `/api/v1/health` 的 `timestamp` 为 Caddy `{time.now}` 输出，非 ISO8601。

## 排障

- 任务不执行：确认用的是 `dagu start-all`（`server` 只排队）。
- 新增 DAG 不生效：重启 dagu。
- 创建报"docker network ... does not exist"：`docker network create dagu-net`。
- 容器反复重启：检查镜像 ENTRYPOINT（`opencode`），`docker run` 不要传多余命令。
