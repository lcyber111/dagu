#!/usr/bin/env bash
# dagu-gate: create a user environment container from the webhook payload.
#
# Reads WEBHOOK_PAYLOAD (JSON with uid/username/resources/extra_config) and
# performs: validate uid -> idempotency check -> copy template -> inject
# config -> docker run with resource limits -> wait for 4096 -> cleanup on
# failure. Only 4096 (OpenCode Web) is checked; 7010 is no longer used.
set -euo pipefail

# ---- configuration (override via environment) ----
# Defaults are derived from this script's own location so the package works
# from any deployment root without editing paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_GATE_ROOT="${DAGU_GATE_ROOT:-$(dirname "$SCRIPT_DIR")}"

# ---- python3: system interpreter first, bundled portable runtime fallback ----
PYTHON3="${PYTHON3:-}"
if [ -z "$PYTHON3" ] && command -v python3 >/dev/null 2>&1; then
  PYTHON3="$(command -v python3)"
fi
if [ -z "$PYTHON3" ] && [ -x "$DAGU_GATE_ROOT/python/bin/python3" ]; then
  PYTHON3="$DAGU_GATE_ROOT/python/bin/python3"
fi
if [ -z "$PYTHON3" ]; then
  echo "ERROR: python3 not found (install python3 or keep dist/python-linux-x86_64.tar.gz in the package)" >&2
  exit 1
fi

USER_DATA_ROOT="${USER_DATA_ROOT:-$DAGU_GATE_ROOT/users}"
TEMPLATES_YAML="${TEMPLATES_YAML:-$DAGU_GATE_ROOT/templates.yaml}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$DAGU_GATE_ROOT/archive}"
GATEWAY_PUBLIC_BASE_URL="${GATEWAY_PUBLIC_BASE_URL:-http://127.0.0.1:9088}"
DOCKER_NETWORK="${DOCKER_NETWORK:-dagu-net}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCODE_EXECUTABLE="${OPENCODE_EXECUTABLE:-opencode}"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-60}"

PAYLOAD="${WEBHOOK_PAYLOAD:-}"
if [ -z "$PAYLOAD" ]; then
  echo "ERROR: WEBHOOK_PAYLOAD is empty" >&2
  exit 1
fi

# ---- parse payload (JSON via python3: system or bundled portable runtime) ----
eval "$("$PYTHON3" - "$PAYLOAD" <<'PYEOF'
import json
import sys

def q(v):
    return "'" + str(v).replace("'", "'\\''") + "'"

p = json.loads(sys.argv[1])
if isinstance(p, dict) and "payload" in p:
    p = p["payload"]
res = p.get("resources") or {}
print("UID_VAL=%s" % q(p.get("uid", "")))
print("USERNAME=%s" % q(p.get("username", "")))
print("CPU=%s" % q(res.get("cpu_limit") or ""))
print("MEM=%s" % q(res.get("memory_limit") or ""))
print("TPL_ID=%s" % q(res.get("template_id") or ""))
print("EXTRA_JSON=%s" % q(json.dumps(p.get("extra_config") or {})))
PYEOF
)"

UID_VAL="${UID_VAL:-}"
TPL_ID="${TPL_ID:-tpl-dev-v2}"

# ---- validate uid ----
if ! [[ "$UID_VAL" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  echo "ERROR: invalid uid '$UID_VAL' (must match ^[A-Za-z0-9_-]{1,64}$)" >&2
  exit 2
fi

CONTAINER_NAME="dagu-u-${UID_VAL}"
USER_DIR="$USER_DATA_ROOT/$UID_VAL"

# ---- template lookup (simple YAML parser for the constrained format) ----
tpl_value() { # $1 = field name
  sed -n "/^  ${TPL_ID}:/,/^  [^ ]/p" "$TEMPLATES_YAML" \
    | grep -m1 "^    ${1}:" \
    | cut -d: -f2- | sed 's/^ //' | tr -d '"'
}

# Resolve a template path: absolute paths pass through, relative paths are
# anchored to the deployment root (DAGU_GATE_ROOT).
resolve_gate_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$DAGU_GATE_ROOT" "$1" ;;
  esac
}

IMAGE="$(tpl_value image)"
TPL_WORKSPACE="$(resolve_gate_path "$(tpl_value workspace_dir)")"
TPL_OPENCODE="$(resolve_gate_path "$(tpl_value opencode_config)")"
PROJECT_PATH="$(tpl_value project_relative_path)"
DEFAULT_CPU="$(tpl_value default_cpu)"
DEFAULT_MEM="$(tpl_value default_memory)"
if [ -z "$IMAGE" ] || [ -z "$TPL_WORKSPACE" ] || [ -z "$PROJECT_PATH" ]; then
  echo "ERROR: template '$TPL_ID' is missing required fields in $TEMPLATES_YAML" >&2
  exit 2
fi
CPU="${CPU:-$DEFAULT_CPU}"
MEM="${MEM:-$DEFAULT_MEM}"
# Docker CLI accepts lowercase units (g/m) but not Kubernetes-style "Gi"/"Mi".
MEM="$(printf '%s' "$MEM" | tr '[:upper:]' '[:lower:]' | tr -d 'i')"

# ---- wait until the container's 4096 port answers ----
wait_ready() {
  local ip deadline
  ip="$(docker inspect --format '{{(index .NetworkSettings.Networks "'"$DOCKER_NETWORK"'").IPAddress}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    echo "ERROR: cannot resolve container IP on network $DOCKER_NETWORK" >&2
    exit 3
  fi
  deadline=$(( $(date +%s) + READINESS_TIMEOUT ))
  until curl -s -o /dev/null --max-time 2 "http://$ip:$OPENCODE_PORT/"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: container did not become ready on port $OPENCODE_PORT within ${READINESS_TIMEOUT}s" >&2
      exit 4
    fi
    sleep 1
  done
}

echo "create_user: uid=$UID_VAL username=$USERNAME template=$TPL_ID cpu=$CPU mem=$MEM"
echo "create_user: extra_config=$EXTRA_JSON"

# ---- idempotency: container already exists ----
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  ACTUAL_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
  if [ "$ACTUAL_IMAGE" != "$IMAGE" ]; then
    echo "ERROR: container $CONTAINER_NAME exists with unexpected image '$ACTUAL_IMAGE'" >&2
    exit 3
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]; then
    docker start "$CONTAINER_NAME" >/dev/null
  fi
  wait_ready
  echo "create_user: container already exists and is ready"
  exit 0
fi

# ---- docker/image/network prerequisites ----
if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
  echo "ERROR: docker network '$DOCKER_NETWORK' does not exist" >&2
  exit 3
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: image '$IMAGE' is not loaded" >&2
  exit 3
fi
if [ ! -d "$TPL_WORKSPACE" ]; then
  echo "ERROR: template workspace '$TPL_WORKSPACE' does not exist" >&2
  exit 3
fi
if [ ! -f "$TPL_OPENCODE" ]; then
  echo "ERROR: opencode config template '$TPL_OPENCODE' does not exist" >&2
  exit 3
fi

CREATED_USER_DIR=false
CREATED_CONTAINER=false
TMP_DIR="$USER_DATA_ROOT/.${UID_VAL}.tmp-$$"

cleanup() {
  if [ "$CREATED_CONTAINER" = true ] && docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [ "$CREATED_USER_DIR" = true ] && [ -e "$USER_DIR" ]; then
    rm -rf "$USER_DIR"
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ---- existing user dir validation ----
if [ -e "$USER_DIR" ]; then
  if [ -L "$USER_DIR" ]; then
    echo "ERROR: user data directory must not be a symbolic link" >&2
    exit 3
  fi
  if [ ! -d "$USER_DIR/workspace/$PROJECT_PATH" ] || [ ! -f "$USER_DIR/config/opencode.json" ]; then
    echo "ERROR: existing user directory is incomplete; refusing to overwrite it" >&2
    exit 3
  fi
fi

# ---- stage template copy ----
mkdir -p "$USER_DATA_ROOT"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cp -a "$TPL_WORKSPACE" "$TMP_DIR/workspace"
mkdir -p "$TMP_DIR/config"
cp -a "$TPL_OPENCODE" "$TMP_DIR/config/opencode.json"

PROJECT_DIR="$TMP_DIR/workspace/$PROJECT_PATH"
mkdir -p "$PROJECT_DIR/scripts"

# inject server.json (gateway URLs for the OpenCode app)
"$PYTHON3" - "$PROJECT_DIR/config/server.json" "$GATEWAY_PUBLIC_BASE_URL" <<'PYEOF'
import json
import os
import sys

path, base_url = sys.argv[1], sys.argv[2]
config = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as fh:
        config = json.load(fh)
config.update(
    {
        "baseUrl": base_url,
        "appProxyBaseUrl": base_url.rstrip("/") + "/app-proxy",
        "description": "Dashboard access through the central OCC gateway",
    }
)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF

mv "$TMP_DIR" "$USER_DIR"
CREATED_USER_DIR=true

# ---- docker run ----
CREATED_CONTAINER=true
docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$DOCKER_NETWORK" \
  --cpus "$CPU" \
  --memory "$MEM" \
  --restart unless-stopped \
  -v "$USER_DIR/workspace:/workspace" \
  -v "$USER_DIR/config/opencode.json:/root/.config/opencode/opencode.json:ro" \
  -w "/workspace/$PROJECT_PATH" \
  -e "OPENCODE_PORT=$OPENCODE_PORT" \
  -e "OPENCODE_EXECUTABLE=$OPENCODE_EXECUTABLE" \
  "$IMAGE" >/dev/null

wait_ready
trap - EXIT
echo "create_user: done uid=$UID_VAL url=$GATEWAY_PUBLIC_BASE_URL/u/$UID_VAL"
