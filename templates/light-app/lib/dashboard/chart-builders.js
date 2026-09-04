/* ============================================================
   chart-builders.js — 声明式 spec 图表构建（纯函数，无 DOM 依赖）
   UMD：浏览器挂 window.DashboardBuilders；Node 下可 require（供行为校验）
   与 dashboard.js 分离：构建逻辑唯一来源，浏览器与 node 校验共用同一份代码
   ============================================================ */
(function (root, factory) {
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = factory();
  } else {
    root.DashboardBuilders = factory();
  }
})(this, function () {
  'use strict';

  var DARK_TOOLTIP = {
    backgroundColor: 'rgba(10,14,23,0.95)',
    borderColor: 'rgba(0,255,136,0.2)',
    borderWidth: 1,
    textStyle: { color: '#c8d6e5', fontSize: 12 },
    extraCssText: 'border-radius:6px;box-shadow:0 4px 20px rgba(0,0,0,0.6)'
  };

  /* ---------- 覆盖圈坐标生成（Haversine 等距投影） ---------- */
  function generateCirclePoints(lat, lon, radiusKm, steps) {
    var pts = [];
    for (var a = 0; a < 360; a += 360 / steps) {
      var rad = a * Math.PI / 180;
      var dx = radiusKm * Math.cos(rad) / 111.32;
      var dy = radiusKm * Math.sin(rad) / (111.32 * Math.cos(lat * Math.PI / 180));
      pts.push([lon + dx, lat + dy]);
    }
    return pts;
  }

  /* ---------- 字段模板 → formatter 函数 ---------- */
  function makeFieldFormatter(fields) {
    return function (p) {
      var d = p.data || {};
      var h = '<div style="font-size:13px;font-weight:700;color:#e8f0f8">' +
              String(d.name == null ? '' : d.name).replace(/&/g, '&amp;').replace(/</g, '&lt;') +
              '</div>';
      fields.forEach(function (f) {
        var v = d.extra ? d.extra[f.field] : d[f.field];
        if (v === undefined || v === null || v === '') return;
        var sv = String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;');
        h += '<div style="color:#8a9aaa">' + f.label + ': <span style="color:#c8d6e5">' +
             sv + (f.suffix ? f.suffix : '') + '</span></div>';
      });
      return h;
    };
  }

  /* ---------- 数据形状归一化 ----------
     values 一维数字数组（单序列）或二维数字数组（多序列）；series 为显式多序列 */
  function normalizeSeries(d) {
    if (Array.isArray(d.values)) {
      if (!d.values.length) return [];
      if (Array.isArray(d.values[0])) return d.values;
      return [d.values];
    }
    if (Array.isArray(d.series)) return d.series;
    return [];
  }

  function isNumeric(v) { return typeof v === 'number' && isFinite(v); }

  /* bar/line 数据形状断言：非法即 throw（失败显性化）
     colors 语义：单序列 = 逐类别配色（长度须等于 categories），多序列 = 逐序列配色（长度须等于序列数） */
  function assertBarLine(d, seriesList, type) {
    if (!Array.isArray(d.categories) || !d.categories.length) {
      throw new Error('data.categories 必须是非空数组');
    }
    if (!seriesList.length) {
      throw new Error('data.values 必须是非空数组');
    }
    var n = seriesList.length;
    if (Array.isArray(d.legend) && d.legend.length !== n) {
      throw new Error('data.legend(' + d.legend.length + ') 与序列数(' + n + ')不一致');
    }
    if (n > 1 && Array.isArray(d.colors) && d.colors.length && d.colors.length !== n) {
      throw new Error('data.colors(' + d.colors.length + ') 与序列数(' + n + ')不一致');
    }
    if (n === 1 && type === 'bar' && Array.isArray(d.colors) && d.colors.length && d.colors.length !== d.categories.length) {
      throw new Error('单序列 bar 的 data.colors(' + d.colors.length + ') 与 categories(' + d.categories.length + ')不一致（单序列 colors 为逐柱配色）');
    }
    seriesList.forEach(function (vals, i) {
      if (!Array.isArray(vals) || !vals.length) {
        throw new Error('data.values[' + i + '] 序列为空');
      }
      vals.forEach(function (v, j) {
        if (!isNumeric(v)) {
          throw new Error('data.values[' + i + '][' + j + '] 非数字');
        }
      });
    });
  }

  /* ---------- 声明式图表构建 ---------- */

  function buildMapChart(cs) {
    var option = {
      tooltip: Object.assign({ trigger: 'item' }, DARK_TOOLTIP),
      geo: Object.assign({
        map: 'world', roam: true, label: { show: false }, silent: true, z: 0,
        itemStyle: { areaColor: 'rgba(0,180,200,0.04)', borderColor: 'rgba(0,180,200,0.12)', borderWidth: 0.6 },
        emphasis: { itemStyle: { areaColor: 'rgba(0,200,200,0.08)' }, label: { show: false } }
      }, cs.geo || {}),
      series: []
    };

    var legendData = [];
    var legendSeen = {};
    function legendAdd(nm, icon) {
      if (legendSeen[nm]) return;
      legendSeen[nm] = true;
      legendData.push({ name: nm, icon: icon });
    }
    var ICON_LINE = 'path://M2,14 L20,2 L22,5 L4,17 Z';
    var ICON_RING = 'path://M12,2A10,10 0,1 0,12,22A10,10 0,1 0,12,2ZM12,6A6,6 0,1 1,12,18A6,6 0,1 1,12,6Z';

    (cs.circles || []).forEach(function (c) {
      if (!c.center || c.center.length < 2 || !c.radiusKm) return;
      var nm = c.name || ('覆盖圈 ' + c.radiusKm + 'km');
      legendAdd(nm, ICON_RING);
      var pts = generateCirclePoints(c.center[1], c.center[0], c.radiusKm, c.steps || 64);
      option.series.push({
        name: nm,
        type: 'scatter', coordinateSystem: 'geo',
        symbol: 'circle', symbolSize: 2,
        itemStyle: { color: c.color || '#4488ff' },
        data: pts.map(function (p) {
          return { value: p, itemStyle: { color: c.fill || 'transparent', borderColor: c.color || '#4488ff', borderWidth: c.borderWidth || 1, borderType: c.borderType || 'dashed' } };
        }),
        z: 1, tooltip: { show: false }, hoverAnimation: false, silent: true
      });
    });

    (cs.lines || []).forEach(function (l) {
      if (!l.coords || l.coords.length < 2) return;
      var nm = l.name || '轨迹';
      legendAdd(nm, ICON_LINE);
      var col = l.color || 'rgba(0,255,136,0.4)';
      var lineSeries = {
        name: nm, type: 'lines', coordinateSystem: 'geo',
        lineStyle: { color: col, width: l.width || 1.5, opacity: l.opacity || 0.45, type: l.lineType || 'dashed', curveness: l.curveness || 0.2 },
        itemStyle: { color: col },
        data: [{ coords: l.coords, lineStyle: { color: col } }],
        z: 1, tooltip: { show: false }, silent: true
      };
      if (l.effect) {
        lineSeries.effect = {
          show: true,
          period: l.effect.period || 6,
          trailLength: l.effect.trailLength || 0.3,
          symbol: l.effect.symbol || 'circle',
          symbolSize: l.effect.symbolSize || 5
        };
      }
      option.series.push(lineSeries);
    });

    var cats = cs.categories || {};
    var groups = {};
    (cs.markers || []).forEach(function (m) {
      (groups[m.category] = groups[m.category] || []).push(m);
    });
    Object.keys(groups).forEach(function (ck) {
      var cat = cats[ck] || {};
      var nm = cat.legendName || ck;
      legendAdd(nm, cat.symbol || 'circle');
      var isEffect = !!cat.effect;
      var itemColor = cat.color || '#00cccc';
      var series = {
        name: nm,
        type: isEffect ? 'effectScatter' : 'scatter',
        coordinateSystem: 'geo',
        symbol: cat.symbol || 'circle',
        symbolSize: cat.size || (isEffect ? 14 : 10),
        itemStyle: { color: itemColor },
        data: groups[ck].map(function (m) {
          var d = {
            name: m.name, value: m.value,
            itemStyle: { color: itemColor, shadowBlur: cat.shadowBlur || (isEffect ? 12 : 0), shadowColor: cat.shadowColor || 'rgba(0,200,200,0.3)' }
          };
          if (cat.label) d.label = { show: true, formatter: '{b}', position: cat.labelPos || 'right', color: cat.labelColor || '#c8d6e5', fontSize: cat.labelFontSize || 10 };
          if (m.extra) d.extra = m.extra;
          return d;
        }),
        z: cat.z || 3
      };
      if (isEffect) series.rippleEffect = cat.ripple || { brushType: 'stroke', scale: 4, period: 4, color: itemColor };
      if (cat.tooltip) series.tooltip = { formatter: makeFieldFormatter(cat.tooltip) };
      option.series.push(series);
    });

    var legendOpt = {
      orient: 'vertical', right: 16, top: 16,
      textStyle: { color: '#8a9aaa', fontSize: 11 },
      itemWidth: 16, itemHeight: 16
    };
    if (cs.legend && cs.legend.length) {
      legendOpt.data = cs.legend.map(function (n) {
        var ic = 'circle';
        for (var i = 0; i < legendData.length; i++) {
          if (legendData[i].name === n) { ic = legendData[i].icon; break; }
        }
        return { name: n, icon: ic };
      });
    } else if (legendData.length) {
      legendOpt.data = legendData;
    }
    if (legendOpt.data) option.legend = legendOpt;
    return option;
  }

  /* bar/line 通用：支持单序列（一维 values，colors=逐柱配色）与多序列（二维 values/series，colors=逐序列配色） */
  function buildBarLine(cs, type) {
    var d = cs.data || {};
    var seriesList = normalizeSeries(d);
    assertBarLine(d, seriesList, type);
    var multi = seriesList.length > 1;
    var series = seriesList.map(function (vals, i) {
      var col = (Array.isArray(d.colors) && d.colors.length) ? d.colors[i] : d.color;
      var s = { type: type, data: vals };
      if (d.legend && d.legend[i]) s.name = d.legend[i];
      if (type === 'bar') {
        // 单序列默认柱宽占类目 50%；多序列不强制 barWidth，由 ECharts 按组自动分配（自动留组内间隙，避免并排柱重叠）
        if (!multi) s.barWidth = d.barWidth || '50%';
        else if (d.barWidth) s.barWidth = d.barWidth;
        if (d.barGap) s.barGap = d.barGap;
        s.showBackground = true;
        s.backgroundStyle = { color: 'rgba(255,255,255,0.03)' };
        if (!multi && Array.isArray(d.colors) && d.colors.length) {
          s.data = vals.map(function (v, j) {
            return { value: v, itemStyle: { color: d.colors[j % d.colors.length] || col, borderRadius: [4, 4, 0, 0] } };
          });
        } else if (col) {
          s.itemStyle = { color: col, borderRadius: [4, 4, 0, 0] };
        }
      } else {
        var lc = col || '#00ff88';
        s.smooth = true;
        s.symbolSize = 5;
        s.lineStyle = { color: lc, width: 2 };
        s.itemStyle = { color: lc };
        if (d.area) s.areaStyle = { color: toRgba(lc, 0.08) };
      }
      return s;
    });
    var grid = { left: 40, right: 16, top: 24, bottom: 36, containLabel: true };
    if (d.legend && d.legend.length) {
      // 有图例时给顶部图例让出空间，避免遮挡柱子/坐标轴
      grid.top = 48;
    } else if (type === 'bar') {
      // 柱状图顶部留白：柱子底部对齐，上方留出呼吸空间
      grid.top = 40;
    }
    if (d.grid && typeof d.grid === 'object') {
      grid = Object.assign(grid, d.grid);
    }
    var option = {
      tooltip: Object.assign({ trigger: 'axis', axisPointer: { type: type === 'bar' ? 'shadow' : 'line' } }, DARK_TOOLTIP),
      grid: grid,
      xAxis: { type: 'category', data: d.categories, boundaryGap: type !== 'line', axisLabel: { color: '#8a9aaa', fontSize: 9, rotate: d.rotate || 0, interval: 0 }, axisLine: { lineStyle: { color: 'rgba(0,255,136,0.1)' } }, axisTick: { show: false } },
      yAxis: { type: 'value', name: d.unit || '', nameTextStyle: { color: '#6a7a8a', fontSize: 10 }, axisLabel: { color: '#6a7a8a', fontSize: 10 }, splitLine: { lineStyle: { color: 'rgba(0,255,136,0.05)', type: 'dashed' } } },
      series: series
    };
    if (d.legend && d.legend.length) {
      option.legend = { data: d.legend, top: 0, right: 8, textStyle: { color: '#8a9aaa', fontSize: 11 }, icon: 'circle', itemWidth: 12, itemHeight: 12 };
    }
    return option;
  }

  function toRgba(hex, alpha) {
    if (/^#([0-9a-fA-F]{6})$/.test(hex)) {
      var h = hex.slice(1);
      var r = parseInt(h.slice(0, 2), 16), g = parseInt(h.slice(2, 4), 16), b = parseInt(h.slice(4, 6), 16);
      return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
    }
    return 'rgba(0,255,136,' + alpha + ')';
  }

  function buildBarChart(cs) {
    return buildBarLine(cs, 'bar');
  }

  function buildLineChart(cs) {
    return buildBarLine(cs, 'line');
  }

  function buildPieChart(cs) {
    var d = cs.data || {};
    var vals = d.values || [];
    if (!Array.isArray(vals) || !vals.length) {
      throw new Error('data.values 必须是非空数组');
    }
    vals.forEach(function (v, i) {
      if (!v || !isNumeric(v.value)) {
        throw new Error('data.values[' + i + '] 必须含数字 value');
      }
    });
    return {
      tooltip: Object.assign({ trigger: 'item', formatter: d.tooltip || '{b}: {c} ({d}%)' }, DARK_TOOLTIP),
      series: [{
        type: 'pie',
        radius: d.radius || ['30%', '60%'],
        center: d.center || ['50%', '55%'],
        avoidLabelOverlap: true,
        padAngle: d.padAngle || 0,
        itemStyle: { borderRadius: 4, borderColor: 'rgba(10,14,23,0.5)', borderWidth: 2 },
        label: { show: true, formatter: typeof d.label === 'string' ? d.label : '{b}\n{c}', color: '#c8d6e5', fontSize: 11, lineHeight: 16 },
        emphasis: { label: { fontSize: 13, fontWeight: 'bold' }, itemStyle: { shadowBlur: 10, shadowColor: 'rgba(0,0,0,0.5)' } },
        data: vals.map(function (v, i) {
          var it = { name: v.name, value: v.value };
          var col = (d.colors && d.colors[i]) || v.color;
          if (col) it.itemStyle = { color: col };
          return it;
        })
      }]
    };
  }

  function buildScatterChart(cs) {
    var d = cs.data || {};
    var vals = d.values || [];
    if (!Array.isArray(vals) || !vals.length) {
      throw new Error('data.values 必须是非空数组');
    }
    vals.forEach(function (v, i) {
      if (!Array.isArray(v) || v.length < 2 || !isNumeric(v[0]) || !isNumeric(v[1])) {
        throw new Error('data.values[' + i + '] 必须为 [x,y] 数字对');
      }
    });
    return {
      tooltip: Object.assign({ trigger: 'item' }, DARK_TOOLTIP),
      grid: { left: 40, right: 16, top: 24, bottom: 36, containLabel: true },
      xAxis: { type: 'value', name: d.xName || '', nameTextStyle: { color: '#6a7a8a', fontSize: 10 }, axisLabel: { color: '#8a9aaa', fontSize: 9 }, splitLine: { lineStyle: { color: 'rgba(255,255,255,0.05)' } } },
      yAxis: { type: 'value', name: d.yName || '', nameTextStyle: { color: '#6a7a8a', fontSize: 10 }, axisLabel: { color: '#8a9aaa', fontSize: 9 }, splitLine: { lineStyle: { color: 'rgba(255,255,255,0.05)' } } },
      series: [{ type: 'scatter', data: vals, symbolSize: d.symbolSize || 10, itemStyle: { color: d.color || '#00ff88' } }]
    };
  }

  function buildRadarChart(cs) {
    var d = cs.data || {};
    var cats = d.categories;
    var vals = d.values;
    if (!Array.isArray(cats) || !cats.length) {
      throw new Error('data.categories 必须是非空数组');
    }
    if (!Array.isArray(vals) || !vals.length) {
      throw new Error('data.values 必须是非空数组');
    }
    var is2d = Array.isArray(vals[0]);
    var seriesVals = is2d ? vals : [vals];
    var legend = Array.isArray(d.legend) ? d.legend : [];
    var colors = Array.isArray(d.colors) ? d.colors : [];
    var indicator = cats.map(function (c) {
      var it = { name: c };
      if (isNumeric(d.max)) it.max = d.max;
      return it;
    });
    var series = seriesVals.map(function (v, i) {
      if (!Array.isArray(v) || v.length !== cats.length || !v.every(isNumeric)) {
        throw new Error('data.values[' + i + '] 长度必须等于 categories 且全为数字');
      }
      var nm = legend[i] || ('序列' + (i + 1));
      var s = {
        name: nm,
        type: 'radar',
        symbol: 'circle',
        symbolSize: 4,
        lineStyle: { width: 2 },
        areaStyle: { opacity: 0.15 },
        data: [{ name: nm, value: v }]
      };
      if (colors[i]) s.itemStyle = { color: colors[i] };
      return s;
    });
    var option = {
      tooltip: Object.assign({ trigger: 'item' }, DARK_TOOLTIP),
      radar: {
        indicator: indicator,
        radius: '62%',
        center: ['50%', '54%'],
        splitNumber: 4,
        axisName: { color: '#8a9aaa', fontSize: 11 },
        splitLine: { lineStyle: { color: 'rgba(0,255,136,0.12)' } },
        splitArea: { areaStyle: { color: ['rgba(0,255,136,0.02)', 'rgba(0,255,136,0.06)'] } },
        axisLine: { lineStyle: { color: 'rgba(0,255,136,0.25)' } }
      }
    };
    if (legend.length) {
      var lpos = (d.legendPos && typeof d.legendPos === 'object') ? d.legendPos : {};
      option.legend = Object.assign(
        { data: legend, bottom: 0, textStyle: { color: '#8a9aaa', fontSize: 10 }, itemWidth: 12, itemHeight: 8 },
        lpos
      );
    }
    option.series = series;
    return option;
  }

  var BUILDERS = {
    map: buildMapChart,
    bar: buildBarChart,
    line: buildLineChart,
    pie: buildPieChart,
    scatter: buildScatterChart,
    radar: buildRadarChart
  };

  /* ---------- 行为校验：对"已构建的 ECharts option"做数据形状断言 ----------
     供浏览器（失败显性化）与 node 行为校验共用；是"空图/坏数据"的确定性判据 */
  function validateChartOption(type, option) {
    var errs = [];
    var series = (option && option.series) || [];
    if (!series.length) {
      errs.push('无 series');
    }
    series.forEach(function (s, i) {
      var data = s.data;
      if (!Array.isArray(data) || !data.length) {
        errs.push('series[' + i + '] 数据为空');
        return;
      }
      if (type === 'bar' || type === 'line') {
        data.forEach(function (it, j) {
          var ok = isNumeric(it)
              || (Array.isArray(it) && it.length === 2 && isNumeric(it[0]) && isNumeric(it[1]))
              || (it && typeof it === 'object' && isNumeric(it.value));
          if (!ok) {
            errs.push('series[' + i + '] 数据项[' + j + '] 需为数字 / {value} / [x,y]');
          }
        });
      } else if (type === 'pie') {
        data.forEach(function (it, j) {
          if (!it || !isNumeric(it.value)) {
            errs.push('series[' + i + '] 数据项[' + j + '] 缺少数字 value');
          }
        });
      } else if (type === 'scatter') {
        data.forEach(function (it, j) {
          if (!Array.isArray(it) || it.length < 2 || !isNumeric(it[0]) || !isNumeric(it[1])) {
            errs.push('series[' + i + '] 数据项[' + j + '] 需为 [x,y] 数字对');
          }
        });
      } else if (type === 'radar') {
        data.forEach(function (it, j) {
          if (!it || !Array.isArray(it.value) || !it.value.length) {
            errs.push('series[' + i + '] 数据项[' + j + '] 缺少数组 value');
          }
        });
      }
    });
    return errs;
  }

  return {
    DARK_TOOLTIP: DARK_TOOLTIP,
    generateCirclePoints: generateCirclePoints,
    makeFieldFormatter: makeFieldFormatter,
    normalizeSeries: normalizeSeries,
    buildMapChart: buildMapChart,
    buildBarChart: buildBarChart,
    buildLineChart: buildLineChart,
    buildPieChart: buildPieChart,
    buildScatterChart: buildScatterChart,
    buildRadarChart: buildRadarChart,
    validateChartOption: validateChartOption,
    BUILDERS: BUILDERS
  };
});
