/* ============================================================
   interactive.js — 大屏浏览器交互装配层（表格搜索/排序/分页/导出、Tabs、live 轮询）
   UMD：浏览器挂 window.DashboardInteractive；Node 下可 require（供行为校验，无 DOM 时惰性）
   渐进增强：任一功能 JS 失败不影响其余，静态内容始终可用
   表格 formatter 单源：只操作 DOM 节点（排序/过滤/分页移动 <tr>），不重新渲染 formatter
   幂等：dashboard.js 重渲染（spec 更新）后重复 init 不会重复绑定监听；
        表格行重建后自动按当前 state 重新应用排序/分页。
   ============================================================ */
(function (root, factory) {
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = factory();
  } else {
    (typeof window !== 'undefined' ? window : globalThis).DashboardInteractive = factory();
  }
})(this, function () {
  'use strict';

  var T = (typeof module !== 'undefined' && module.exports)
    ? require('./table-tools.js')
    : (typeof window !== 'undefined' ? (window.DashboardTableTools || null) : null);

  function hasDOM() { return typeof document !== 'undefined' && document.querySelectorAll; }

  /* ---------- 表格交互（排序/过滤/分页/导出） ---------- */
  // 每张表一个 state；apply() 每次都从 tbody 重新读行，支撑重渲染后的增量更新
  var tableStates = {};

  function readRows(card) {
    var tbody = card.querySelector('tbody');
    return tbody ? Array.prototype.slice.call(tbody.querySelectorAll('tr')) : [];
  }

  function cellText(tr, i) {
    var td = tr.children[i];
    return td ? (td.getAttribute('data-sort') || td.textContent || '') : '';
  }

  function matchesQuery(tr, query) {
    var q = query.toLowerCase();
    if (!q) return true;
    return Array.prototype.some.call(tr.children, function (td) {
      var t = td.getAttribute('data-sort') || td.textContent || '';
      return t.toLowerCase().indexOf(q) !== -1;
    });
  }

  function apply(card, state) {
    var table = card.querySelector('table');
    if (!table) return;
    var tbody = table.querySelector('tbody');
    if (!tbody) return;
    var allRows = readRows(card);
    var filtered = allRows.filter(function (tr) { return matchesQuery(tr, state.query); });
    if (state.sortable && state.sortCol >= 0) {
      var d = state.sortDir === 'desc' ? -1 : 1;
      filtered.sort(function (a, b) {
        return T.compareCells(cellText(a, state.sortCol), cellText(b, state.sortCol)) * d;
      });
    }
    var pageSize = state.pageSize;
    var visible = pageSize ? T.paginate(filtered, state.page, pageSize).rows : filtered;
    // 按可见顺序重排 DOM 节点（appendChild 会从原位置移除并追加到末尾），使排序/分页真实反映在页面
    visible.forEach(function (tr) { tbody.appendChild(tr); });
    allRows.forEach(function (tr) {
      tr.style.display = visible.indexOf(tr) === -1 ? 'none' : '';
    });
    var info = card.querySelector('.page-info');
    if (info) {
      if (pageSize) {
        var p = T.paginate(filtered, state.page, pageSize);
        info.textContent = '第 ' + p.page + '/' + p.pages + ' 页 · 共 ' + p.total + ' 条';
      } else {
        info.textContent = '共 ' + filtered.length + ' 条';
      }
    }
    if (state.sortable) {
      Array.prototype.forEach.call(table.querySelectorAll('th[data-col]'), function (th) {
        var i = parseInt(th.getAttribute('data-col'), 10);
        th.classList.remove('sorted-asc', 'sorted-desc');
        if (i === state.sortCol) th.classList.add(state.sortDir === 'desc' ? 'sorted-desc' : 'sorted-asc');
      });
    }
  }

  function initTable(card) {
    var table = card.querySelector('table');
    if (!table) return;
    var tbody = table.querySelector('tbody');
    if (!tbody) return;

    var key = card.getAttribute('data-table-id') || '';
    var searchable = card.hasAttribute('data-searchable');
    var sortable = card.hasAttribute('data-sortable');
    var pageSize = parseInt(card.getAttribute('data-page-size') || '0', 10) || 0;

    var state = tableStates[key];
    if (state) {
      // 已初始化：spec 重渲染后只重新应用（行可能已重建）
      state.searchable = searchable;
      state.sortable = sortable;
      state.pageSize = pageSize;
      apply(card, state);
      return;
    }
    state = { query: '', sortCol: -1, sortDir: 'asc', page: 1, searchable: searchable, sortable: sortable, pageSize: pageSize };
    tableStates[key] = state;

    if (searchable) {
      var input = card.querySelector('.table-search');
      if (input) {
        input.addEventListener('input', function () { state.query = this.value; state.page = 1; apply(card, state); });
      }
    }
    if (sortable) {
      Array.prototype.forEach.call(table.querySelectorAll('th[data-col]'), function (th) {
        th.addEventListener('click', function () {
          var i = parseInt(th.getAttribute('data-col'), 10);
          if (state.sortCol === i) state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
          else { state.sortCol = i; state.sortDir = 'asc'; }
          apply(card, state);
        });
      });
    }
    if (pageSize) {
      var prev = card.querySelector('.page-prev'), next = card.querySelector('.page-next');
      if (prev) prev.addEventListener('click', function () { if (state.page > 1) { state.page--; apply(card, state); } });
      if (next) next.addEventListener('click', function () {
        var filtered = readRows(card).filter(function (tr) { return matchesQuery(tr, state.query); });
        var p = T.paginate(filtered, state.page + 1, pageSize);
        if (p.page !== state.page) { state.page = p.page; apply(card, state); }
      });
    }
    if (pageSize) apply(card, state); // 初始分页生效（隐藏超页行）
  }

  /* ---------- Tabs 切换 ---------- */
  var tabsBound = false;
  function initTabs() {
    var nav = document.querySelector('.tab-nav');
    if (!nav || tabsBound) return;
    tabsBound = true;
    var buttons = nav.querySelectorAll('.tab-btn');
    var panels = document.querySelectorAll('.tab-panel');

    function activate(id) {
      buttons.forEach(function (b) { b.classList.toggle('active', b.getAttribute('data-tab') === id); });
      panels.forEach(function (p) { p.classList.toggle('active', p.getAttribute('data-tab') === id); });
      if (location.hash !== '#tab-' + id) history.replaceState(null, '', '#tab-' + id);
      window.dispatchEvent(new Event('resize')); // 图表随显隐 resize
    }
    buttons.forEach(function (b) {
      b.addEventListener('click', function () { activate(b.getAttribute('data-tab')); });
    });
    var initId = (location.hash || '').replace(/^#tab-/, '');
    if (initId && Array.prototype.some.call(buttons, function (b) { return b.getAttribute('data-tab') === initId; })) {
      activate(initId);
    }
  }

  /* ---------- live 轮询（单例，防重渲染重复起定时器） ---------- */
  var liveTimer = null;
  function initLive(spec) {
    var live = spec && spec.live;
    if (!live || !live.endpoint) return;
    var interval = Math.max(5, parseInt(live.interval, 10) || 30) * 1000;
    // 页面挂在 /app/<port>/ 下：绝对 /svc/* endpoint 需补应用基址
    var BASE = (function () {
      var m = location.pathname.match(/^(\/app\/[0-9]+)(\/|$)/);
      return m ? m[1] + '/' : '';
    })();
    var endpoint = (live.endpoint.indexOf('/') === 0 && BASE)
      ? BASE + live.endpoint.replace(/^\//, '')
      : live.endpoint;

    function applyLive(data) {
      if (!data || typeof data !== 'object') return;
      if (data.time) {
        document.querySelectorAll('.header .time').forEach(function (el) { el.textContent = data.time; });
      }
      if (Array.isArray(data.kpis)) {
        data.kpis.forEach(function (k, i) {
          var card = document.querySelectorAll('.kpi-card')[i];
          if (!card || k == null) return;
          var v = (typeof k === 'object') ? k.value : k;
          var valEl = card.querySelector('.kpi-value');
          var subEl = card.querySelector('.kpi-sub');
          if (valEl && v != null) valEl.textContent = v;
          if (subEl && typeof k === 'object' && k.sub != null) subEl.textContent = k.sub;
        });
      }
      if (Array.isArray(data.charts)) {
        data.charts.forEach(function (u) {
          if (!u || !u.id || !root.DashboardBuilders) return;
          var dom = document.getElementById(u.id);
          if (!dom || !window.echarts) return;
          try {
            var cs = u.spec || { id: u.id, type: u.type || 'bar', data: u.data };
            var chart = window.echarts.getInstanceByDom(dom);
            var opt = root.DashboardBuilders.BUILDERS[cs.type] ? root.DashboardBuilders.BUILDERS[cs.type](cs) : (cs.option || {});
            (chart || window.echarts.init(dom, null, { renderer: 'canvas' })).setOption(opt, true);
          } catch (e) { console.warn('[dashboard] live 更新图表失败: ' + u.id, e); }
        });
      }
      if (Array.isArray(data.tables)) {
        data.tables.forEach(function (u) {
          if (!u || !u.id || !Array.isArray(u.rows)) return;
          var card = document.querySelector('[data-table-id="' + u.id + '"]');
          if (!card) return;
          var tbody = card.querySelector('tbody');
          if (!tbody) return;
          tbody.innerHTML = u.rows.map(function (r) {
            return '<tr>' + r.map(function (c) {
              var escTxt = String(c == null ? '' : c).replace(/&/g, '&amp;').replace(/</g, '&lt;');
              var escAttr = escTxt.replace(/"/g, '&quot;');
              return '<td data-sort="' + escAttr + '">' + escTxt + '</td>';
            }).join('') + '</tr>';
          }).join('');
          if (tableStates[u.id]) apply(card, tableStates[u.id]);
        });
      }
    }

    function poll() {
      try {
        fetch(endpoint, { cache: 'no-store' })
          .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
          .then(applyLive)
          .catch(function (e) { console.warn('[dashboard] live 轮询失败（保持快照）: ' + endpoint, e); });
      } catch (e) {
        // file:// 下 fetch 不可用 → 静默降级为静态快照
        console.warn('[dashboard] live 不可用（file:// 或离线），使用静态快照');
      }
    }
    if (liveTimer) clearInterval(liveTimer);
    liveTimer = setInterval(poll, interval);
  }

  /* ---------- 装配入口（幂等：表格按 state 复用，Tabs/live 全局单例） ---------- */
  function init(spec) {
    if (!hasDOM()) return;
    if (T) {
      document.querySelectorAll('.card[data-table-id]').forEach(initTable);
    }
    initTabs();
    initLive(spec);
  }

  return { init: init, initTable: initTable, initTabs: initTabs, initLive: initLive };
});
