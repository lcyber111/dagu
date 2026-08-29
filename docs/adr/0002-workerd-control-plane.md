# ADR-0002：workerd 控制面逻辑服务（Caddy 前、workerd 后）

状态：已接受（阶段一）
日期：2026-08-14

## 背景

现在 dagu-gate 的网关（Caddy）承担了所有工作：既要转发用户容器流量，又要用
Caddyfile 的表达式写业务逻辑（写 Cookie、302 跳转、启动页判断、webhook 转发、
token 注入）。逻辑一多，Caddyfile 就变得绕、难读、难维护。

因此引入 workerd（Cloudflare 开源的 JS 运行时）作为“控制面逻辑服务”：
**Caddy 继续守前门、转发容器流量；业务判断逻辑全部搬到 workerd，用 JS 编写。**

## 决策

### 1. 架构：Caddy 在前，workerd 在后

```
浏览器
  │
  ▼
  Caddy (:9088 公网) ──┬── 数据面：用户容器流量（页面、静态资源、WebSocket/SSE、
                     │         /app/<port> App Worker 数据面、启动页 502、白名单之外 404、活动日志）
                     │         → 直接代理到 dagu-u-{uid}:4096（完全不变）
                     │
                     └── 控制面：/portal/*、/app/v1/*、/api/v1/health、
                                 /api/v1/webhooks/*、/api/v1/restart/* → 转发给 workerd (:9090)
                                                       │
                                                       ▼
                                                 dagu（编排）/ 门户
```

一句话：**Caddy 是执行点，workerd 是决策点。** 容器流量不经过 workerd，
workerd 只处理低频的控制面请求。

### 2. workerd 职责（四条路径）

| 路径 | workerd 做什么 |
| --- | --- |
| `/portal/u/{uid}` | 校验 uid 格式（`^[A-Za-z0-9_-]{1,64}$`）→ 写 `ws_user` Cookie → 302 到 `/portal`；uid 不合法返回 400 |
| `/portal`、`/portal/*` | 门户页与静态资产（disk 绑定 `$DAGU_ROOT/portal/`） |
| `/app/v1/*` | 轻应用控制面（list/sync/select/delete/refresh/apply，内部校验 Cookie） |
| `/api/v1/health` | 返回 `{"status":"healthy","timestamp":...}` |
| `/api/v1/webhooks/*` | 校验调用方 Bearer token（对照 `.webhook-tokens/` 里的文件）→ 原样透传给 dagu，不改请求体 |
| `/api/v1/restart/*` | 浏览器直连、无外部 token → workerd 从文件读 token 并注入 → 转发 dagu `user_start` webhook |
| 其他未知路径 | 返回 404 |

### 3. Caddy 保留（完全不动）

- 用户容器数据面代理（WebSocket/SSE 等长连接）
- 容器不可达 502 → 启动页（含 JS 自动恢复）——阶段一不碰
- 无 Cookie / 未知路径访问 → 404（统一错误兜底）
- 活动日志（`reap_idle` 判活依赖它）保持不变

### 4. 运行与部署

- workerd 以**裸进程**运行，`install.sh` 用 nohup 启动（和 dagu 同一套运维方式）
- 监听 `0.0.0.0:9090`，Caddy 通过 `172.17.0.1:9090` 转发给它
- 交付包**必带** `dist/workerd-linux-amd64`；缺失或启动自检失败 → `install.sh` 报错退出
- webhook token 通过 filesystem 绑定**只读**读取 `.webhook-tokens/` 目录
- workerd 写自己的访问日志 `$ROOT/logs/workerd-access.log`，仅排障用

## 为什么这么排（架构理由）

1. **数据面不进 JS 层**：opencode 的 SSE 心跳、WebSocket 都是长连接、高并发，
   让它们穿过 workerd 等于给每一帧流量加一道 JS 边界，风险和损耗都不值得。
2. **故障隔离**：workerd 挂了只影响控制面（登录、跳转、webhook），
   已经在工作区里的用户完全不受影响。
3. **扩展友好**：以后的登录鉴权、限流、门户对接，都是“判断逻辑”，
   往 workerd 里加即可；Caddy 永远不用改逻辑。
4. **离线交付简单**：workerd 是单个静态二进制，和 dagu 一样拷过去就能跑，
   不需要 Python 环境、数据库等额外组件。

## 数据流示例

**正常访问**：用户点 `/portal/u/usr_01` → Caddy 转给 workerd → workerd 写 Cookie、
302 到 `/portal` → 门户页加载；打开工作区/大屏时，浏览器带 Cookie 的请求由 Caddy
直接代理到目标（不经过 workerd）。

**容器被回收后**：用户访问 `/` → Caddy 代理失败（502）→ 返回启动页 →
页面 JS 调 `/api/v1/restart/usr_01` → Caddy 转给 workerd → workerd 注入 token
转发 dagu → `user_start` 启动容器 → 页面自动刷新进入工作区。

## 阶段一验收标准

1. 本机（Windows）：workerd 独立运行，curl 验证四条路径行为正确。
2. VM 端到端：Caddy 把控制面路径转发给 workerd，现有 smoke-test 全绿，
   并新增“逻辑路径确实经过 workerd”的验证（查 workerd 访问日志）。
3. 回退方式：`git checkout v1.0.0` 即回到纯 Caddy 版本。

## 明确不做（后续阶段）

- 阶段二：启动页 502 判断收编进 workerd（届时优先走 dagu 只读接口，不碰 docker socket）
- 阶段三：登录/鉴权、限流、门户对接
- 阶段一不感知容器状态
