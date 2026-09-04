#!/usr/bin/env bash
# dagu-gate workerd_guard —— 守护宿主 workerd：进程不在或 9090 未监听时自动拉起
# 注意：重启前等待旧进程完全退出（DO 存储锁），避免新实例阻塞启动。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGU_ROOT="${DAGU_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$DAGU_ROOT"

restart_workerd() {
  echo "workerd_guard: restarting workerd"
  # 按进程名杀（兼容带/不带 --watch 的历史启动方式）
  pkill -x workerd 2>/dev/null || true
  sleep 2
  # workerd 可能忽略 SIGTERM（异常态下会滞留且不再监听 9090），兜底强杀
  pkill -9 -x workerd 2>/dev/null || true
  # 等待旧进程完全退出再启动，避免 9090 bind 冲突
  for _ in $(seq 1 10); do
    pgrep -xc workerd >/dev/null 2>&1 || break
    sleep 1
  done
  nohup ./workerd/workerd serve --watch workerd/config.capnp >> logs/workerd-app.log 2>&1 &
  sleep 2
  if ss -lntp 2>/dev/null | grep -q ":9090\b"; then
    echo "workerd_guard: restarted OK (9090 listening)"
  else
    echo "workerd_guard: restart initiated, listener pending" >&2
  fi
}

if ! pgrep -x workerd >/dev/null 2>&1; then
  restart_workerd
elif ! ss -lntp 2>/dev/null | grep -q ":9090\b"; then
  echo "workerd_guard: process alive but 9090 not listening"
  restart_workerd
else
  echo "workerd_guard: healthy"
fi
