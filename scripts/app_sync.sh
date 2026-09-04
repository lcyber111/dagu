#!/usr/bin/env bash
# dagu-gate app_sync —— 扫描所有用户的 .apps 注册表，生成 workerd 配置（控制面 + App Workers）
#
# 用法：bash scripts/app_sync.sh
# 环境变量（可选）：
#   DAGU_ROOT     部署根（默认脚本上级目录）
#   WORKERD_PORT  workerd 监听端口（默认 9090）
#   WORKERD_BIND  workerd 监听地址（默认 172.17.0.1，仅 docker 网桥可达，Caddy 容器经此访问）
#   WORKERD_BIN   workerd 二进制（默认 $DAGU_ROOT/workerd/workerd）
#   DAGU_API      dagu 管理服务地址（默认 172.17.0.1:18080）
#
# 注册表约定（用户侧，agent 维护）：
#   users/<uid>/workspace/.apps/apps.json
#   users/<uid>/workspace/.apps/<appId>/<version>.js   （agent 编写的 worker）
#   users/<uid>/workspace/.apps/<appId>/www/           （页面资产，disk 绑定）
#   users/<uid>/workspace/.apps/<appId>/data-<version>/（SQLite，writable）
#
# 服务名派生（与 workerd/worker.js 的 serviceName 一致）：
#   app-<uid>-<appId>-<version>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"
WORKERD_PORT="${WORKERD_PORT:-9090}"
WORKERD_BIND="${WORKERD_BIND:-172.17.0.1}"
DAGU_API="${DAGU_API:-172.17.0.1:18080}"
# 兼容带 http:// 前缀的 DAGU_API（install.sh 的 env 默认即带前缀），
# 避免把 scheme 写进 capnp 的 daguServer address 导致 workerd DNS 解析失败
DAGU_API="${DAGU_API#http://}"
WORKERD_BIN="${WORKERD_BIN:-$DAGU_ROOT/workerd/workerd}"
if [ ! -x "$WORKERD_BIN" ]; then
  WORKERD_BIN="$(command -v workerd || true)"
fi
if [ -z "$WORKERD_BIN" ] || [ ! -x "$WORKERD_BIN" ]; then
  echo "ERROR: workerd binary not found (set WORKERD_BIN)" >&2
  exit 1
fi

# python3: system interpreter first, bundled portable runtime second
PYTHON3="${PYTHON3:-}"
if [ -z "$PYTHON3" ] && command -v python3 >/dev/null 2>&1; then
  PYTHON3="$(command -v python3)"
fi
if [ -z "$PYTHON3" ] && [ -x "$DAGU_ROOT/python/bin/python3" ]; then
  PYTHON3="$DAGU_ROOT/python/bin/python3"
fi
if [ -z "$PYTHON3" ]; then
  echo "ERROR: python3 not found (install python3 or keep dist/python-linux-x86_64.tar.gz in the package)" >&2
  exit 1
fi

echo "app_sync: DAGU_ROOT=$DAGU_ROOT WORKERD_PORT=$WORKERD_PORT WORKERD_BIND=$WORKERD_BIND"

# 可选：仅同步指定用户（dagu webhook 透传 WEBHOOK_PAYLOAD={"payload":{"uid":...}}）
SCOPE_UID=""
if [ -n "${WEBHOOK_PAYLOAD:-}" ]; then
  SCOPE_UID="$("$PYTHON3" -c 'import json,sys
p=json.loads(sys.argv[1]); p=p.get("payload",p); print(p.get("uid",""))' "$WEBHOOK_PAYLOAD")"
  echo "app_sync: scope uid=$SCOPE_UID"
fi

"$PYTHON3" - "$DAGU_ROOT" "$WORKERD_PORT" "$WORKERD_BIND" "$DAGU_API" "$SCOPE_UID" > "$DAGU_ROOT/workerd/config.capnp.tmp" <<'PY'
import json
import os
import sys
import time

root, port, bind, dagu_api, scope_uid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

# ---- 配额（M1）----
MAX_APPS_PER_USER = 20
MAX_SQLITE_BYTES = 100 * 1024 * 1024

# ---- 扫描所有用户的注册表 ----
users_root = os.path.join(root, "users")
manifests = []
if os.path.isdir(users_root):
    for entry in sorted(os.listdir(users_root)):
        p = os.path.join(users_root, entry, "workspace", ".apps", "apps.json")
        if os.path.isfile(p):
                try:
                    data = json.load(open(p, encoding="utf-8"))
                except Exception as e:
                    print(f"# WARN: bad registry {p}: {e}", file=sys.stderr)
                    continue
                # 配额校验：app 数量
                apps = data.get("apps") or []
                if len(apps) > MAX_APPS_PER_USER:
                    print(
                        "ERROR: uid %s app 数量 %d 超过配额 %d"
                        % (entry, len(apps), MAX_APPS_PER_USER),
                        file=sys.stderr,
                    )
                    sys.exit(1)
                # 配额校验：单 app SQLite 体积
                for app in apps:
                    app_root = os.path.join(users_root, entry, "workspace", ".apps", app.get("id", ""))
                    for ver in (app.get("versions") or {}).keys():
                        d = os.path.join(app_root, "data-" + ver)
                        if os.path.isdir(d):
                            total = sum(
                                os.path.getsize(os.path.join(dp, f))
                                for dp, _dn, fn in os.walk(d)
                                for f in fn
                            )
                            if total > MAX_SQLITE_BYTES:
                                print(
                                    "ERROR: uid %s app %s v%s SQLite 体积 %d 超过配额 %d"
                                    % (entry, app.get("id"), ver, total, MAX_SQLITE_BYTES),
                                    file=sys.stderr,
                                )
                                sys.exit(1)
                manifests.append((entry, p, data))

# ---- 端口唯一性 + 区间校验（跨所有用户） ----
seen_ports = {}
for _uid, _reg, _manifest in manifests:
    for _app in (_manifest.get("apps") or []):
        _p = _app.get("port")
        if not _p:
            continue
        if not (isinstance(_p, int) and 20000 <= _p <= 29999):
            print(
                "ERROR: uid %s app %s port %r 不在 20000-29999 区间"
                % (_uid, _app.get("id"), _p),
                file=sys.stderr,
            )
            sys.exit(1)
        if _p in seen_ports:
            print(
                "ERROR: 端口冲突 %d：%s/%s 与 %s/%s"
                % (_p, _uid, _app.get("id"), seen_ports[_p][0], seen_ports[_p][1]),
                file=sys.stderr,
            )
            sys.exit(1)
        seen_ports[_p] = (_uid, _app.get("id"))

# 发布标记：每次 app_sync 生成配置后更新 _meta.lastPublish（门户据此自动刷新预览）
_now = time.time()
for _uid, _reg, _manifest in manifests:
    # config 是全量（所有用户）生成的；scope 只用于 lastPublish 标记，避免每次发布刷新所有用户预览
    if scope_uid and _uid != scope_uid:
        continue
    _meta = _manifest.setdefault("_meta", {})
    _meta["lastPublish"] = _now
    json.dump(_manifest, open(_reg, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

print("# generated by scripts/app_sync.sh (do not edit)", file=sys.stderr)
print(f"# users with apps: {len(manifests)}", file=sys.stderr)


def capnp_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def const_name(svc):
    parts = svc.split("-")
    return parts[0] + "".join(
        "".join(c for c in p.capitalize() if c.isalnum()) for p in parts[1:]
    ) + "Worker"


def rel(p):
    # workerd 以 DAGU_ROOT 为 CWD 运行；embed/disk 均需相对路径
    return os.path.relpath(p, root)


def rel_embed(p):
    # capnp embed 按配置文件所在目录（workerd/）解析，与 disk 路径不同
    return os.path.relpath(p, os.path.join(root, "workerd"))


services = [
    '    (name = "main", worker = .gatewayWorker),',
    '    (name = "dagu", external = .daguServer),',
    '    (name = "tokens", disk = %s),' % capnp_str(rel(os.path.join(root, ".webhook-tokens"))),
    '    (name = "registry", disk = (path = %s, allowDotfiles = true)),' % capnp_str(rel(users_root)),
    '    (name = "app-libs", disk = (path = %s, allowDotfiles = true)),' % capnp_str(rel(os.path.join(root, "app-libs"))),
    '    (name = "portal", disk = (path = %s, allowDotfiles = true)),' % capnp_str(rel(os.path.join(root, "portal"))),
]
gateway_bindings = [
    '    (name = "dagu", service = "dagu"),',
    '    (name = "tokens", service = "tokens"),',
    '    (name = "registry", service = "registry"),',
    '    (name = "portal", service = "portal"),',
]
worker_consts = []

for uid, reg_path, manifest in manifests:
    apps = manifest.get("apps") or []
    for app in apps:
        app_id = app.get("id", "")
        app_port = app.get("port")
        if not app_id or not app_port:
            continue
        versions = app.get("versions") or {}
        for ver, v in versions.items():
            svc = "app-%s-%s-%s" % (uid, app_id, ver)
            cname = const_name(svc)
            app_root = os.path.join(users_root, uid, "workspace", ".apps", app_id)
            worker_file = os.path.join(app_root, ver + ".js")
            www_dir = os.path.join(app_root, "www")
            data_dir = os.path.join(app_root, "data-" + ver)
            do_class = v.get("doClass", "AppStore")
            unique_key = "app-%s-%s-%s" % (uid, app_id, ver)
            try:
                os.makedirs(data_dir, exist_ok=True)
            except PermissionError:
                print(
                    "ERROR: app %s v%s 数据目录不可写（多半是容器内创建导致 root 属主）。"
                    "请在用户容器内执行: chown -R 1000:1000 %s，再重新发布。"
                    % (app_id, ver, os.path.join(root, "users", uid, "workspace", ".apps", app_id)),
                    file=sys.stderr,
                )
                sys.exit(1)
            app_bindings = []

            services.append('    (name = %s, worker = .%s),' % (capnp_str(svc), cname))
            services.append(
                '    (name = %s, disk = (path = %s, allowDotfiles = true)),'
                % (capnp_str(svc + "-files"), capnp_str(rel(www_dir)))
            )
            services.append(
                '    (name = %s, disk = (path = %s, writable = true, allowDotfiles = true)),'
                % (capnp_str(svc + "-data"), capnp_str(rel(data_dir)))
            )
            gateway_bindings.append('    (name = %s, service = %s),' % (capnp_str(svc), capnp_str(svc)))
            app_bindings = app_bindings + ['    (name = "files", service = %s),' % capnp_str(svc + "-files")]
            app_bindings.append('    (name = "lib", service = "app-libs"),')
            # 每个 app/版本都有 DO 命名空间（脚手架默认 AppStore），必须暴露为 env 绑定
            app_bindings.append(
                '    (name = %s, durableObjectNamespace = %s),'
                % (capnp_str(do_class), capnp_str(do_class))
            )
            app_bindings.append('    (name = "Hub", durableObjectNamespace = "Hub"),')

            do_block = """
  durableObjectNamespaces = [
    (className = %s, uniqueKey = %s, enableSql = true),
    (className = "Hub", uniqueKey = %s),
  ],
  durableObjectStorage = (localDisk = %s),""" % (
                capnp_str(do_class),
                capnp_str(unique_key),
                capnp_str(unique_key + "-hub"),
                capnp_str(svc + "-data"),
            )
            worker_consts.append(
                """
const %s :Workerd.Worker = (
  compatibilityDate = "2025-12-23",
  modules = [
    (name = "worker.js", esModule = embed %s),
  ],%s
  bindings = [
%s
  ],
);"""
                % (cname, capnp_str(rel_embed(worker_file)), do_block, "\n".join(app_bindings))
            )

config = """using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
%s
  ],
  sockets = [
    ( name = "http", address = "%s:%s", http = (), service = "main" ),
  ],
);

const daguServer :Workerd.ExternalServer = (
  address = %s,
  http = (),
);

const gatewayWorker :Workerd.Worker = (
  compatibilityDate = "2025-12-23",
  modules = [
    (name = "worker.js", esModule = embed %s),
  ],
  bindings = [
%s
  ],
);
%s
""" % (
    "\n".join(services),
    bind,
    port,
    capnp_str(dagu_api),
    capnp_str(rel_embed(os.path.join(root, "workerd", "worker.js"))),
    "\n".join(gateway_bindings),
    "".join(worker_consts),
)

print(config)
PY

echo "== app_sync: 校验配置 =="
# embed/disk 相对路径按 workerd 进程 CWD 解析，因此编译校验与 serve 都必须在 DAGU_ROOT 下运行
if (cd "$DAGU_ROOT" && "$WORKERD_BIN" compile workerd/config.capnp.tmp >/dev/null 2>workerd/compile.err); then
  if [ -f "$DAGU_ROOT/workerd/config.capnp" ] && cmp -s "$DAGU_ROOT/workerd/config.capnp.tmp" "$DAGU_ROOT/workerd/config.capnp"; then
    rm -f "$DAGU_ROOT/workerd/config.capnp.tmp" "$DAGU_ROOT/workerd/compile.err"
    echo "app_sync: config.capnp unchanged, skip reload"
  else
    mv "$DAGU_ROOT/workerd/config.capnp.tmp" "$DAGU_ROOT/workerd/config.capnp"
    rm -f "$DAGU_ROOT/workerd/compile.err"
    echo "app_sync: config.capnp updated (workerd reload)"
  fi
else
  echo "app_sync: 配置校验失败，保留旧 config" >&2
  cat "$DAGU_ROOT/workerd/compile.err" >&2
  rm -f "$DAGU_ROOT/workerd/config.capnp.tmp" "$DAGU_ROOT/workerd/compile.err"
  exit 1
fi
