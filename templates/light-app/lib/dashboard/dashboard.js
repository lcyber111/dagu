/* ============================================================
   dashboard.js — 浏览器渲染入口（声明式 spec → 页面）

   spec 来源两种模式：
     1) 存量静态页：window.DASHBOARD_SPEC 内联，脚本加载即渲染；
     2) App Worker 运行时页：页面 fetch /svc/spec 拿到 spec 后设置
        window.DASHBOARD_SPEC，再调用 window.DashboardRender()；
        收到 /svc/events（SSE）的 data/spec 事件后重拉 spec 并重渲染。

   用 window.DashboardBuilders（chart-builders.js）构建 ECharts option，
   声明式渲染：头部 + KPI + 图表 + 表格 + docs/cards + 图例。
   重渲染幂等：图表实例按 id 复用、表格 tbody 重建、交互装配防重复绑定。
   ============================================================ */
(function () {
  'use strict';
  var charts = {};        // chart id -> echarts 实例（重渲染复用）
  var resizeBound = {};   // chart id -> 已绑定 resize

  function escapeHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function renderError(dom, e) {
    if (!dom) return;
    dom.innerHTML = '<div class="chart-error">' +
      escapeHtml(String(e && e.message || e)) +
      '</div>';
  }

  /* ---------- 头部 ---------- */
  function renderHeader(spec) {
    if (spec.title) document.title = spec.title;
    var h1 = document.querySelector('.header h1 span');
    if (h1 && spec.title != null) h1.textContent = spec.title;
    var sub = document.querySelector('.header .subtitle');
    if (sub && spec.subtitle != null) sub.textContent = spec.subtitle;
    var time = document.querySelector('.header .time');
    if (time && spec.time != null) {
      time.innerHTML = '<i class="far fa-clock"></i> ' + escapeHtml(String(spec.time));
    }
  }

  /* ---------- KPI 计数动画 ---------- */
  function animateCount(el, target, dur) {
    dur = dur || 900;
    if (typeof target !== 'number' || isNaN(target)) {
      el.textContent = String(target == null ? '' : target);
      return;
    }
    var start = null;
    function step(ts) {
      if (!start) start = ts;
      var p = Math.min(1, (ts - start) / dur);
      var v = Math.round(target * (0.3 + 0.7 * p));
      el.textContent = v.toLocaleString();
      if (p < 1) requestAnimationFrame(step);
      else el.textContent = target.toLocaleString();
    }
    requestAnimationFrame(step);
  }

  function renderKpis(spec) {
    var kpis = spec.kpis || [];
    var row = document.querySelector('.kpi-row');
    if (!row) return;
    if (!kpis.length) {
      row.innerHTML = '';
      return;
    }
    row.className = kpis.length >= 6 ? 'kpi-row kpi-row-dense' : 'kpi-row';
    row.innerHTML = kpis.map(function (k) {
      var label = k.label || '';
      var color = k.color || 'var(--primary)';
      var v = k.value;
      var text, sub = k.sub, subCls = '';
      if (v && typeof v === 'object') {
        text = String(v.text == null ? '' : v.text);
        if (v.sub != null) sub = v.sub;
      } else {
        text = String(v == null ? '' : v);
      }
      if (sub == null || sub === '') subCls = '';
      else subCls = ' inline';
      var dataValue = /^[0-9]+(?:\.[0-9]+)?$/.test(text)
        ? ' data-value="' + text + '"' : '';
      var subHtml = sub ? '<div class="kpi-sub' + subCls + '">' + escapeHtml(sub) + '</div>' : '';
      return '<div class="kpi-card"' + dataValue + '>' +
        '<div class="kpi-label">' + escapeHtml(label) + '</div>' +
        '<div class="kpi-value" style="color:' + escapeHtml(color) + '">' + escapeHtml(text) + '</div>' +
        subHtml + '</div>';
    }).join('');
    row.querySelectorAll('.kpi-card[data-value]').forEach(function (card) {
      var target = parseFloat(card.getAttribute('data-value'));
      var valEl = card.querySelector('.kpi-value');
      if (valEl) animateCount(valEl, target, 300);
    });
  }

  /* ---------- ECharts 初始化 ---------- */
  function makeChart(id) {
    var dom = document.getElementById(id);
    if (!dom) return null;
    var chart = charts[id] || echarts.init(dom, null, { renderer: 'canvas' });
    charts[id] = chart;
    if (window.WORLD_GEOJSON && !echarts.getMap('world')) {
      echarts.registerMap('world', WORLD_GEOJSON);
    }
    if (!resizeBound[id]) {
      resizeBound[id] = true;
      window.addEventListener('resize', function () { chart.resize(); });
    }
    return chart;
  }

  function setOptionSafe(chart, option, id) {
    try {
      chart.clear();
      chart.setOption(option);
    } catch (e) {
      console.error('[dashboard] 图表渲染失败(' + id + '):', e);
      renderError(chart.getDom(), e);
    }
  }

  function renderCharts(spec) {
    var seen = {};
    (spec.charts || []).forEach(function (cs) {
      seen[cs.id] = true;
      if (cs.js || cs.js_embedded) return;  // 原始 JS 块由生成器单独注入
      var chart = makeChart(cs.id);
      if (!chart) return;

      var option = null;
      try {
        if (cs.type === 'echarts') {
          option = cs.option || {};
        } else if (window.DashboardBuilders && window.DashboardBuilders.BUILDERS[cs.type]) {
          option = window.DashboardBuilders.BUILDERS[cs.type](cs);
          var errs = (window.DashboardBuilders.validateChartOption &&
            window.DashboardBuilders.validateChartOption(cs.type, option)) || [];
          if (errs.length) {
            throw new Error('[dashboard] 图表数据异常: ' + errs.join('; '));
          }
        } else {
          throw new Error('[dashboard] 未知图表类型: ' + cs.type + ' (' + cs.id + ')');
        }
      } catch (e) {
        console.error('[dashboard] 图表构建失败(' + cs.id + '):', e);
        renderError(chart.getDom(), e);
        return;
      }
      setOptionSafe(chart, option, cs.id);
    });
    // 释放已被新 spec 移除的图表实例
    Object.keys(charts).forEach(function (id) {
      if (!seen[id]) {
        try { charts[id].dispose(); } catch (_) {}
        delete charts[id];
        delete resizeBound[id];
      }
    });
  }

  /* ---------- 表格（formatter 规则与 build_dashboard.py 保持一致） ---------- */
  function formatCell(raw, col, colFmt) {
    var val = escapeHtml(raw == null ? '' : raw);
    if (!colFmt || typeof colFmt !== 'object') return val;
    var tagMap = colFmt.tag;
    if (tagMap && typeof tagMap === 'object' && tagMap[raw] != null) {
      val = '<span class="tag ' + escapeHtml(tagMap[raw]) + '">' + val + '</span>';
    }
    var color = null;
    if (typeof colFmt.color === 'string') color = colFmt.color;
    else if (colFmt.color && typeof colFmt.color === 'object') color = colFmt.color[raw];
    if (color) {
      var weight = colFmt.weight ? ';font-weight:' + Number(colFmt.weight) : '';
      val = '<span style="color:' + escapeHtml(color) + weight + '">' + val + '</span>';
    }
    if (colFmt.bold) val = '<strong>' + val + '</strong>';
    var tc = colFmt.truncate;
    if (typeof tc === 'number') {
      val = '<span style="max-width:' + tc + 'px;display:inline-block;overflow:hidden;' +
        'text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom">' + val + '</span>';
    }
    return val;
  }

  function renderTables(spec) {
    var tables = spec.tables || [];
    tables.forEach(function (t) {
      var card = document.querySelector('[data-table-id="' + t.id + '"]');
      if (!card) return;
      card.style.display = '';
      var table = card.querySelector('table');
      if (!table) return;
      // 列头随 spec 重建（列变更后表头不过时）
      var thead = table.querySelector('thead');
      if (thead && t.columns) {
        var sortable = card.hasAttribute('data-sortable');
        thead.innerHTML = '<tr>' + (t.columns || []).map(function (col, i) {
          return '<th data-col="' + i + '"' + (sortable ? ' data-sortable' : '') + '>' +
            escapeHtml(col) + '</th>';
        }).join('') + '</tr>';
      }
      var tbody = card.querySelector('tbody');
      if (!tbody) return;
      var colFmt = t.formatters || {};
      tbody.innerHTML = (t.rows || []).map(function (row) {
        var tds = (t.columns || []).map(function (col, idx) {
          var raw = row[idx] != null ? row[idx] : '';
          return '<td data-sort="' + escapeHtml(raw) + '">' +
            formatCell(raw, col, colFmt[col]) + '</td>';
        }).join('');
        return '<tr>' + tds + '</tr>';
      }).join('');
    });
    // 新 spec 已移除的表格卡片隐藏，避免残留旧表
    document.querySelectorAll('[data-table-id]').forEach(function (card) {
      var tid = card.getAttribute('data-table-id');
      if (!tables.some(function (t) { return t.id === tid; })) {
        card.style.display = 'none';
      }
    });
  }

  /* ---------- docs 文本块 ---------- */
  function renderDocSection(d) {
    var title = d.title;
    var color = d.color || 'var(--primary)';
    var tag = d.tag;
    var text = d.text || '';
    var head = '';
    if (title) {
      var bar = '<span class="doc-sec-bar" style="background:' + escapeHtml(color) + '"></span>';
      var titleHtml = '<span class="doc-sec-title" style="color:' + escapeHtml(color) + '">' + escapeHtml(title) + '</span>';
      if (tag) {
        head = '<div class="doc-sec-head">\n  ' + bar + '\n  ' + titleHtml +
          '\n  <span class="doc-sec-tag">' + escapeHtml(tag) + '</span>\n</div>\n';
      } else {
        head = '<div class="doc-sec-head">\n  ' + bar + '\n  ' + titleHtml + '\n</div>\n';
      }
    }
    return '<div class="doc-section">\n' + head + '<p class="doc-sec-body">' + escapeHtml(text) + '</p>\n</div>';
  }

  function renderDocsCells(spec) {
    var seen = {};
    (spec.rows || []).forEach(function (row, ri) {
      (row.cells || []).forEach(function (cell, ci) {
        if (!cell.docs) return;
        seen[ri + '-' + ci] = true;
        var card = document.querySelector('[data-docs-cell="' + ri + '-' + ci + '"]');
        if (!card) return;
        card.style.display = '';
        var head = card.querySelector('.card-header');
        var body = card.querySelector('.card-body');
        if (body) body.innerHTML = cell.docs.map(renderDocSection).join('\n');
        if (head) {
          var h3 = head.querySelector('h3');
          if (h3) h3.textContent = cell.title || '';
        }
      });
    });
    document.querySelectorAll('[data-docs-cell]').forEach(function (card) {
      if (!seen[card.getAttribute('data-docs-cell')]) card.style.display = 'none';
    });
  }

  /* ---------- cards 实体卡 ---------- */
  function renderEntityCard(item, horizontal) {
    var color = item.color || 'var(--primary)';
    var eid = escapeHtml(item.id || '');
    var role = escapeHtml(item.role || '');
    var photo = item.photo || {};
    var src = photo.src;
    var note = photo.note;
    var photoHtml;
    if (src) {
      photoHtml = '<img class="entity-photo-img" src="' + escapeHtml(src) + '" alt="" ' +
        'onerror="this.style.display=\'none\';this.nextElementSibling.style.display=\'flex\'">\n' +
        '<p class="entity-photo-placeholder" style="display:none"><i class="fas fa-image"></i><span>本地照片缺失</span></p>';
    } else {
      photoHtml = '<p class="entity-photo-placeholder"><i class="fas fa-image"></i><span>本地照片缺失</span></p>';
    }
    var noteHtml = note ? '\n<span class="entity-photo-note">' + escapeHtml(note) + '</span>' : '';
    var metaRows = (item.meta || []).map(function (row) {
      var label = escapeHtml(row[0]);
      var v = escapeHtml(row[1]);
      if (row.length > 2 && row[2]) v = '<b style="color:' + escapeHtml(row[2]) + '">' + v + '</b>';
      return '<div><span>' + label + '</span>' + v + '</div>';
    }).join('\n');
    if (horizontal) {
      return '<div class="entity-card entity-card-h" style="border-color:' + escapeHtml(color) + '">' +
        '<div class="entity-photo entity-photo-h">' + photoHtml + '</div>' +
        '<div class="entity-card-h-right">' +
        '<div class="entity-head"><span class="entity-id" style="color:' + escapeHtml(color) + '">' + eid +
        '</span><span class="entity-role">' + role + '</span></div>' + noteHtml +
        '<div class="entity-meta">\n' + metaRows + '\n</div>' +
        '</div></div>';
    }
    return '<div class="entity-card" style="border-color:' + escapeHtml(color) + '">' +
      '<div class="entity-head"><span class="entity-id" style="color:' + escapeHtml(color) + '">' + eid +
      '</span><span class="entity-role">' + role + '</span></div>' +
      '<div class="entity-photo">' + photoHtml + '</div>' + noteHtml +
      '<div class="entity-meta">\n' + metaRows + '\n</div>' +
      '</div>';
  }

  function renderCardsCells(spec) {
    var seen = {};
    (spec.rows || []).forEach(function (row, ri) {
      (row.cells || []).forEach(function (cell, ci) {
        if (!cell.cards) return;
        seen[ri + '-' + ci] = true;
        var card = document.querySelector('[data-cards-cell="' + ri + '-' + ci + '"]');
        if (!card) return;
        card.style.display = '';
        var body = card.querySelector('.card-body');
        if (!body) return;
        var c = cell.cards;
        var horizontal = c.layout === 'horizontal';
        var cls = horizontal ? 'cards cards-h' : 'cards';
        body.innerHTML = '<div class="' + cls + '">\n' +
          (c.items || []).map(function (it) { return renderEntityCard(it, horizontal); }).join('\n') +
          '\n</div>';
        var head = card.querySelector('.card-header h3');
        if (head) head.textContent = c.title || '';
      });
    });
    document.querySelectorAll('[data-cards-cell]').forEach(function (card) {
      if (!seen[card.getAttribute('data-cards-cell')]) card.style.display = 'none';
    });
  }

  /* ---------- footer ---------- */
  function renderFooter(spec) {
    var ft = document.querySelector('.footer div');
    if (!ft) return;
    var parts = (spec.footer || []).map(function (it) {
      return '<span class="ft-item"><span class="label">' + escapeHtml(it.label || '') + ':</span> ' +
        escapeHtml(it.value || '') + '</span>';
    });
    if (spec.time) {
      parts.push('<span class="ft-item"><span class="label">分析时间:</span> ' + escapeHtml(String(spec.time)) + '</span>');
    }
    if (parts.length) ft.innerHTML = parts.join('\n    ');
  }

  /* ---------- 主渲染（幂等，可重复调用） ---------- */
  function renderDashboard() {
    var spec = window.DASHBOARD_SPEC;
    if (!spec) return;
    renderHeader(spec);
    renderKpis(spec);
    renderCharts(spec);
    renderTables(spec);
    renderDocsCells(spec);
    renderCardsCells(spec);
    renderFooter(spec);
    if (window.DashboardInteractive) {
      window.DashboardInteractive.init(spec);
    }
  }

  // 存量静态页兼容：spec 内联时加载即渲染
  if (window.DASHBOARD_SPEC) renderDashboard();
  // 运行时页：页面 fetch spec 后调用；此处再兜底一次（幂等）
  window.DashboardRender = renderDashboard;
})();
