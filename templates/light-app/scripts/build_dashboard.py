"""
build_dashboard.py — 大屏构建脚本（声明式 spec → HTML）

用法: python scripts/build_dashboard.py <spec.json>
产出: html/<spec.name>.html
环境变量:
  LIB_BASE=lib/          App Worker 流程（页面在 /app/<port>/ 下，走 worker 的 lib 路由）
  RUNTIME_SPEC=1         App Worker 运行时模式：spec 不写死进 HTML，输出
                         html/<name>.spec.json 侧车文件；页面加载时 fetch /svc/spec
                         渲染，并订阅 /svc/events（SSE）实时重拉重渲染
  OUT_BASE=...           输出目录覆盖（默认 light-app/../html，即 version0802/html）；
                         页面与侧车 spec 都写入该目录，避免依赖 CWD 或同事 agents_gen 结构
返回: 成功打印 "OK html/<name>.html (N 行)" (exit 0)；失败打印错误列表 (exit 1)

职责:
  1. 严格校验 spec（JSON/必填/图表类型/id 引用/theme）
  2. 渲染 HTML 骨架（header/KPI/rows/图表容器/表格/footer）
  3. 注入 spec.theme 为 CSS 变量覆盖段
  4. 转义注入的数据（防 </script> 破坏）
  5. 复杂图（type:"echarts" + js）原样注入脚本块

图表逻辑全部在 lib/dashboard/dashboard.js 客户端声明式渲染，本脚本保持薄。
"""

import json
import re
import sys
import html as htmlmod
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import jsonschema  # noqa: E402
except ImportError:
    # 用户容器镜像未预装 jsonschema：回退到 light-app 内置纯 Python 副本（scripts/vendor/）
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor'))
    import jsonschema  # noqa: E402

# 页面资源基址：默认 ../lib/（存量静态形态）；App Worker 流程用
# LIB_BASE=lib/（相对路径，页面在 /app/<port>/ 下解析到 worker 的 lib 路由），
# 一行环境变量即可切换。
LIB_BASE = os.environ.get("LIB_BASE", "../lib/").rstrip("/") + "/"
from log_util import get  # noqa: E402

log = get('build')

ALLOWED_TYPES = {'map', 'bar', 'line', 'pie', 'scatter', 'radar', 'echarts'}
ALLOWED_STYLES = {'command', 'report-light', 'report-dark', 'timeline', 'terminal', 'minimal'}
GRID_STYLES = {'command', 'terminal', 'minimal'}
REPORT_STYLES = {'report-light', 'report-dark'}
NAME_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')
ID_CHARSET_RE = re.compile(r'^[A-Za-z0-9_-]+$')
HEX_RE = re.compile(r'^#[0-9a-fA-F]{6}$')
GRID_RE = re.compile(r'^(\d+(?:\.\d+)?(?:fr|px|%|rem|em)?)(\s+\d+(?:\.\d+)?(?:fr|px|%|rem|em)?)*$')
# 表格交互自动阈值：行数 ≥ AUTO_ROWS 时自动启用搜索/排序/导出（显式 false 可覆盖）
AUTO_ROWS = 50
TIMELINE_PALETTE = ['#00ff88', '#ffd93d', '#ff8c00', '#4488ff', '#c77dff', '#ff4d4f', '#00d4aa']
STATUS_COLOR = {
    '高危': '#ff4444', '异常': '#ff4444', '严重': '#ff4444',
    '关注': '#ff8c00', '较高': '#ff8c00', '警戒': '#ff8c00',
    '正常': '#44ff88', '恢复': '#44ff88', '成功': '#44ff88',
    '未知': '#8a9aaa', '静默': '#8a9aaa',
}
CSS_VAR_MAP = {
    'primary': '--primary',
    'background': '--bg',
    'bg_soft': '--bg-soft',
    'accent': '--accent',
}


def error(msg):
    log.error(msg)
    print(f'[ERROR] {msg}')
    sys.exit(1)


SCHEMA_PATH = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'templates', 'dashboard-spec.schema.json'))


def validate_schema(spec):
    """按 JSON Schema（唯一契约源）深度校验 spec 结构。"""
    try:
        with open(SCHEMA_PATH, 'r', encoding='utf-8') as f:
            schema = json.load(f)
    except Exception as e:
        error(f'无法加载 schema 文件 {SCHEMA_PATH}: {e}')
    try:
        jsonschema.validate(spec, schema)
    except jsonschema.ValidationError as e:
        path = 'spec' + ''.join(f'[{p}]' if isinstance(p, int) else f'.{p}' for p in e.absolute_path)
        error(f'{path}: {e.message}')


def check_chart_data(spec):
    """跨字段不变量（JSON Schema 无法表达字段间比较），返回错误列表。"""
    errs = []
    for cs in spec['charts']:
        cid = cs['id']
        ctype = cs['type']
        d = cs.get('data', {})
        if ctype in ('bar', 'line', 'radar'):
            vals = d.get('values')
            if not isinstance(vals, list) or not vals:
                continue  # 必填/非空由 schema 兜底
            if isinstance(vals[0], list):
                n = len(vals)
                for field, label in (('legend', '图例'), ('colors', '颜色')):
                    if field in d and (not isinstance(d[field], list) or len(d[field]) != n):
                        errs.append(f'charts[{cid}].data.{field}({len(d[field]) if isinstance(d[field], list) else "非数组"}) 与序列数({n})不一致')
                for i, v in enumerate(vals):
                    if not isinstance(v, list) or not v:
                        errs.append(f'charts[{cid}].data.values[{i}] 序列为空')
                    elif not all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v):
                        errs.append(f'charts[{cid}].data.values[{i}] 含非数字元素')
            else:
                if not all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in vals):
                    errs.append(f'charts[{cid}].data.values 含非数字元素')
                cats = d.get('categories')
                if ctype == 'bar' and isinstance(d.get('colors'), list) and d['colors'] and (
                        not isinstance(cats, list) or len(d['colors']) != len(cats)):
                    errs.append(f'charts[{cid}].data.colors({len(d["colors"])}) 与 categories({len(cats) if isinstance(cats, list) else "非数组"})不一致（单序列 bar 的 colors 为逐柱配色）')
                if ctype == 'line' and isinstance(d.get('colors'), list) and d['colors']:
                    errs.append(f'charts[{cid}].data.colors 单序列 line 不支持逐点配色（仅 bar 支持），请用多序列或删除 colors')
    return errs


def validate_docs_structure(docs, who):
    """docs 文本块结构校验。"""
    for i, d in enumerate(docs):
        if not isinstance(d, dict):
            error(f'{who}.docs[{i}] 必须是对象')
        if not isinstance(d.get('text'), str) or not d['text'].strip():
            error(f'{who}.docs[{i}].text 必须是非空字符串')
        color = d.get('color')
        if color is not None and (not isinstance(color, str) or not HEX_RE.match(color)):
            error(f'{who}.docs[{i}].color 必须是 #RRGGBB 十六进制颜色: {color}')
        if 'tag' in d and (not isinstance(d.get('tag'), str) or not d['tag'].strip()):
            error(f'{who}.docs[{i}].tag 必须是非空字符串')


def validate_cards_structure(cards, who):
    """cards 实体卡片结构校验。"""
    if not isinstance(cards, dict):
        error(f'{who}.cards 必须是对象')
    layout = cards.get('layout')
    if layout is not None and layout not in ('vertical', 'horizontal'):
        error(f'{who}.cards.layout 必须是 "vertical" 或 "horizontal"')
    items = cards.get('items')
    if not isinstance(items, list) or not items:
        error(f'{who}.cards.items 缺失或为空')
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            error(f'{who}.cards.items[{i}] 必须是对象')
        if not isinstance(it.get('id'), str) or not it['id'].strip():
            error(f'{who}.cards.items[{i}].id 缺失或为空')
        color = it.get('color')
        if color is not None and (not isinstance(color, str) or not HEX_RE.match(color)):
            error(f'{who}.cards.items[{i}].color 必须是 #RRGGBB 十六进制颜色: {color}')
        meta = it.get('meta')
        if meta is not None:
            if not isinstance(meta, list) or not all(
                    isinstance(r, list) and len(r) >= 2 and all(isinstance(x, str) for x in r) for r in meta):
                error(f'{who}.cards.items[{i}].meta 必须是 [label,value] 字符串对数组')
        photo = it.get('photo')
        if photo is not None:
            if not isinstance(photo, dict):
                error(f'{who}.cards.items[{i}].photo 必须是对象')
            if not isinstance(photo.get('src'), str) or not photo['src'].strip():
                error(f'{who}.cards.items[{i}].photo.src 缺失或为空')


def validate_layout_refs(spec, blocks, who):
    """report/timeline 的 blocks 引用校验：chart/table id 必须已声明。"""
    chart_ids = {cs['id'] for cs in spec['charts']}
    table_ids = {t['id'] for t in spec.get('tables', [])}
    for b in blocks:
        if not isinstance(b, dict):
            error(f'{who} blocks[] 项必须是对象: {b}')
        if 'chart' in b:
            if b['chart'] not in chart_ids:
                error(f'{who} blocks 引用了不存在的图表 id: {b["chart"]}')
        elif 'table' in b:
            if b['table'] not in table_ids:
                error(f'{who} blocks 引用了不存在的表格 id: {b["table"]}')
        elif 'row' in b:
            refs = b['row']
            if not isinstance(refs, list) or not refs:
                error(f'{who} blocks[].row 必须是非空 id 数组')
            for ref in refs:
                if ref not in chart_ids and ref not in table_ids:
                    error(f'{who} blocks[].row 引用了不存在的图表/表格 id: {ref}')
        elif 'text' in b:
            if not isinstance(b.get('text'), str) or not b['text'].strip():
                error(f'{who} blocks[].text 必须是非空字符串')
        elif 'doc' in b:
            validate_docs_structure([b['doc']], who)
        elif 'docs' in b:
            docs = b['docs']
            if not isinstance(docs, list) or not docs:
                error(f'{who} blocks[].docs 必须是非空数组')
            validate_docs_structure(docs, who)
        elif 'cards' in b:
            validate_cards_structure(b['cards'], who)
        else:
            error(f'{who} blocks[] 项非法: {b}（需含 text/chart/table/row/doc/docs/cards 之一）')


def validate(spec):
    if not isinstance(spec, dict):
        error('spec 必须是 JSON 对象')

    name = spec.get('name')
    if not name or not isinstance(name, str) or not NAME_RE.match(name):
        error("spec.name 缺失或非法（需 kebab-case：小写字母/数字/连字符，如 'carrier-ais-20260728'）")

    if not spec.get('title') or not isinstance(spec['title'], str):
        error('spec.title 缺失')

    style = spec.get('style', 'command')
    if not isinstance(style, str) or style not in ALLOWED_STYLES:
        error(f'spec.style 非法: {style}（允许: {", ".join(sorted(ALLOWED_STYLES))}）')

    for field in ('kpis', 'charts'):
        if field not in spec or not isinstance(spec[field], list):
            error(f'spec.{field} 缺失或不是数组')
    if style in GRID_STYLES:
        if 'rows' not in spec or not isinstance(spec['rows'], list):
            error('spec.rows 缺失或不是数组（style=command/terminal/minimal 必须提供 rows）')

    # theme 校验
    theme = spec.get('theme', {})
    if not isinstance(theme, dict):
        error('spec.theme 必须是对象')
    for k, v in theme.items():
        if k not in CSS_VAR_MAP:
            error(f'spec.theme 未知字段: {k}（允许: {", ".join(CSS_VAR_MAP)}）')
        if not isinstance(v, str) or not HEX_RE.match(v):
            error(f'spec.theme.{k} 必须是 #RRGGBB 十六进制颜色')

    # kpis 校验
    for k in spec.get('kpis', []):
        if not isinstance(k, dict):
            error('spec.kpis[] 必须是对象')
        color = k.get('color')
        if color is not None and (not isinstance(color, str) or not HEX_RE.match(color)):
            error(f'spec.kpis[].color 必须是 #RRGGBB 十六进制颜色: {color}')

    # charts 校验
    chart_ids = set()
    for cs in spec['charts']:
        cid = cs.get('id')
        if not cid or not isinstance(cid, str):
            error('charts[].id 缺失')
        if not ID_CHARSET_RE.match(cid):
            error(f'charts[].id 含非法字符: {cid!r}（仅字母/数字/下划线/连字符，会拼入 HTML id 与 JS 选择器）')
        if cid in chart_ids:
            error(f'charts[].id 重复: {cid}')
        chart_ids.add(cid)

        ctype = cs.get('type')
        if ctype not in ALLOWED_TYPES:
            error(f'charts[{cid}].type 非法: {ctype}（允许: {", ".join(sorted(ALLOWED_TYPES))}）')

        if ctype == 'echarts':
            if 'option' not in cs and 'js' not in cs:
                error(f'charts[{cid}] type=echarts 必须提供 option(JSON) 或 js(原始脚本) 之一')
            if 'option' in cs and not isinstance(cs['option'], dict):
                error(f'charts[{cid}].option 必须是对象')
            if 'option' in cs and 'series' in cs['option'] and not isinstance(cs['option']['series'], list):
                error(f'charts[{cid}].option.series 必须是数组')
            if 'js' in cs and not isinstance(cs['js'], str):
                error(f'charts[{cid}].js 必须是字符串')

        if ctype == 'map':
            for key in ('markers', 'circles', 'lines'):
                if key in cs and not isinstance(cs[key], list):
                    error(f'charts[{cid}].{key} 必须是数组')
            if 'categories' in cs and not isinstance(cs['categories'], dict):
                error(f'charts[{cid}].categories 必须是对象')
            if 'geo' in cs and not isinstance(cs['geo'], dict):
                error(f'charts[{cid}].geo 必须是对象')

    # tables 校验
    table_ids = set()
    for t in spec.get('tables', []):
        tid = t.get('id')
        if not tid or not isinstance(tid, str):
            error('tables[].id 缺失')
        if not ID_CHARSET_RE.match(tid):
            error(f'tables[].id 含非法字符: {tid!r}（仅字母/数字/下划线/连字符，会拼入 HTML id 与 JS 选择器）')
        if tid in table_ids:
            error(f'tables[].id 重复: {tid}')
        table_ids.add(tid)
        if not t.get('title') or not isinstance(t['title'], str):
            error(f'tables[{tid}].title 缺失')
        if 'columns' not in t or not isinstance(t['columns'], list) or not t['columns']:
            error(f'tables[{tid}].columns 缺失或为空')
        if 'rows' not in t or not isinstance(t['rows'], list):
            error(f'tables[{tid}].rows 缺失')
        if 'formatters' in t and not isinstance(t['formatters'], dict):
            error(f'tables[{tid}].formatters 必须是对象')
        for col, fmt in t.get('formatters', {}).items():
            if not isinstance(fmt, dict):
                continue
            col_def = fmt.get('color')
            if isinstance(col_def, str) and not HEX_RE.match(col_def):
                error(f'tables[{tid}].formatters[{col}].color 必须是 #RRGGBB 十六进制颜色: {col_def}')
            elif isinstance(col_def, dict):
                for val, c in col_def.items():
                    if not isinstance(c, str) or not HEX_RE.match(c):
                        error(f'tables[{tid}].formatters[{col}].color[{val}] 必须是 #RRGGBB 十六进制颜色: {c}')

    # rows 布局引用校验（仅网格布局；report/timeline 由 report/timeline 结构承载）
    for row in spec.get('rows', []):
        if not isinstance(row, dict):
            error('rows[] 必须是对象')
        grid = row.get('grid', '1fr')
        if not isinstance(grid, str) or not GRID_RE.match(grid):
            error(f'rows[].grid 非法: {grid}（需如 "1fr"、"2fr 1fr"）')
        cells = row.get('cells')
        if not isinstance(cells, list) or not cells:
            error('rows[].cells 缺失或为空')
        for cell in cells:
            if 'chart' in cell:
                if cell['chart'] not in chart_ids:
                    error(f"rows 引用了不存在的图表 id: {cell['chart']}")
            elif 'table' in cell:
                if cell['table'] not in table_ids:
                    error(f"rows 引用了不存在的表格 id: {cell['table']}")
            elif 'stack' in cell:
                for item in cell['stack']:
                    if isinstance(item, str):
                        if item not in chart_ids:
                            error(f"rows stack 引用了不存在的图表 id: {item}")
                    elif isinstance(item, dict):
                        # stack 内嵌套横向子行（如 [{"grid":"1fr 1fr","cells":[...]}]）
                        subgrid = item.get('grid', '1fr')
                        if not isinstance(subgrid, str) or not GRID_RE.match(subgrid):
                            error(f'rows stack 子行 grid 非法: {subgrid}')
                        subcells = item.get('cells')
                        if not isinstance(subcells, list) or not subcells:
                            error('rows stack 子行 cells 缺失或为空')
                        for iid in subcells:
                            if iid not in chart_ids:
                                error(f"rows stack 子行引用了不存在的图表 id: {iid}")
                    else:
                        error(f'rows stack 项非法: {item}（需为图表 id 或 {grid,cells} 子行对象）')
            elif 'text' in cell:
                if not isinstance(cell.get('text'), str) or not cell['text'].strip():
                    error('rows[].cells[].text 必须是非空字符串')
            elif 'docs' in cell:
                docs = cell['docs']
                if not isinstance(docs, list) or not docs:
                    error('rows[].cells[].docs 必须是非空数组')
                validate_docs_structure(docs, 'rows[].cells')
            elif 'cards' in cell:
                validate_cards_structure(cell['cards'], 'rows[].cells')
            else:
                error(f'rows[].cells 项非法: {cell}（需含 chart/table/stack/text/docs/cards 之一）')

    if style in REPORT_STYLES:
        report = spec.get('report')
        if not isinstance(report, dict):
            error('spec.report 缺失（style=report-light/report-dark 必须提供 report 结构）')
        if not isinstance(report.get('sections'), list) or not report['sections']:
            error('spec.report.sections 缺失或为空')
        for i, sec in enumerate(report['sections']):
            if not isinstance(sec, dict):
                error(f'spec.report.sections[{i}] 必须是对象')
            if not isinstance(sec.get('title'), str) or not sec['title'].strip():
                error(f'spec.report.sections[{i}].title 缺失或为空')
            blocks = sec.get('blocks')
            if not isinstance(blocks, list) or not blocks:
                error(f'spec.report.sections[{i}].blocks 缺失或为空')
            validate_layout_refs(spec, blocks, f'spec.report.sections[{i}]')

    if style == 'timeline':
        tl = spec.get('timeline')
        if not isinstance(tl, dict):
            error('spec.timeline 缺失（style=timeline 必须提供 timeline 结构）')
        phases = tl.get('phases')
        if not isinstance(phases, list) or not phases:
            error('spec.timeline.phases 缺失或为空')
        for i, ph in enumerate(phases):
            if not isinstance(ph, dict):
                error(f'spec.timeline.phases[{i}] 必须是对象')
            if not isinstance(ph.get('time'), str) or not ph['time'].strip():
                error(f'spec.timeline.phases[{i}].time 缺失或为空')
            if not isinstance(ph.get('heading'), str) or not ph['heading'].strip():
                error(f'spec.timeline.phases[{i}].heading 缺失或为空')
            for field, label in (('type', 'type'), ('status', 'status')):
                v = ph.get(field)
                if v is not None and (not isinstance(v, str) or not v.strip()):
                    error(f'spec.timeline.phases[{i}].{label} 必须是非空字符串')
            for field in ('color', 'status_color'):
                v = ph.get(field)
                if v is not None and (not isinstance(v, str) or not HEX_RE.match(v)):
                    error(f'spec.timeline.phases[{i}].{field} 必须是 #RRGGBB 十六进制颜色: {v}')
            blocks = ph.get('blocks', [])
            if blocks:
                validate_layout_refs(spec, blocks, f'spec.timeline.phases[{i}]')

    return True


def esc(s):
    return htmlmod.escape(str(s), quote=False)


def render_header(spec, has_fa):
    title = spec['title']
    subtitle = spec.get('subtitle')
    icon = spec.get('header_icon', '')
    badge = spec.get('header_badge', '离线部署')
    time = spec.get('time', '')

    logo = f'<div class="header-logo"><i class="{esc(icon)}"></i></div>' if icon and has_fa else ''
    h1 = f'<h1><span>{esc(title)}</span></h1>'
    sub_parts = []
    if subtitle:
        sub_parts.append(esc(subtitle))
    sub_html = f'<div class="subtitle">{" &middot; ".join(sub_parts)}</div>' if sub_parts else ''

    time_html = f'<span class="time"><i class="far fa-clock"></i> {esc(time)}</span>' if time else ''
    badge_icon = '<i class="fas fa-database"></i> ' if has_fa else ''
    badge_html = f'<span class="badge">{badge_icon}{esc(badge)}</span>'

    return f'''<div class="header">
  <div class="header-left">
    {logo}
    <div>
      {h1}
      {sub_html}
    </div>
  </div>
  <div class="header-right">
    {time_html}
    {badge_html}
  </div>
</div>'''


def render_kpis(spec):
    cards = []
    for k in spec.get('kpis', []):
        label = k.get('label', '')
        color = k.get('color', 'var(--primary)')
        v = k.get('value', '')
        if isinstance(v, dict):
            text = str(v.get('text', ''))
            sub = v.get('sub')
            sub_cls = ' inline' if sub else ''
        else:
            text = str(v)
            sub = k.get('sub')
            sub_cls = ' inline' if sub else ''
        if sub is None:
            sub = ''
            sub_cls = ''
        data_value = ''
        if re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', text):
            data_value = f' data-value="{text}"'
        sub_html = f'<div class="kpi-sub{sub_cls}">{esc(sub)}</div>' if sub else ''
        cards.append(f'''  <div class="kpi-card"{data_value}>
    <div class="kpi-label">{esc(label)}</div>
    <div class="kpi-value" style="color:{esc(color)}">{esc(text)}</div>
    {sub_html}
  </div>''')
    if not cards:
        return ''
    cls = 'kpi-row kpi-row-dense' if len(cards) >= 6 else 'kpi-row'
    return f'<div class="{cls}">\n' + '\n'.join(cards) + '\n</div>'


def render_table_card(t):
    col_fmt = t.get('formatters', {})
    max_h = t.get('maxHeight')
    style = f' style="max-height:{int(max_h)}px"' if max_h else ''
    # 交互能力按行数自动判定：≥AUTO_ROWS 自动启用搜索/排序；显式布尔可覆盖（false 关闭 / true 强制）
    auto = len(t.get('rows', [])) >= AUTO_ROWS
    searchable = bool(t.get('searchable', auto))
    sortable = bool(t.get('sortable', auto))
    page_size = t.get('pageSize')

    thead = ''.join(f'<th data-col="{i}"{" data-sortable" if sortable else ""}>{esc(c)}</th>'
                    for i, c in enumerate(t['columns']))
    body_rows = []
    for row in t['rows']:
        tds = []
        for idx, col in enumerate(t['columns']):
            raw = row[idx] if idx < len(row) else ''
            val = esc(raw)
            fmt = col_fmt.get(col, {})
            if isinstance(fmt, dict):
                # tag 白名单映射
                tag_map = fmt.get('tag')
                if isinstance(tag_map, dict) and raw in tag_map:
                    val = f'<span class="tag {esc(tag_map[raw])}">{val}</span>'
                # color 映射（固定色或按值映射）
                col_def = fmt.get('color')
                color = None
                if isinstance(col_def, str):
                    color = col_def
                elif isinstance(col_def, dict):
                    color = col_def.get(raw)
                if color:
                    weight = f';font-weight:{int(fmt.get("weight", 600))}' if fmt.get('weight') else ''
                    val = f'<span style="color:{esc(color)}{weight}">{val}</span>'
                # bold
                if fmt.get('bold'):
                    val = f'<strong>{val}</strong>'
                # truncate
                tc = fmt.get('truncate')
                if isinstance(tc, int):
                    val = f'<span style="max-width:{tc}px;display:inline-block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom">{val}</span>'
            # data-sort 保留原始文本用于精确排序（含 formatter 时仍可按原文排序）
            tds.append(f'<td data-sort="{esc(raw)}">{val}</td>')
        body_rows.append('      <tr>' + ''.join(tds) + '</tr>')

    toolbar = ''
    if searchable:
        toolbar = f'<div class="table-toolbar">\n    <input type="search" class="table-search" placeholder="搜索…" aria-label="搜索">\n  </div>'

    pager = ''
    if page_size:
        pager = ('<div class="table-pager">'
                 '<button type="button" class="page-prev" aria-label="上一页">‹</button>'
                 '<span class="page-info"></span>'
                 '<button type="button" class="page-next" aria-label="下一页">›</button>'
                 '</div>')

    attrs = []
    attrs.append(f'data-table-id="{t["id"]}"')
    if searchable:
        attrs.append('data-searchable')
    if sortable:
        attrs.append('data-sortable')
    if page_size:
        attrs.append(f'data-page-size="{int(page_size)}"')

    return f'''  <div class="card" {" ".join(attrs)}>
    <div class="card-header"><h3>{esc(t["title"])}</h3></div>
    {toolbar}
    <div class="card-body no-pad">
      <div class="table-wrap"{style}>
        <table>
          <thead><tr>{thead}</tr></thead>
          <tbody>
{chr(10).join(body_rows)}
          </tbody>
        </table>
      </div>
      {pager}
    </div>
  </div>'''


def render_chart_card(cs):
    title = cs.get('title')
    legend = cs.get('header_legend', [])
    legend_html = ''
    if isinstance(legend, list) and legend:
        items = ''.join(
            f'<span class="legend-item"><span class="legend-dot" style="background:{esc(l["color"])}"></span>{esc(l["label"])}</span>'
            for l in legend)
        legend_html = f'<div class="legend-row">{items}</div>'
    head = ''
    if title:
        head = f'<div class="card-header"><h3>{esc(title)}</h3></div>'
    elif legend_html:
        head = f'<div class="card-header"><div>{legend_html}</div></div>'

    h = int(cs.get('height', 400))
    hstyle = f' style="height:{h}px"'
    body = f'<div id="{cs["id"]}" class="chart-box"{hstyle}></div>'
    return f'  <div class="card">\n{head}\n    <div class="card-body no-pad">{body}</div>\n  </div>'


def render_doc_section(d):
    """单个文本块（判据/结论/分节说明），声明式驱动 .doc-section 组件。"""
    title = d.get('title')
    color = d.get('color') or 'var(--primary)'
    tag = d.get('tag')
    text = d.get('text', '')
    head = ''
    if title:
        bar = f'<span class="doc-sec-bar" style="background:{esc(color)}"></span>'
        title_html = f'<span class="doc-sec-title" style="color:{esc(color)}">{esc(title)}</span>'
        if tag:
            head = f'    <div class="doc-sec-head">\n      {bar}\n      {title_html}\n      <span class="doc-sec-tag">{esc(tag)}</span>\n    </div>\n'
        else:
            head = f'    <div class="doc-sec-head">\n      {bar}\n      {title_html}\n    </div>\n'
    return f'<div class="doc-section">\n{head}    <p class="doc-sec-body">{esc(text)}</p>\n  </div>'


def render_docs_card(cell, cell_key):
    """docs 单元格：一个卡片内堆叠多个文本块（多条等高）。data-docs-cell 供运行时重渲染定位。"""
    title = esc(cell.get('title', ''))
    head = f'<div class="card-header"><h3>{title}</h3></div>' if title else ''
    body = '\n'.join(render_doc_section(d) for d in cell.get('docs', []))
    return f'  <div class="card" data-docs-cell="{cell_key}">\n{head}\n    <div class="card-body">\n{body}\n    </div>\n  </div>'


def render_entity_card(item, horizontal=False):
    """cards 组件内的单个实体卡（照片 + 属性元数据）。
    horizontal=True → 照片左（约 30%）/ 头部+元信息右，复刻存量 uav-card 布局。
    """
    color = item.get('color') or 'var(--primary)'
    eid = esc(item.get('id', ''))
    role = esc(item.get('role', ''))
    photo = item.get('photo') or {}
    src = photo.get('src')
    note = photo.get('note')
    if src:
        photo_html = (
            '<img class="entity-photo-img" src="' + esc(src) + '" alt="" '
            'onerror="this.style.display=\'none\';this.nextElementSibling.style.display=\'flex\'">\n'
            '      <p class="entity-photo-placeholder" style="display:none"><i class="fas fa-image"></i><span>本地照片缺失</span></p>')
    else:
        photo_html = '<p class="entity-photo-placeholder"><i class="fas fa-image"></i><span>本地照片缺失</span></p>'
    note_html = f'\n    <span class="entity-photo-note">{esc(note)}</span>' if note else ''
    meta_rows = []
    for row in (item.get('meta') or []):
        label = esc(row[0])
        v = esc(row[1])
        if len(row) > 2 and row[2]:
            v = f'<b style="color:{esc(row[2])}">{v}</b>'
        meta_rows.append(f'      <div><span>{label}</span>{v}</div>')
    meta_html = '\n'.join(meta_rows)
    if horizontal:
        return f'''  <div class="entity-card entity-card-h" style="border-color:{esc(color)}">
    <div class="entity-photo entity-photo-h">
      {photo_html}
    </div>
    <div class="entity-card-h-right">
      <div class="entity-head">
        <span class="entity-id" style="color:{esc(color)}">{eid}</span>
        <span class="entity-role">{role}</span>
      </div>{note_html}
      <div class="entity-meta">
{meta_html}
      </div>
    </div>
  </div>'''
    return f'''  <div class="entity-card" style="border-color:{esc(color)}">
    <div class="entity-head">
      <span class="entity-id" style="color:{esc(color)}">{eid}</span>
      <span class="entity-role">{role}</span>
    </div>
    <div class="entity-photo">
      {photo_html}
    </div>{note_html}
    <div class="entity-meta">
{meta_html}
    </div>
  </div>'''


def render_cards(card, cell_key):
    """cards 单元格/块：一个卡片内 flex 排布多个实体卡（layout=horizontal 时照片左/信息右）。
    data-cards-cell 供运行时重渲染定位。"""
    title = esc(card.get('title', ''))
    head = f'<div class="card-header"><h3>{title}</h3></div>' if title else ''
    horizontal = card.get('layout') == 'horizontal'
    cls = 'cards cards-h' if horizontal else 'cards'
    cards_html = '\n'.join(render_entity_card(it, horizontal) for it in card.get('items', []))
    return f'  <div class="card" data-cards-cell="{cell_key}">\n{head}\n    <div class="card-body">\n      <div class="{cls}">\n{cards_html}\n      </div>\n    </div>\n  </div>'


def render_rows(spec):
    by_chart = {cs['id']: cs for cs in spec['charts']}
    by_table = {t['id']: t for t in spec.get('tables', [])}
    rows_html = []
    for ri, row in enumerate(spec['rows']):
        grid = esc(row.get('grid', '1fr'))
        cells = []
        for ci, cell in enumerate(row['cells']):
            cell_key = f'{ri}-{ci}'
            if 'chart' in cell:
                cells.append(render_chart_card(by_chart[cell['chart']]))
            elif 'table' in cell:
                cells.append(render_table_card(by_table[cell['table']]))
            elif 'docs' in cell:
                cells.append(render_docs_card(cell, cell_key))
            elif 'cards' in cell:
                cells.append(render_cards(cell['cards'], cell_key))
            elif 'stack' in cell:
                inner = []
                for item in cell['stack']:
                    if isinstance(item, dict):
                        # 嵌套横向子行（并排小图）
                        subgrid = esc(item.get('grid', '1fr'))
                        sub = '\n'.join(render_chart_card(by_chart[iid]) for iid in item['cells'])
                        inner.append(f'<div class="grid-row" style="grid-template-columns:{subgrid}">\n{sub}\n  </div>')
                    else:
                        inner.append(render_chart_card(by_chart[item]))
                cells.append(f'  <div class="stack">\n' + '\n'.join(inner) + '\n  </div>')
            elif 'text' in cell:
                text_title = esc(cell.get('title', ''))
                text_head = f'<div class="card-header"><h3>{text_title}</h3></div>' if text_title else ''
                cells.append(f'  <div class="card">\n{text_head}\n    <div class="card-body">{cell["text"]}</div>\n  </div>')
        rows_html.append(
            f'<div class="grid-row" style="grid-template-columns:{grid}">\n' + '\n'.join(cells) + '\n</div>')
    return '\n'.join(rows_html)


def render_footer(spec):
    items = spec.get('footer', [])
    parts = []
    for it in items:
        parts.append(f'<span class="ft-item"><span class="label">{esc(it.get("label", ""))}:</span> {esc(it.get("value", ""))}</span>')
    time = spec.get('time')
    if time:
        parts.append(f'<span class="ft-item"><span class="label">分析时间:</span> {esc(time)}</span>')
    body = '\n    '.join(parts)
    return f'<div class="footer">\n  <div>\n    {body}\n  </div>\n  <div class="ft-right">离线大屏 &middot; 本地 lib/ 资源</div>\n</div>'


def render_blocks(spec, blocks):
    """report/timeline 的 blocks：text 段落 / chart 单图 / table 单表 / row 并排。"""
    by_chart = {cs['id']: cs for cs in spec['charts']}
    by_table = {t['id']: t for t in spec.get('tables', [])}
    out = []
    for b in blocks:
        if 'chart' in b:
            out.append(render_chart_card(by_chart[b['chart']]))
        elif 'table' in b:
            out.append(render_table_card(by_table[b['table']]))
        elif 'row' in b:
            cells = []
            for ref in b['row']:
                if ref in by_chart:
                    cells.append(render_chart_card(by_chart[ref]))
                else:
                    cells.append(render_table_card(by_table[ref]))
            out.append(
                '<div class="report-grid" style="grid-template-columns:repeat(auto-fit, minmax(320px, 1fr))">\n'
                + '\n'.join(cells) + '\n</div>')
        elif 'text' in b:
            out.append(f'<p class="report-para">{esc(b["text"])}</p>')
        elif 'doc' in b:
            out.append(render_doc_section(b['doc']))
        elif 'docs' in b:
            out.append('\n'.join(render_doc_section(d) for d in b['docs']))
        elif 'cards' in b:
            out.append(render_cards(b['cards']))
    return '\n'.join(out)


def render_report(spec):
    """文书报告布局（style=report-light/report-dark）。"""
    report = spec.get('report') or {}
    meta = []
    if spec.get('time'):
        meta.append(esc(spec['time']))
    meta.append(esc(spec.get('header_badge', '离线部署')))
    for it in spec.get('footer', []):
        meta.append(f"{esc(it.get('label', ''))}：{esc(it.get('value', ''))}")
    meta_html = ' · '.join(meta)

    parts = ['<article class="report">']
    parts.append(f'''  <header class="report-header">
    <h1 class="report-title">{esc(spec['title'])}</h1>
    <div class="report-subtitle">{esc(spec.get('subtitle', ''))}</div>
    <div class="report-meta">{meta_html}</div>
  </header>''')
    kpis = render_kpis(spec)
    if kpis:
        parts.append(f'  <section class="report-kpis">\n{kpis}\n  </section>')
    summary = report.get('summary')
    if summary:
        parts.append(
            f'  <section class="report-section">\n    <h2 class="report-h2">摘要</h2>\n    <p class="report-para">{esc(summary)}</p>\n  </section>')
    for i, sec in enumerate(report.get('sections', [])):
        title = sec.get('title', f'第 {i + 1} 节')
        blocks_html = render_blocks(spec, sec.get('blocks', []))
        parts.append(f'  <section class="report-section">\n    <h2 class="report-h2">{esc(title)}</h2>\n    {blocks_html}\n  </section>')
    conclusion = report.get('conclusion')
    if conclusion:
        parts.append(
            f'  <section class="report-section report-conclusion">\n    <h2 class="report-h2">结论</h2>\n    <p class="report-para">{esc(conclusion)}</p>\n  </section>')
    parts.append(render_footer(spec))
    parts.append('</article>')
    return '\n'.join(parts)


def render_timeline(spec):
    """时间线布局（style=timeline）：阶段类型变色 + 状态 tag + 自动图例。"""
    phases = (spec.get('timeline') or {}).get('phases', [])

    # 阶段类型 → 颜色（显式 color 优先，缺省按调色板确定性分配；供图例与 marker/pill 共用）
    type_colors = {}
    for ph in phases:
        t = ph.get('type')
        if t and t not in type_colors:
            type_colors[t] = ph.get('color') or TIMELINE_PALETTE[len(type_colors) % len(TIMELINE_PALETTE)]

    legend_html = ''
    if type_colors:
        items = ''.join(
            f'<span class="timeline-legend-item"><span class="timeline-legend-dot" style="background:{esc(c)}"></span>{esc(t)}</span>'
            for t, c in type_colors.items())
        legend_html = f'<div class="timeline-legend">{items}</div>\n'

    items = []
    for i, ph in enumerate(phases):
        time = esc(ph.get('time', ''))
        heading = esc(ph.get('heading', f'阶段 {i + 1}'))
        text = ph.get('text', '')
        t = ph.get('type')
        color = type_colors.get(t) or ph.get('color') or 'var(--primary)'
        type_html = (f'<span class="timeline-type" style="color:{esc(color)};'
                     f'border-color:{_hex_rgba(color, 0.45)};background:{_hex_rgba(color, 0.1)}">{esc(t)}</span>'
                     if t else '')
        status = ph.get('status')
        status_color = ph.get('status_color')
        if status and not status_color:
            status_color = STATUS_COLOR.get(status)
        status_html = (f'<span class="timeline-status" style="color:{esc(status_color)}">● {esc(status)}</span>'
                       if status else '')
        text_html = f'    <p class="report-para">{esc(text)}</p>' if text else ''
        blocks_html = render_blocks(spec, ph.get('blocks', []))
        if blocks_html:
            blocks_html = '    ' + blocks_html.replace('\n', '\n    ')
        items.append(f'''  <div class="timeline-item">
    <div class="timeline-marker" style="border-color:{esc(color)}"></div>
    <div class="timeline-card">
      <div class="timeline-head">
        <span class="timeline-time"><i class="far fa-clock"></i> {time}</span>
        <h3 class="timeline-heading">{heading}</h3>
        {type_html}
        {status_html}
      </div>
{text_html}
{blocks_html}
    </div>
  </div>''')
    return '\n\n'.join([
        render_header(spec, True),
        render_kpis(spec),
        '<div class="timeline">\n' + legend_html + '\n'.join(items) + '\n</div>',
        render_footer(spec),
    ])


def render_body(spec, style):
    """按 style 选布局：网格布局走现有渲染器；report/timeline 走新渲染器。"""
    if style in REPORT_STYLES:
        return render_report(spec)
    if style == 'timeline':
        return render_timeline(spec)
    return '\n\n'.join([
        render_header(spec, True),
        render_kpis(spec),
        render_rows(spec),
        render_footer(spec),
    ])


def _hex_rgba(hexstr, alpha):
    hexstr = hexstr.lstrip('#')
    r = int(hexstr[0:2], 16)
    g = int(hexstr[2:4], 16)
    b = int(hexstr[4:6], 16)
    return f'rgba({r},{g},{b},{alpha})'


def theme_override(spec):
    theme = spec.get('theme', {})
    if not theme:
        return ''
    lines = []
    for k, v in theme.items():
        lines.append(f'  {CSS_VAR_MAP[k]}: {v};')
    primary = theme.get('primary')
    if primary:
        lines.append(f'  --primary-soft: {_hex_rgba(primary, 0.08)};')
        lines.append(f'  --border: {_hex_rgba(primary, 0.12)};')
        lines.append(f'  --border-strong: {_hex_rgba(primary, 0.3)};')
    vars_ = '\n'.join(lines)
    custom_css = spec.get('custom_css', '')
    return f'<style>\n:root {{\n{vars_}\n}}\n{custom_css}\n</style>'


def safe_js_embed(obj):
    s = json.dumps(obj, ensure_ascii=False)
    s = s.replace('</', '<\\/').replace('<!--', '<\\!--')
    return s


def render_runtime_boot(lib_base):
    """App Worker 运行时模式的页面引导脚本：
    1) fetch <base>/svc/spec 拿 spec → 设置 window.DASHBOARD_SPEC → 动态加载 dashboard.js；
    2) 订阅 <base>/svc/events（SSE），收到 data/spec 事件后重拉 spec 并重渲染（无刷新实时更新）。
    base 由页面 URL（/app/<port>/）计算，保证相对路径在数据面路由下正确。"""
    return f'''<script>
(function () {{
  'use strict';
  var LIB = {json.dumps(lib_base)};
  var BASE = (function () {{
    var m = location.pathname.match(/^(\\/app\\/[0-9]+)(\\/|$)/);
    return m ? m[1] + '/' : '';
  }})();
  function applySpec(d) {{
    if (d && d.spec) window.DASHBOARD_SPEC = d.spec;
    if (window.DashboardRender) window.DashboardRender();
  }}
  function onEvent() {{
    fetch(BASE + 'svc/spec', {{ cache: 'no-store' }})
      .then(function (r) {{ if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); }})
      .then(applySpec)
      .catch(function (e) {{ console.warn('[dashboard] spec 刷新失败（保持当前视图）', e); }});
  }}
  function boot() {{
    var s = document.createElement('script');
    s.src = BASE + LIB + 'dashboard/dashboard.js';
    s.onload = function () {{
      try {{
        var es = new EventSource(BASE + 'svc/events');
        es.addEventListener('spec', onEvent);
        es.onerror = function () {{ /* EventSource 自动重连 */ }};
      }} catch (_) {{}}
    }};
    document.body.appendChild(s);
  }}
  fetch(BASE + 'svc/spec', {{ cache: 'no-store' }})
    .then(function (r) {{ if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); }})
    .then(function (d) {{ if (d && d.spec) window.DASHBOARD_SPEC = d.spec; boot(); }})
    .catch(function (e) {{ console.warn('[dashboard] spec 加载失败，按空 spec 启动', e); boot(); }});
  setInterval(onEvent, 30000); // 轮询兜底（SSE 断线时保证不白屏）
}})();
</script>'''


def render(spec):
    title = esc(spec['title'])
    refresh = ''
    if spec.get('refresh'):
        refresh = f'<meta http-equiv="refresh" content="{int(spec["refresh"])}">'

    # 从注入给客户端的 spec 中剥离原始 js（由下方单独注入），并打标记供渲染器/校验器跳过
    client_spec = json.loads(json.dumps(spec))
    for cs in client_spec.get('charts', []):
        if 'js' in cs:
            cs['js_embedded'] = True
            cs.pop('js', None)
    spec_embed = safe_js_embed(client_spec)
    runtime = os.environ.get('RUNTIME_SPEC') == '1'

    style = spec.get('style', 'command')
    preset_css = f'<link rel="stylesheet" href="{LIB_BASE}dashboard/presets/{style}.css">' if style != 'command' else ''

    if runtime:
        spec_block = render_runtime_boot(LIB_BASE)
    else:
        spec_block = f'<script>\nwindow.DASHBOARD_SPEC = {spec_embed};\n</script>'

    # 原始 JS 块（type=echarts + js）
    js_blocks = []
    for cs in spec['charts']:
        if cs.get('js'):
            raw_js = cs['js'].replace('</script', '<\\/script').replace('<!--', '<\\!--')
            js_blocks.append(f'''<script>
(function () {{
  'use strict';
  var dom = document.getElementById({json.dumps(cs['id'])});
  if (!dom) return;
  try {{
{raw_js}
  }} catch (e) {{
    console.error({json.dumps('[dashboard] 图表渲染失败(' + cs['id'] + '):')}, e);
    dom.innerHTML = '<div style="color:#ff6b6b;text-align:center;padding:40px">图表渲染失败，请查看控制台</div>';
  }}
}})();
</script>''')

    dash_js = '' if runtime else f'<script src="{LIB_BASE}dashboard/dashboard.js"></script>'

    return f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title}</title>
{refresh}
<link rel="stylesheet" href="{LIB_BASE}fontawesome/css/all.min.css">
<link rel="stylesheet" href="{LIB_BASE}dashboard/dashboard.css">
{preset_css}
{theme_override(spec)}
</head>
<body data-preset="{esc(style)}">

{render_body(spec, style)}

<script src="{LIB_BASE}echarts/echarts.min.js"></script>
<script src="{LIB_BASE}echarts-maps/world.js"></script>
<script src="{LIB_BASE}dashboard/chart-builders.js"></script>
<script src="{LIB_BASE}dashboard/table-tools.js"></script>
<script src="{LIB_BASE}dashboard/interactive.js"></script>
{spec_block}
{dash_js}
{''.join(js_blocks)}
</body>
</html>'''


def main():
    if len(sys.argv) < 2:
        print('用法: python scripts/build_dashboard.py <spec.json>')
        sys.exit(1)
    path = sys.argv[1]
    if not os.path.exists(path):
        print(f'[ERROR] 文件不存在: {path}')
        sys.exit(1)
    try:
        with open(path, 'r', encoding='utf-8') as f:
            spec = json.load(f)
    except json.JSONDecodeError as e:
        print(f'[ERROR] spec JSON 解析失败: 行 {e.lineno} 列 {e.colno}: {e.msg}')
        sys.exit(1)
    except Exception as e:
        print(f'[ERROR] 读取失败: {e}')
        sys.exit(1)

    validate_schema(spec)
    validate(spec)

    data_errs = check_chart_data(spec)
    if data_errs:
        for e in data_errs:
            print(f'[ERROR] {e}')
        sys.exit(1)

    runtime = os.environ.get('RUNTIME_SPEC') == '1'
    out_name = spec['name'] + '.html'
    out_base = os.environ.get('OUT_BASE')
    if out_base:
        out_dir = os.path.normpath(out_base)
    else:
        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'html')
    out_path = os.path.normpath(os.path.join(out_dir, out_name))
    html_str = render(spec)

    os.makedirs(out_dir, exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(html_str)

    if runtime:
        # 侧车 spec：App Worker 流程用它 POST /svc/spec 入库（页面运行时 fetch 渲染）
        client_spec = json.loads(json.dumps(spec))
        for cs in client_spec.get('charts', []):
            if 'js' in cs:
                cs['js_embedded'] = True
                cs.pop('js', None)
        spec_path = os.path.normpath(os.path.join(out_dir, spec['name'] + '.spec.json'))
        with open(spec_path, 'w', encoding='utf-8') as f:
            json.dump(client_spec, f, ensure_ascii=False)

    lines = html_str.count('\n') + 1
    log.info(f'构建成功 {out_path} lines={lines} bytes={len(html_str.encode("utf-8"))}')
    print(f'OK {out_path} ({lines} 行, {len(html_str.encode("utf-8"))} bytes)')
    if runtime:
        print(f'SPEC {spec_path} （App Worker 流程：发布后 POST /svc/spec 入库，页面运行时拉取渲染）')


if __name__ == '__main__':
    main()
