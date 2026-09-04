#!/usr/bin/env bash
# sync_light_app.sh — 把 light-app/AGENTS.md/opencode.json 从模板同步到存量用户
#
# 背景: 同事的 agents_gen 由他独立维护（push 到 git_origin，再手动同步到模板与存量用户）。
#       本脚本只负责“轻应用侧”三件套的同步，与 agents_gen 完全解耦：
#         - light-app/       （我们的 SOP/脚本/运行时 JS）
#         - AGENTS.md        （version0802 入口路由）
#         - opencode.json    （模板级配置 → 各用户 config/opencode.json）
#       绝不触碰 agents_gen / user_space / .apps / .selected。
# 用法: bash scripts/sync_light_app.sh [DAGU_ROOT]   （默认取脚本所在目录的上级，即 dagu-run）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TPL_V="templates/tpl-dev-v2"
V0802="workspace/version0802"

TPL_LIGHT="$ROOT/$TPL_V/$V0802/light-app"
TPL_AGENTSMD="$ROOT/$TPL_V/$V0802/AGENTS.md"
TPL_OPENCODE="$ROOT/$TPL_V/opencode.json"

# 平台网关地址：优先环境变量，其次 install.sh 写入的 $ROOT/.deploy-env
GATEWAY_PUBLIC_BASE_URL="${GATEWAY_PUBLIC_BASE_URL:-}"
if [ -z "$GATEWAY_PUBLIC_BASE_URL" ] && [ -f "$ROOT/.deploy-env" ]; then
  GATEWAY_PUBLIC_BASE_URL="$(sed -n 's/^GATEWAY_PUBLIC_BASE_URL=//p' "$ROOT/.deploy-env" | tail -1)"
fi
GATEWAY_INTERNAL_BASE_URL="${GATEWAY_INTERNAL_BASE_URL:-http://caddy-gateway:9088}"

[ -d "$TPL_LIGHT" ]   || { echo "ERROR: 模板缺少 light-app: $TPL_LIGHT" >&2; exit 1; }
[ -f "$TPL_AGENTSMD" ] || { echo "ERROR: 模板缺少 AGENTS.md: $TPL_AGENTSMD" >&2; exit 1; }
[ -f "$TPL_OPENCODE" ] || { echo "ERROR: 模板缺少 opencode.json: $TPL_OPENCODE" >&2; exit 1; }

sync_v0802() {
  local dest="$1"
  mkdir -p "$dest"
  # 模板自身：light-app/AGENTS.md 就是源，跳过自拷贝（只同步到用户侧）
  if [ "$dest" = "$ROOT/$TPL_V/$V0802" ]; then
    return 0
  fi
  mkdir -p "$dest/light-app"
  cp -a "$TPL_LIGHT/." "$dest/light-app/"
  cp -a "$TPL_AGENTSMD" "$dest/AGENTS.md"
}

# 模板自身就是源（light-app/AGENTS.md/opencode.json 都在模板里），无需自同步；
# 下面只把三件套同步到存量用户。

# 存量用户
for d in "$ROOT"/users/*; do
  [ -d "$d" ] || continue
  if [ ! -d "$d/$V0802" ]; then
    echo "skip(no v0802): $d"
    continue
  fi
  sync_v0802 "$d/$V0802"
  if [ -f "$d/config/opencode.json" ]; then
    cp -a "$TPL_OPENCODE" "$d/config/opencode.json"
  fi
  if [ -n "$GATEWAY_PUBLIC_BASE_URL" ]; then
    mkdir -p "$d/workspace/.platform"
    _uid="$(basename "$d")"
    printf '{"baseUrl": "%s", "internalBaseUrl": "%s", "uid": "%s"}\n' \
      "$GATEWAY_PUBLIC_BASE_URL" "$GATEWAY_INTERNAL_BASE_URL" "$_uid" > "$d/workspace/.platform/gateway.json"
  fi
  echo "synced: $d"
done

echo "sync_light_app: done"
