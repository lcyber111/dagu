# dagu-gate 控制面逻辑服务（workerd）配置模板
# 由 scripts/install.sh 渲染到 $DAGU_ROOT/workerd/config.capnp：
#   {{DAGU_ROOT}}    -> 部署根目录
#   {{DAGU_API_HOST}} -> dagu 管理服务地址（host:port）
#   {{WORKERD_PORT}} -> workerd 监听端口（默认 9090）
#   {{WORKERD_BIND}} -> workerd 监听地址（默认 172.17.0.1，仅 docker 网桥可达）
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    # 控制面 worker（业务逻辑见 worker.js）
    (name = "main", worker = .gatewayWorker),
    # dagu 管理服务：worker 通过 env.dagu.fetch() 转发请求
    (name = "dagu", external = .daguServer),
    # webhook token 目录：只读挂载，worker 通过 env.tokens.fetch() 读取
    (name = "tokens", disk = "{{DAGU_ROOT}}/.webhook-tokens"),
  ],
  sockets = [
    ( name = "http", address = "{{WORKERD_BIND}}:{{WORKERD_PORT}}", http = (), service = "main" ),
  ],
);

const daguServer :Workerd.ExternalServer = (
  address = "{{DAGU_API_HOST}}",
  http = (),
);

const gatewayWorker :Workerd.Worker = (
  compatibilityDate = "2025-12-23",
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
  ],
  bindings = [
    (name = "dagu", service = "dagu"),
    (name = "tokens", service = "tokens"),
  ],
);
