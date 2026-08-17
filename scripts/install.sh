#!/usr/bin/env bash
# dagu-gate offline installer (idempotent).
#
# Usage:
#   bash scripts/install.sh [--env <env-file>]
#
# Run from the delivery package root. All machine-specific settings live in
# ONE env file (see deploy/env.example); without one, built-in defaults are
# used. The installer: stops an old dagu -> prepares layout/network/images ->
# copies runtime files -> renders dagu + workerd configs -> starts dagu
# (start-all) with the runtime env -> initializes webhook tokens -> starts
# workerd (control-plane logic) with health check -> starts the Caddy gateway.
set -euo pipefail

# ---- arguments ----
ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env)
      ENV_FILE="${2:-}"
      if [ -z "$ENV_FILE" ]; then
        echo "ERROR: --env requires a file path" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      echo "usage: bash scripts/install.sh [--env <env-file>]" >&2
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- machine-specific settings (single source of truth) ----
if [ -n "$ENV_FILE" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: env file not found: $ENV_FILE" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

ROOT="${DAGU_ROOT:-/home/li/dagu-run}"
CONFIG_PATH="${DAGU_CONFIG:-$ROOT/.config/dagu/base.yaml}"
GATEWAY_PUBLIC_BASE_URL="${GATEWAY_PUBLIC_BASE_URL:-http://127.0.0.1:9088}"
DOCKER_NETWORK="${DOCKER_NETWORK:-dagu-net}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCODE_EXECUTABLE="${OPENCODE_EXECUTABLE:-opencode}"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-60}"
ADMIN_USER="${DAGU_ADMIN_USER:-admin}"
ADMIN_PASS="${DAGU_ADMIN_PASS:-dagu-gate-2026}"
OPENCODE_IMAGE_TAR="${OPENCODE_IMAGE_TAR:-/home/li/dagu/opencode-1.17.10-custom-nods-python-pandas.tar.gz}"
CADDY_IMAGE_TAR="${CADDY_IMAGE_TAR:-/home/li/dagu/caddy.2.11.4.tar}"
DAGU_API="${DAGU_API:-http://172.17.0.1:18080}"
IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-360}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
START_PAGE_REFRESH="${START_PAGE_REFRESH:-5}"
REAP_CRON="${REAP_CRON:-* * * * *}"
WORKERD_PORT="${WORKERD_PORT:-9090}"
# Caddy 容器运行用户：默认自动取当前登录用户（用什么用户装就用什么用户跑）。
GATEWAY_UID="${GATEWAY_UID:-$(id -u)}"
GATEWAY_GID="${GATEWAY_GID:-$(id -g)}"

echo "install: root=$ROOT"
echo "install: gateway=$GATEWAY_PUBLIC_BASE_URL network=$DOCKER_NETWORK"

echo "== [1/9] layout =="
mkdir -p "$ROOT"/{dags,data,users,archive,scripts,gateway,templates,.webhook-tokens,logs,workerd}

echo "== [2/9] stop old dagu/workerd =="
# Stop dagu/workerd BEFORE overwriting their binaries: Linux refuses to
# overwrite a running executable ("Text file busy").
pkill -x dagu 2>/dev/null || true
pkill -x workerd 2>/dev/null || true
sleep 1

echo "== [3/9] docker network =="
docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK"

echo "== [4/9] docker images =="
docker image inspect smanx/opencode:1.17.10-custom-nods-python-pandas >/dev/null 2>&1 \
  || docker load -i "$OPENCODE_IMAGE_TAR"
docker image inspect caddy:2.11.4-alpine >/dev/null 2>&1 \
  || docker load -i "$CADDY_IMAGE_TAR"

echo "== [5/9] copy runtime files =="
if [ "$PKG_ROOT" != "$ROOT" ]; then
  if [ -f "$PKG_ROOT/dist/dagu-linux-amd64" ]; then
    cp -a "$PKG_ROOT/dist/dagu-linux-amd64" "$ROOT/dagu"
  elif [ -f "$PKG_ROOT/dagu" ]; then
    cp -a "$PKG_ROOT/dagu" "$ROOT/dagu"
  fi
  chmod +x "$ROOT/dagu" 2>/dev/null || true
  cp -a "$PKG_ROOT/dags/." "$ROOT/dags/"
  cp -a "$PKG_ROOT/scripts/." "$ROOT/scripts/"
  chmod +x "$ROOT"/scripts/*.sh
  cp -a "$PKG_ROOT/gateway/." "$ROOT/gateway/"
  cp -a "$PKG_ROOT/templates.yaml" "$ROOT/templates.yaml"
  cp -a "$PKG_ROOT/deploy/base.dag.yaml" "$ROOT/base.dag.yaml"
  cp -a "$PKG_ROOT/deploy/templates/tpl-dev-v2.tar.gz" "$ROOT/templates/"
  cp -a "$PKG_ROOT/workerd/." "$ROOT/workerd/"
  if [ -f "$PKG_ROOT/dist/workerd-linux-amd64" ]; then
    cp -a "$PKG_ROOT/dist/workerd-linux-amd64" "$ROOT/workerd/workerd"
  elif [ -f "$PKG_ROOT/workerd/workerd" ]; then
    cp -a "$PKG_ROOT/workerd/workerd" "$ROOT/workerd/workerd"
  fi
fi
# 只检查文件是否存在：从 Windows 打包解压的二进制可能没有 x 位，
# 下面的 chmod +x 会补上（检查放在 chmod 之前会误报 missing）。
if [ ! -f "$ROOT/workerd/workerd" ]; then
  echo "ERROR: workerd binary missing at $ROOT/workerd/workerd" >&2
  echo "       put dist/workerd-linux-amd64 into the delivery package" >&2
  exit 1
fi
chmod +x "$ROOT/workerd/workerd"
mkdir -p "$ROOT/templates"
if [ ! -d "$ROOT/templates/tpl-dev-v2/workspace" ]; then
  tar -xzf "$ROOT/templates/tpl-dev-v2.tar.gz" -C "$ROOT/templates/"
fi

echo "== [6/9] render dagu + workerd config =="
# Render DAG files from templates: an absolute script path is required because
# dagu resolves step working directories against the per-run work directory in
# server mode, not against the DAG file location.
python3 - "$PKG_ROOT/deploy/dags" "$ROOT/dags" "$ROOT" "$REAP_CRON" <<'PYEOF'
import os
import sys

src_dir, dst_dir, root, reap_cron = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
for name in sorted(os.listdir(src_dir)):
    if not name.endswith(".tpl"):
        continue
    with open(os.path.join(src_dir, name), encoding="utf-8") as fh:
        data = fh.read()
    data = data.replace("{{DAGU_ROOT}}", root)
    data = data.replace("{{REAP_CRON}}", reap_cron)
    dst = os.path.join(dst_dir, name[:-4])
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(data)
    print("rendered %s -> %s" % (name, dst))
PYEOF

mkdir -p "$(dirname "$CONFIG_PATH")"
python3 - "$PKG_ROOT/deploy/base.yaml.tpl" "$CONFIG_PATH" "$ROOT" <<'PYEOF'
import sys

src, dst, root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as fh:
    data = fh.read()
data = data.replace("{{DAGU_ROOT}}", root)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(data)
PYEOF
echo "config written to $CONFIG_PATH"

# Render workerd config (control-plane logic service).
WORKERD_CONFIG="$ROOT/workerd/config.capnp"
DAGU_API_HOST="${DAGU_API#http://}"
python3 - "$PKG_ROOT/workerd/config.capnp.tpl" "$WORKERD_CONFIG" "$ROOT" "$DAGU_API_HOST" "$WORKERD_PORT" <<'PYEOF'
import sys

src, dst, root, api_host, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(src, encoding="utf-8") as fh:
    data = fh.read()
data = data.replace("{{DAGU_ROOT}}", root)
data = data.replace("{{DAGU_API_HOST}}", api_host)
data = data.replace("{{WORKERD_PORT}}", port)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(data)
print("workerd config written to %s" % dst)
PYEOF

# Record the effective settings for smoke-test.sh and manual restarts.
cat > "$ROOT/.deploy-env" <<EOF
DAGU_ROOT=$ROOT
GATEWAY_PUBLIC_BASE_URL=$GATEWAY_PUBLIC_BASE_URL
DOCKER_NETWORK=$DOCKER_NETWORK
IDLE_TIMEOUT_MINUTES=$IDLE_TIMEOUT_MINUTES
STOP_TIMEOUT=$STOP_TIMEOUT
START_PAGE_REFRESH=$START_PAGE_REFRESH
REAP_CRON="$REAP_CRON"
ACTIVITY_LOG=$ROOT/logs/access.log
GATEWAY_UID=$GATEWAY_UID
GATEWAY_GID=$GATEWAY_GID
WORKERD_PORT=$WORKERD_PORT
WORKERD_LOG=$ROOT/logs/workerd-access.log
EOF

echo "== [7/9] start dagu + init webhooks =="
cd "$ROOT"
env \
  DAGU_COORDINATOR_ENABLED=false \
  DAGU_GATE_ROOT="$ROOT" \
  USER_DATA_ROOT="$ROOT/users" \
  TEMPLATES_YAML="$ROOT/templates.yaml" \
  ARCHIVE_DIR="$ROOT/archive" \
  GATEWAY_PUBLIC_BASE_URL="$GATEWAY_PUBLIC_BASE_URL" \
  DOCKER_NETWORK="$DOCKER_NETWORK" \
  OPENCODE_PORT="$OPENCODE_PORT" \
  OPENCODE_EXECUTABLE="$OPENCODE_EXECUTABLE" \
  READINESS_TIMEOUT="$READINESS_TIMEOUT" \
  IDLE_TIMEOUT_MINUTES="$IDLE_TIMEOUT_MINUTES" \
  STOP_TIMEOUT="$STOP_TIMEOUT" \
  ACTIVITY_LOG="$ROOT/logs/access.log" \
  nohup ./dagu start-all --config "$CONFIG_PATH" > server.log 2>&1 &
echo $! > server.pid
sleep 5

curl -s -X POST "$DAGU_API/api/v1/auth/setup" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" >/dev/null || true

LOGIN=$(curl -s -X POST "$DAGU_API/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}")
TOKEN=$(printf '%s' "$LOGIN" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$TOKEN" ]; then
  echo "ERROR: admin login failed" >&2
  exit 1
fi

for dag in user_create user_delete user_start; do
  RESP=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" "$DAGU_API/api/v1/dags/$dag/webhook")
  WT=$(printf '%s' "$RESP" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$WT" ]; then
    curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$DAGU_API/api/v1/dags/$dag/webhook" >/dev/null
    RESP=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" "$DAGU_API/api/v1/dags/$dag/webhook")
    WT=$(printf '%s' "$RESP" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
  if [ -z "$WT" ]; then
    echo "ERROR: failed to init webhook for $dag: $RESP" >&2
    exit 1
  fi
  printf '%s' "$WT" > "$ROOT/.webhook-tokens/$dag.token"
  echo "webhook $dag token saved"
done

# Gateway runtime env: log mount + page refresh (token injection moved to workerd).
cat > "$ROOT/gateway/.env" <<EOF
LOG_DIR=$ROOT/logs
START_PAGE_REFRESH=$START_PAGE_REFRESH
GATEWAY_UID=$GATEWAY_UID
GATEWAY_GID=$GATEWAY_GID
EOF
echo "gateway env written to $ROOT/gateway/.env"

echo "== [8/9] start workerd (control plane) =="
cd "$ROOT"
nohup "$ROOT/workerd/workerd" serve "$ROOT/workerd/config.capnp" \
  > "$ROOT/logs/workerd-access.log" 2>&1 &
echo $! > "$ROOT/workerd/workerd.pid"

WORKERD_OK=no
for _ in $(seq 1 10); do
  if curl -s --max-time 2 "http://127.0.0.1:$WORKERD_PORT/api/v1/health" \
      | grep -q '"healthy"'; then
    WORKERD_OK=yes
    break
  fi
  sleep 1
done
if [ "$WORKERD_OK" != "yes" ]; then
  echo "ERROR: workerd health check failed (see $ROOT/logs/workerd-access.log)" >&2
  exit 1
fi
echo "workerd healthy on 127.0.0.1:$WORKERD_PORT"

echo "== [9/9] gateway =="
cd "$ROOT/gateway"
# 日志目录归 Caddy 容器用户所有，保证 access.log 可写可读（reap_idle 依赖）。
chown "$GATEWAY_UID:$GATEWAY_GID" "$ROOT/logs" 2>/dev/null || true
# 清掉旧容器遗留的日志，避免新容器（root 身份）打开旧文件时权限失败。
rm -f "$ROOT/logs/access.log"
docker run --rm \
  -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null
docker compose up -d

echo "install complete. webhook tokens:"
for dag in user_create user_delete user_start; do
  echo "  $dag: $(cat "$ROOT/.webhook-tokens/$dag.token")"
done
echo "workerd: pid $(cat "$ROOT/workerd/workerd.pid") on :$WORKERD_PORT, log $ROOT/logs/workerd-access.log"
