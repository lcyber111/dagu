#!/usr/bin/env bash
# dagu-gate workerd_guard —— 守护宿主 workerd：进程不在或 9090 未监听时自动拉起
# 注意：重启前等待旧进程完全退出（DO 存储锁），避免新实例阻塞启动。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$DAGU_ROOT"

restart_workerd() {
  echo "workerd_guard: restarting workerd"
  pkill -f "workerd serve --watch workerd/config.capnp" 2>/dev/null || true
  sleep 3
  nohup ./workerd/workerd serve --watch workerd/config.capnp >> logs/workerd-app.log 2>&1 &
  sleep 2
  if ss -lntp 2>/dev/null | grep -q ":9090\b"; then
    echo "workerd_guard: restarted OK (9090 listening)"
  else
    echo "workerd_guard: restart initiated, listener pending" >&2
  fi
}

if ! pgrep -f "workerd serve --watch workerd/config.capnp" >/dev/null 2>&1; then
  restart_workerd
elif ! ss -lntp 2>/dev/null | grep -q ":9090\b"; then
  echo "workerd_guard: process alive but 9090 not listening"
  restart_workerd
else
  echo "workerd_guard: healthy"
fi
