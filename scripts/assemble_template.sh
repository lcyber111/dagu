#!/usr/bin/env bash
# assemble_template.sh — 组装并打包 tpl-dev-v2 模板
# 结构: tpl-dev-v2/{opencode.json, workspace/version0802/{agents_gen, AGENTS.md, light-app}}
# 用法: bash scripts/assemble_template.sh <同事 agents_gen 目录> [输出 tar 路径]
# 说明: agents_gen 由同事独立维护（git），本脚本只做"组装 + 打包"，
#       不修改 agents_gen 内容；light-app 与 AGENTS.md 来自本仓库 templates/。
set -euo pipefail

GEN_SRC="${1:?用法: bash scripts/assemble_template.sh <agents_gen目录> [输出tar]}"
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-$PKG/deploy/templates/tpl-dev-v2.tar.gz}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -d "$GEN_SRC" ] || { echo "ERROR: agents_gen 目录不存在: $GEN_SRC" >&2; exit 1; }
[ -d "$PKG/templates/light-app" ] || { echo "ERROR: 仓库缺少 templates/light-app" >&2; exit 1; }
[ -f "$PKG/templates/AGENTS.md" ] || { echo "ERROR: 仓库缺少 templates/AGENTS.md" >&2; exit 1; }
[ -f "$PKG/templates/opencode.json" ] || { echo "ERROR: 仓库缺少 templates/opencode.json" >&2; exit 1; }

mkdir -p "$TMP/tpl-dev-v2/workspace/version0802"
if [ -d "$GEN_SRC/.git" ]; then
  # git 仓库：只打包跟踪内容（git archive），剔除 .git / user_space / logs / temp 等运行时残留，
  # 保证模板包与机器无关、跨机一致。
  mkdir -p "$TMP/tpl-dev-v2/workspace/version0802/agents_gen"
  git -C "$GEN_SRC" archive HEAD | tar -x -C "$TMP/tpl-dev-v2/workspace/version0802/agents_gen"
else
  cp -a "$GEN_SRC" "$TMP/tpl-dev-v2/workspace/version0802/agents_gen"
  # 非 git 目录：剔除运行时残留与版本目录
  rm -rf "$TMP/tpl-dev-v2/workspace/version0802/agents_gen/.git" \
         "$TMP/tpl-dev-v2/workspace/version0802/agents_gen/user_space" \
         "$TMP/tpl-dev-v2/workspace/version0802/agents_gen/logs" \
         "$TMP/tpl-dev-v2/workspace/version0802/agents_gen/temp"
  find "$TMP/tpl-dev-v2/workspace/version0802/agents_gen" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
fi
cp -a "$PKG/templates/AGENTS.md" "$TMP/tpl-dev-v2/workspace/version0802/AGENTS.md"
cp -a "$PKG/templates/light-app" "$TMP/tpl-dev-v2/workspace/version0802/light-app"
cp -a "$PKG/templates/opencode.json" "$TMP/tpl-dev-v2/opencode.json"

mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$TMP" tpl-dev-v2
echo "template written: $OUT"
