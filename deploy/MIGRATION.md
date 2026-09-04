# 迁移 / 升级指南

本文件覆盖两种场景：**A. 全新部署**到新机器；**B. 存量机器升级**到本版本
（含 light-app / App Worker / 门户，2026-09-02 已在 .234 生产按 B 流程实测）。

---

## A. 全新部署（唯一配置源 = `env`）

每台机器只需要改**一个文件**：`env`（由 `deploy/env.example` 复制而来）。
所有脚本和模板都不再写死旧服务器的绝对路径或 IP。

```bash
cp deploy/env.example env
vi env        # 修改 DAGU_ROOT、GATEWAY_PUBLIC_BASE_URL、镜像 tar 路径等
bash scripts/install.sh --env env
```

### env 文件中需要重点确认的项

| 变量 | 说明 |
| --- | --- |
| `DAGU_ROOT` | 部署根目录（dagu 二进制、dags、scripts、templates、users、data） |
| `GATEWAY_PUBLIC_BASE_URL` | 用户入口（公网），如 `http://<公网IP>:9088`；注入 `.platform/gateway.json` 的 `baseUrl`（对外链接） |
| `GATEWAY_INTERNAL_BASE_URL` | 容器内可达的网关地址（默认 `http://caddy-gateway:9088`）；注入 `internalBaseUrl`，容器内 API 调用用它。公网 IP 在容器内常因 hairpin NAT 不可达，勿把 `GATEWAY_PUBLIC_BASE_URL` 当 API 地址 |
| `DAGU_API` | dagu 管理 API（默认 `http://172.17.0.1:18080`） |
| `OPENCODE_IMAGE_TAR` / `CADDY_IMAGE_TAR` | 离线镜像包路径（镜像已加载时用不到） |
| `DAGU_ADMIN_USER` / `DAGU_ADMIN_PASS` | 管理员账号（首次初始化） |
| `DOCKER_NETWORK` | 网关与用户容器共用网络（默认 `dagu-net`） |
| `IDLE_TIMEOUT_MINUTES` | 空闲回收阈值（默认 360，即 6 小时） |
| `REAP_CRON` | `reap_idle` 定时 cron（默认每分钟） |
| `WORKERD_PORT` / `WORKERD_BIND` | workerd 监听端口/地址（默认 9090 / 172.17.0.1，仅 docker 网桥可达） |

### install.sh 做什么（9 步）

1. 建目录骨架 → 2. 停旧 dagu/workerd（避免覆盖运行中二进制报 "Text file busy"）→
3. 建 docker 网络（缺失时）→ 4. 加载镜像（缺失时）→ 5. 拷贝运行时文件
（dagu/scripts/dags/gateway/workerd/templates.yaml/tar；**同步 app-libs、安装 portal**）→
6. 渲染 dagu 与 workerd 配置 → 6b. app_sync 生成完整 workerd 配置（门户/注册表/app-libs +
存量 App Worker）→ 7. 启动 dagu + 初始化 6 个 webhook token → 8. 启动 workerd（**必须 --watch**）
→ 9. 重建 caddy-gateway。

**workerd 必须以 `serve --watch workerd/config.capnp` 启动**：app_sync 改配置后靠 watch
热加载；workerd_guard 按此模式守护。若不带 `--watch`，新发布的应用不会绑定，
guard 会反复拉起新进程导致 9090 bind 冲突（已在 2026-09-02 修复 install.sh/workerd_guard.sh）。

### 机制说明

- `deploy/dags/*.yaml.tpl` 渲染为绝对路径（dagu 服务器模式步骤的相对工作目录不是 DAG 所在目录）。
- install.sh 把生效配置写入 `$DAGU_ROOT/.deploy-env`，脚本从环境变量或 `.deploy-env` 读取配置。
- `create_user.sh` 创建用户时：拷贝模板 workspace → 注入 `users/<uid>/config/opencode.json`
→ 写入 **`users/<uid>/workspace/.platform/gateway.json`**（发布网关地址，按本机 env 注入）→
`docker run` 挂载 workspace + opencode.json，注入 `WS_USER` 环境变量。
- 门户静态页由 workerd 经 disk 绑定托管 `$DAGU_ROOT/portal`；宿主 `app-libs/` 同理供 App Worker 页面引用。

---

## B. 存量升级（旧版 → 本版本，.234 实测）

旧版特征：无 light-app/门户/app worker，模板里只有 `agents_gen`，态势大屏走
serve_html/FBQ 静态流程。升级后旧 `/workspace`、`/app-proxy` 路由移除（404），
存量静态大屏链接失效（按业务约定，不保留兼容）。

### 阶段 0：备份与记档

```bash
BK=/data1/lxz/backup-YYYYMMDD
cp -a /data1/lxz/dagu-gate "$BK/dagu-gate"
cp -a /data1/lxz/dagu-run/{templates,users,gateway,scripts,dags,.config,.webhook-tokens} "$BK/"
cp -a /data1/lxz/dagu-run/workerd/config.capnp "$BK/"
# 记档：agents_gen HEAD（同事工作目录/模板/用户/origin 四处应一致）、Caddyfile/config 哈希
```

### 阶段 1：VM 预演（推荐）

用**同事最新 agents_gen**（从 git_origin 或模板拷贝，不含 .git）+ 新版 light-app 组装
`deploy/templates/tpl-dev-v2.tar.gz`（`scripts/assemble_template.sh <agents_gen> <out>`），
在测试机全新安装并跑一次生成→发布→门户→修改→删除全链路。

### 阶段 2：替换 dagu-gate + 模板 overlay

```bash
# 1) 全量替换 dagu-gate（windows 仓库 tar，排除 .git；保留本机 env）
tar -xzf dagu-gate-full.tar.gz -C /data1/lxz/dagu-gate
# 2) 用本机同事 agents_gen 重新组装 deploy tar（供未来全新安装）
cd /data1/lxz/dagu-gate
bash scripts/assemble_template.sh \
  /data1/lxz/dagu-run/templates/tpl-dev-v2/workspace/version0802/agents_gen \
  deploy/templates/tpl-dev-v2.tar.gz
# 3) overlay 运行时模板（install.sh 对已存在模板不会重解压，必须手动加）
RT=/data1/lxz/dagu-run/templates/tpl-dev-v2
mkdir -p "$RT/workspace/version0802/light-app"
cp -a templates/light-app/.   "$RT/workspace/version0802/light-app/"
cp -a templates/AGENTS.md     "$RT/workspace/version0802/AGENTS.md"
cp -a templates/opencode.json "$RT/opencode.json"
# agents_gen 全程零接触（先记录 HEAD，完成后核对未变、dirty=0）
```

### 阶段 3：install.sh

```bash
bash /data1/lxz/dagu-gate/scripts/install.sh --env /data1/lxz/dagu-gate/env
```

会重启 dagu/workerd、重建 caddy-gateway、重新生成 webhook token、app_sync 生成完整配置。

### 阶段 4：存量用户同步（sync_light_app.sh）

```bash
bash /data1/lxz/dagu-run/scripts/sync_light_app.sh
# 对每个存量用户：version0802 加 light-app/AGENTS.md；config/opencode.json 换新版；
# 写 .platform/gateway.json（本机网关地址）。跳过 agents_gen/user_space/.apps/.selected。
```

用户容器 workspace 是宿主 bind mount，文件更新无需重建容器；opencode.json 更新后
`docker restart dagu-u-*` 生效（或等下次按需启动）。

### 阶段 5：验证清单

- `/portal/u/{uid}` → 302，带 Cookie `/portal` → 200
- workerd 单进程 `--watch`、`/api/v1/health` 200；dagu API 200
- 旧路径 `/workspace`、`/app-proxy/...` → 404（预期）
- 新建用户/存量用户工作区能看到 `light-app/`、`AGENTS.md`、`.platform/gateway.json`
- 生成一个大屏走 App Worker 全链路（发布→health→spec 入库→门户卡片→页面 200→SSE）
- agents_gen HEAD 与升级前一致、`git status` 干净

---

## 本版本关键点（易踩坑）

- **jsonschema 缺失**：用户容器镜像无 jsonschema；已把纯 Python jsonschema 3.2.0
  + pyrsistent + six vendor 进 `light-app/scripts/vendor/`，build_dashboard.py 自动回退。
- **产物暂存区**：生成中间产物统一落 `/workspace/light-app-work/`（agents_gen 之外），
  SOP 用 `OUT_BASE` 显式指定，防止污染/被同事 git reset 清掉。
- **发布网关地址**：SOP 优先读 `/workspace/.platform/gateway.json`，**不读**同事
  `agents_gen/config/server.json`（那是旧 serve_html 静态配置，可能指向错误机器）。
  `gateway.json` 含两个地址：`internalBaseUrl`（容器内 API 调用，默认 `http://caddy-gateway:9088`）
  与 `baseUrl`（公网，仅用于对外汇报链接）。
- **同事 agents_gen 零接触**：他的同步机制只碰 `agents_gen/` 子目录；`light-app/`、
  `AGENTS.md`、`.platform/`、`light-app-work/`、`.apps/` 都在其外，天然免疫。
- **模板不会自动重解压**：install.sh 对已存在的 `templates/tpl-dev-v2/workspace`
  跳过 tar 解压，存量升级必须按阶段 2 手动 overlay。
