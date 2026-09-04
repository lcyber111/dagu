#!/usr/bin/env bash
# sync_app_libs.sh - 把 light-app/lib 全部共享前端资产同步到宿主 app-libs
# 用法: bash scripts/sync_app_libs.sh [DAGU_ROOT]
# 说明: 轻应用页面加载的 lib/... 来自宿主 app-libs（workerd disk 绑定）。
#       light-app/lib 是唯一真相源：dashboard(运行时 JS) + echarts/echarts-maps/
#       fontawesome/chartjs/markdown（图表/地图/图标渲染所需，缺一页面空白）。
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$ROOT/templates/tpl-dev-v2/workspace/version0802/light-app/lib"
DST="$ROOT/app-libs"

if [ ! -d "$SRC" ]; then
  echo "ERROR: light-app lib not found: $SRC" >&2
  exit 1
fi
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"
echo "app-libs <- light-app/lib (共享前端资产已同步)"
