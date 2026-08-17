# 迁移到新服务器（唯一配置源）

改造后，每台机器只需要改**一个文件**：`env`（由 `deploy/env.example` 复制而来）。
所有脚本和模板都不再写死旧服务器的绝对路径或 IP。

## 迁移步骤

```bash
cp deploy/env.example env
vi env        # 修改 DAGU_ROOT、GATEWAY_PUBLIC_BASE_URL、镜像 tar 路径等
bash scripts/install.sh --env env
```

## env 文件中需要重点确认的项

| 变量 | 说明 |
| --- | --- |
| `DAGU_ROOT` | 部署根目录（dagu 二进制、dags、scripts、templates、users、data） |
| `GATEWAY_PUBLIC_BASE_URL` | 用户工作区入口，如 `http://<公网IP>:9088` |
| `DAGU_API` | dagu 管理 API（默认 `http://172.17.0.1:18080`） |
| `OPENCODE_IMAGE_TAR` / `CADDY_IMAGE_TAR` | 离线镜像包路径（镜像已加载时用不到） |
| `DAGU_ADMIN_USER` / `DAGU_ADMIN_PASS` | 管理员账号（首次初始化） |
| `DOCKER_NETWORK` | 网关与用户容器共用网络（默认 `dagu-net`） |
| `IDLE_TIMEOUT_MINUTES` | 空闲回收阈值：用户容器超过该分钟数无活动即停止（默认 360，即 6 小时） |
| `REAP_CRON` | `reap_idle` 定时 cron（5 段式，默认每分钟） |
| `STOP_TIMEOUT` | `docker stop -t` 超时（秒，默认 30） |
| `START_PAGE_REFRESH` | 启动页自动刷新间隔（秒，默认 5） |
| `WORKERD_PORT` | workerd 控制面服务监听端口（默认 9090） |
| `GATEWAY_UID` / `GATEWAY_GID` | Caddy 容器运行用户（install 自动取安装用户 id -u / id -g，一般无需设置） |

## 机制说明

- `deploy/base.yaml.tpl` 由 install.sh 渲染为实际配置，`dags_dir`、`data_dir`、
  `paths.base_config` 自动跟随 `DAGU_ROOT`。
- `deploy/dags/*.yaml.tpl` 由 install.sh 渲染到 `dags/` 下，脚本路径为绝对路径
  （`{{DAGU_ROOT}}/scripts/...`）。注意：dagu 服务器模式下，步骤的相对工作目录
  是基于运行工作目录解析的，而不是 DAG 文件所在目录，因此这里必须渲染成绝对路径。
- `create_user.sh` / `delete_user.sh` / `start_user.sh` / `reap_idle.sh` 根据
  自身位置推导部署根目录，不再依赖写死的绝对路径；`templates.yaml` 里的
  workspace/opencode 路径也以根目录为基准解析。
- install.sh 会在覆盖 dagu 二进制**之前**停掉旧进程，避免 "Text file busy"。
- install.sh 启动 dagu 时注入运行环境（DAGU_GATE_ROOT、GATEWAY_PUBLIC_BASE_URL
  等），并把生效配置写入 `$DAGU_ROOT/.deploy-env` 供 smoke-test 使用。
- workerd 控制面服务：`workerd/config.capnp.tpl` 由 install.sh 渲染为
  `$DAGU_ROOT/workerd/config.capnp`（注入 DAGU_ROOT、DAGU_API 地址、WORKERD_PORT），
  与 `worker.js` 一起随交付包提供；二进制 `dist/workerd-linux-amd64` 缺失时
  install.sh 会报错退出。workerd 以裸进程运行，健康检查失败同样报错退出。
- 空闲回收与按需恢复（`user_start` / `reap_idle`、启动页、活动日志）的详细说明
  见 `deploy/README.md` 的「空闲回收与按需恢复」章节。

## 手动重启 dagu

如果手工重启 dagu，需要带上运行时环境（否则网关地址等回退到默认值）：

```bash
cd "$DAGU_ROOT"
env $(grep -v '^#' .deploy-env) nohup ./dagu start-all --config .config/dagu/base.yaml > server.log 2>&1 &
```

## 注意

- `templates.yaml` 仍由简易 bash 解析器读取，保持“模板名 2 空格缩进、字段 4 空格
  缩进、每行一个 `key: value`”的格式。
- `gateway/Caddyfile` 中的 `172.17.0.1:18080` 和 `dagu-u-{uid}:4096` 依赖 Docker
  默认网桥地址与容器名，通常无需修改。
