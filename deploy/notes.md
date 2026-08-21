# dagu v2 部署要点（ticket 01 实测记录）

- **配置是扁平 schema**：`host`、`port`、`dags_dir`、`data_dir`、`auth`、`webhooks` 都是顶层键，没有 `server:` 段。可用 `dagu schema config` 查看完整 schema。
- **配置文件必须显式传入**：`dagu server --config <file>`。默认路径 `~/.config/dagu/base.yaml` 不会自动生效。
- **base.yaml 双重身份**：dagu 的 DAG 加载器会把 `paths.base_config` 指向的文件当作"基础 DAG 配置"解析，因此 CLI 配置和 DAG 基础配置必须分开：CLI 配置里设置 `paths.base_config: <空 DAG 基础配置路径>`。
- **webhook 管理需要 builtin 认证**：`auth.mode: basic` 下 webhook 管理接口不可用；必须 `auth.mode: builtin`。
- **初始化管理员**：首次启动后 `POST /api/v1/auth/setup` 创建 admin（一次性），然后 `POST /api/v1/auth/login` 获取 JWT；创建 webhook 用 `POST /api/v1/dags/{name}/webhook`（Bearer JWT）。
- **webhook 触发**：`POST /api/v1/webhooks/{dagName}`，Bearer 用 webhook token（`dagu_wh_...`），触发端点无需管理员 JWT；请求体 `{"payload": {...}}` 会以 `WEBHOOK_PAYLOAD` 环境变量传给 DAG。
- **运行历史端点**：`GET /api/v1/dags/{fileName}/dag-runs`（不是 `/runs`）。
- **DAG YAML 注意**：`run:` 的 shell 值若含冒号+空格，整个值要用引号包起来（YAML 裸标量不能含 `: `）。

## ticket 02/03/04 实测补充

- **`dagu server` 只把任务放进队列**，必须用 `dagu start-all`（server + scheduler）才会真正执行；单机本地模式用 `DAGU_COORDINATOR_ENABLED=false` 关闭分布式协调器。
- **opencode 镜像默认 CMD 就是 `opencode serve --hostname 0.0.0.0 --port 4096`**，不需要自定义启动器；`docker run` 用 `-w /workspace/<project>` 指定项目目录即可。镜像 ENTRYPOINT 是 `opencode`，所以不要把其他命令直接跟在镜像名后（会被当成 project 位置参数）。
- **docker 内存单位**不接受 Kubernetes 风格 `Gi/Mi`，脚本把 `memory_limit`（如 `4Gi`）转成小写 `g/m` 再传给 `--memory`。
- **docker 网络名带连字符**时，`docker inspect --format` 的 Go 模板不能写 `.dagu-net`（会被解析成减法），要用 `{{(index .NetworkSettings.Networks "dagu-net").IPAddress}}`。
- **dagu-net 网络**在老系统清理时可能被一并删除，部署脚本会检查并报错；需要 `docker network create dagu-net`。
- **新增/修改 DAG 文件后需要重启 dagu**（存在 `.dag.index` 缓存），不会即时发现。
- opencode server 未设置 `OPENCODE_SERVER_PASSWORD` 时会提示 unsecured，后续可在模板配置中补充。
- 创建/删除/启动/回收脚本依赖 python3 解析 JSON payload；install.sh 渲染配置也依赖 python3。
  优先用系统 python3；系统没有时自动回退到交付包 `dist/python-linux-x86_64.tar.gz`
  （便携 Python 3.12.14，解压到 `$DAGU_ROOT/python`）。dagu 本体不依赖 python3。
- **dagu 步骤运行在隔离环境**：dagu 执行 DAG 步骤（bash 脚本）时不会继承守护进程的环境变量
  （源码 runner.go 使用 isolatedEnv）。因此 install.sh 启动时设置的
  `GATEWAY_PUBLIC_BASE_URL` 等配置不会自动传给脚本；create_user.sh 曾因此把网关地址
  注入成默认值 `127.0.0.1:9088`。现在 4 个脚本会在变量为空时从 `$DAGU_GATE_ROOT/.deploy-env`
  （install.sh 写入的生效配置）读取，保证定时/手动运行与安装配置一致。
- **dagu webhook 对空/非法 JSON 会 panic（500）**：当前 dagu 构建（version 0.0.0）在
  TriggerWebhook 的 JSON 解码失败分支存在 nil 指针 panic。workerd 在 `forwardToDagu`
  转发前先 `JSON.parse` 校验，非法/空 body 直接返回 400，避免坏请求到达 dagu。

## ticket 05 网关实测补充

- 网关容器 `caddy-gateway`（caddy:2.11.4-alpine）加入 `dagu-net`，宿主机端口 9088；webhook 转发到 `172.17.0.1:18080`。
- `/api/v1/health` 由 Caddy `respond` 返回 `{"status":"healthy","timestamp":"{time.now}"}`；`{time.now}` 输出 Go 默认时间格式（含 `m=+...` 后缀），如需 ISO8601 风格可后续用模板优化。
- Caddy 启动日志的 `Unnecessary header_up X-Forwarded-For/Proto` 是冗余提示，不影响功能；`caddy fmt --overwrite` 可整理格式（可选）。
- 网络统一为 `dagu-net`；旧 `occ-net` 已删除。
