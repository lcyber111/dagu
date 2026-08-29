#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""存量大屏 index.html 运行时化转换（SSE + /svc/spec）：

1) 提取 window.DASHBOARD_SPEC = {...}; 字面量 → 输出 <name>.spec.json 侧车文件
   （用于 POST /svc/spec 入库；页面不再写死 spec 常量）；
2) 用运行时引导脚本替换 spec 字面量：fetch /svc/spec 拿 spec →
   设置 window.DASHBOARD_SPEC → 动态加载 dashboard.js →
   订阅 /svc/events（SSE）收到 data/spec 事件后重拉 spec 并 DashboardRender()；
3) 移除静态 <script src=".../dashboard.js"></script>（改由引导脚本动态加载，避免双载）。

用法: python3 convert_runtime_html.py <index.html> [spec_out.json]
"""
import json
import re
import sys


BOOT_SCRIPT = r'''<script>
(function () {
  'use strict';
  // 页面挂在 /app/<port>/ 下：以页面 URL 计算应用基址，保证 svc/静态资源相对路径正确
  var BASE = (function () {
    var m = location.pathname.match(/^(\/app\/[0-9]+)(\/|$)/);
    return m ? m[1] + '/' : '';
  })();
  function applySpec(d) {
    if (d && d.spec) window.DASHBOARD_SPEC = d.spec;
    if (window.DashboardRender) window.DashboardRender();
  }
  function onEvent() {
    fetch(BASE + 'svc/spec', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(applySpec)
      .catch(function (e) { console.warn('[dashboard] spec 刷新失败（保持当前视图）', e); });
  }
  function boot() {
    var s = document.createElement('script');
    s.src = BASE + 'lib/dashboard/dashboard.js';
    s.onload = function () {
      try {
        var es = new EventSource(BASE + 'svc/events');
        es.addEventListener('spec', onEvent);
        es.onerror = function () { /* EventSource 自动重连 */ };
      } catch (_) {}
    };
    document.body.appendChild(s);
  }
  fetch(BASE + 'svc/spec', { cache: 'no-store' })
    .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
    .then(function (d) { if (d && d.spec) window.DASHBOARD_SPEC = d.spec; boot(); })
    .catch(function (e) { console.warn('[dashboard] spec 加载失败，按空 spec 启动', e); boot(); });
  setInterval(onEvent, 30000); // 轮询兜底（SSE 断线时保证不白屏）
})();
</script>'''


def extract_spec_literal(html):
    """返回 (spec_json_text, statement_start, script_close_end)；未找到返回 (None, None, None)。"""
    start = html.find('window.DASHBOARD_SPEC')
    if start < 0:
        return None, None, None
    eq = html.find('=', start)
    brace = html.find('{', eq)
    if brace < 0:
        return None, None, None
    # 花括号配对（识别字符串，兼容 \/ 等转义），取整段字面量
    depth = 0
    in_str = False
    esc = False
    i = brace
    while i < len(html):
        c = html[i]
        if in_str:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    end = html.find('</script>', i)
                    if end < 0:
                        return None, None, None
                    return html[brace:i + 1], start, end + len('</script>')
        i += 1
    return None, None, None


def main():
    if len(sys.argv) < 2:
        print('usage: python3 convert_runtime_html.py <index.html> [spec_out.json]')
        sys.exit(2)
    path = sys.argv[1]
    spec_out = sys.argv[2] if len(sys.argv) > 2 else None
    with open(path, 'r', encoding='utf-8') as f:
        html = f.read()

    spec_text, stmt_start, script_end = extract_spec_literal(html)
    if spec_text is None:
        print('ERROR: no window.DASHBOARD_SPEC literal found in', path)
        sys.exit(1)
    spec = json.loads(spec_text)  # 合法 JSON（含 \/ 转义，JSON 解析器自动还原）

    # 回退到包裹该字面量的 <script> 开标签，整块替换（避免残留 <script><script> 嵌套）
    script_open = html.rfind('<script', 0, stmt_start)
    if script_open < 0:
        print('ERROR: no <script> tag wrapping DASHBOARD_SPEC in', path)
        sys.exit(1)
    new_html = html[:script_open] + BOOT_SCRIPT + html[script_end:]
    # 移除静态 dashboard.js 标签（引导脚本动态加载，避免双载；兼容不同 LIB_BASE 前缀）
    new_html = re.sub(
        r'<script src="[^"]*dashboard/dashboard\.js"></script>\s*', '', new_html)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_html)
    if spec_out:
        with open(spec_out, 'w', encoding='utf-8') as f:
            json.dump(spec, f, ensure_ascii=False)
    print('OK', path,
          '| rows=%d charts=%d kpis=%d'
          % (len(spec.get('rows', [])), len(spec.get('charts', [])),
             len(spec.get('kpis', []))))


if __name__ == '__main__':
    main()
