/* ============================================================
   table-tools.js — 表格交互纯函数（搜索/排序/分页）
   UMD：浏览器挂 window.DashboardTableTools；Node 下可 require（供行为校验）
   原则：只操作"行数组"，不接触 DOM/formatter —— 装配层负责 DOM 交互
   与 chart-builders.js 同样：逻辑唯一来源，浏览器与 node 校验共用同一份代码
   ============================================================ */
(function (root, factory) {
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = factory();
  } else {
    root.DashboardTableTools = factory();
  }
})(this, function () {
  'use strict';

  /* 将单元格文本转可排序值：数字串→数字（支持千分位/百分比），其余→字符串 */
  function parseCell(v) {
    if (typeof v === 'number') return v;
    var s = String(v == null ? '' : v).trim();
    if (!s) return s;
    var n = Number(String(s).replace(/[,\s%]/g, ''));
    if (s !== '' && !isNaN(n) && /^-?\d+\.?\d*$/.test(s.replace(/[,\s%]/g, ''))) return n;
    return s;
  }

  function compareCells(a, b) {
    var av = parseCell(a), bv = parseCell(b);
    if (typeof av === 'number' && typeof bv === 'number') return av - bv;
    return String(av).localeCompare(String(bv), 'zh-CN');
  }

  /* rows: 二维数组；colIdx: 排序列；dir: 'asc' | 'desc'。返回新数组（不修改原数组） */
  function sortRows(rows, colIdx, dir) {
    var d = dir === 'desc' ? -1 : 1;
    return rows.slice().sort(function (a, b) {
      return compareCells(a[colIdx], b[colIdx]) * d;
    });
  }

  /* rows: 二维数组；query: 任意列子串匹配（大小写不敏感）。返回新数组 */
  function filterRows(rows, query) {
    var q = String(query == null ? '' : query).trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(function (r) {
      return r.some(function (c) {
        return String(c == null ? '' : c).toLowerCase().indexOf(q) !== -1;
      });
    });
  }

  /* 分页。返回 {rows, page, pages, total}；page 越界自动收敛到 [1, pages] */
  function paginate(rows, page, pageSize) {
    pageSize = pageSize > 0 ? pageSize : rows.length || 1;
    var total = rows.length;
    var pages = Math.max(1, Math.ceil(total / pageSize));
    page = Math.min(Math.max(1, page || 1), pages);
    return {
      rows: rows.slice((page - 1) * pageSize, page * pageSize),
      page: page, pages: pages, total: total
    };
  }

  return { parseCell: parseCell, compareCells: compareCells, sortRows: sortRows, filterRows: filterRows, paginate: paginate };
});
