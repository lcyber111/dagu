#!/usr/bin/env bash
# dagu-gate: delete a user environment container and reclaim resources.
#
# Reads WEBHOOK_PAYLOAD (JSON with uid/force/archive_data). Archive data
# before delete when archive_data=true (default), force cleans up incomplete
# state, and repeated deletes are idempotent.
set -euo pipefail

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
ARCHIVE_DIR="${ARCHIVE_DIR:-$DAGU_GATE_ROOT/archive}"

PAYLOAD="${WEBHOOK_PAYLOAD:-}"
if [ -z "$PAYLOAD" ]; then
  echo "ERROR: WEBHOOK_PAYLOAD is empty" >&2
  exit 1
fi

eval "$("$PYTHON3" - "$PAYLOAD" <<'PYEOF'
import json
import sys

def q(v):
    return "'" + str(v).replace("'", "'\\''") + "'"

p = json.loads(sys.argv[1])
if isinstance(p, dict) and "payload" in p:
    p = p["payload"]
print("UID_VAL=%s" % q(p.get("uid", "")))
print("FORCE=%s" % q(str(p.get("force", False)).lower()))
print("ARCHIVE_DATA=%s" % q(str(p.get("archive_data", True)).lower()))
PYEOF
)"

if ! [[ "$UID_VAL" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  echo "ERROR: invalid uid '$UID_VAL'" >&2
  exit 2
fi

CONTAINER_NAME="dagu-u-${UID_VAL}"
USER_DIR="$USER_DATA_ROOT/$UID_VAL"
FORCE="${FORCE:-false}"
ARCHIVE_DATA="${ARCHIVE_DATA:-true}"

echo "delete_user: uid=$UID_VAL force=$FORCE archive_data=$ARCHIVE_DATA"

if [ "$ARCHIVE_DATA" = true ] && [ -e "$USER_DIR" ]; then
  mkdir -p "$ARCHIVE_DIR"
  ARCHIVE_FILE="$ARCHIVE_DIR/${UID_VAL}-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo "delete_user: archiving to $ARCHIVE_FILE"
  tar -czf "$ARCHIVE_FILE" -C "$USER_DATA_ROOT" "$UID_VAL"
fi

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "delete_user: removing container $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

if [ -e "$USER_DIR" ]; then
  if [ -L "$USER_DIR" ]; then
    if [ "$FORCE" = true ]; then
      rm -f "$USER_DIR"
    else
      echo "ERROR: user data directory is a symbolic link; use force=true to remove" >&2
      exit 3
    fi
  else
    rm -rf "$USER_DIR"
  fi
fi

echo "delete_user: done uid=$UID_VAL"
