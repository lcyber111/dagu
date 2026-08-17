#!/usr/bin/env bash
# dagu-gate: start a stopped user environment container and wait for readiness.
#
# Reads WEBHOOK_PAYLOAD (JSON with uid) and performs: validate uid -> if the
# container exists and is not running, docker start -> wait for 4096.
# Idempotent: an already-running container is left running, and a missing
# container fails (the starting page keeps retrying until user_create
# completes or an admin intervenes).
set -euo pipefail

# ---- configuration (override via environment) ----
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

DOCKER_NETWORK="${DOCKER_NETWORK:-dagu-net}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-60}"
GATEWAY_PUBLIC_BASE_URL="${GATEWAY_PUBLIC_BASE_URL:-http://127.0.0.1:9088}"

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
print("UID_VAL=%s" % q(p.get("uid", "")))
PYEOF
)"

if ! [[ "$UID_VAL" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  echo "ERROR: invalid uid '$UID_VAL' (must match ^[A-Za-z0-9_-]{1,64}$)" >&2
  exit 2
fi

CONTAINER_NAME="dagu-u-${UID_VAL}"

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

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "ERROR: container $CONTAINER_NAME does not exist" >&2
  exit 3
fi

if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]; then
  echo "user_start: starting container $CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
fi

wait_ready
echo "user_start: done uid=$UID_VAL url=$GATEWAY_PUBLIC_BASE_URL/u/$UID_VAL"
