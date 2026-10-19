'use strict';
/**
 * Canvas charts. Every chart is drawn from a spec the server supplied — this
 * file never decides what a number means, only how to draw it.
 *
 * Spec:
 *   {
 *     type: 'line' | 'bar' | 'stacked',
 *     labels: ['2026-10-01', ...],
 *     series: [{ name, unit, values: [..|null], axis: 'left'|'right',
 *                kind: 'line'|'bar', color }],
 *     thresholds: [{ value, label, color }],
 *     provisional: [bool, ...],
 *     unitLeft, unitRight
 *   }
 *
 * Null values are GAPS: the line breaks, the bar is absent, the tooltip says
 * "no data". Nothing is interpolated across a missing day, because a smooth
 * line through a hole is a fabricated measurement.
 */
(function () {
  const PASTEL = {
    int: '#60a5fa', out1: '#c7b9f5', out2: '#8fd3c7', deficit: '#7fc4a8',
    bad: '#f4a3a3', warn: '#f6d488', line: '#9db4d0', grid: '#e6ecf4',
    ink: '#334155', dim: '#94a3b8', prov: '#fdf3d7',
  };
  const AXIS_R = '#b48ad6';

  function setup(canvas) {
    const dpr = window.devicePixelRatio || 1;
    const W = canvas.clientWidth || 600;
    const H = canvas.clientHeight || 240;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    return { ctx, W, H };
  }

  function bounds(series, axis) {
    let min = Infinity;
    let max = -Infinity;
    for (const s of series) {
      if ((s.axis || 'left') !== axis) continue;
      for (const v of s.values) {
        if (v === null || v === undefined || !Number.isFinite(v)) continue;
        if (v < min) min = v;
        if (v > max) max = v;
      }
    }
    if (min === Infinity) return null;
    if (min === max) {
      min -= Math.abs(min * 0.1) || 1;
      max += Math.abs(max * 0.1) || 1;
    }
    return { min, max };
  }

  function stackedTotals(series, labels) {
    const totals = new Array(labels.length).fill(0);
    let any = false;
    for (const s of series) {
      if (s.kind === 'line') continue;
      s.values.forEach((v, i) => {
        if (v !== null && v !== undefined && Number.isFinite(v)) {
          totals[i] += v;
          any = true;
        }
      });
    }
    return any ? totals : null;
  }

  function fmt(v, digits) {
    if (v === null || v === undefined || !Number.isFinite(v)) return '—';
    const d = digits === undefined ? (Math.abs(v) >= 100 ? 0 : 1) : digits;
    return v.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
  }

  function tooltipFor(canvas) {
    const card = canvas.closest('.card') || canvas.parentElement;
    let tip = card.querySelector('.tip');
    if (!tip) {
      tip = document.createElement('div');
      tip.className = 'tip';
      tip.hidden = true;
      card.appendChild(tip);
    }
    return tip;
  }

  /**
   * Draw a spec onto a canvas and remember the geometry so pointer handlers can
   * hit-test it. Returns the state.
   */
  function render(canvas, spec) {
    const { ctx, W, H } = setup(canvas);
    const pad = { l: 52, r: 52, t: 14, b: 34 };
    const sw = W - pad.l - pad.r;
    const sh = H - pad.t - pad.b;
    const labels = spec.labels || [];
    const series = (spec.series || []).map((s) => ({
      ...s,
      axis: s.axis || 'left',
      kind: s.kind || (spec.type === 'bar' || spec.type === 'stacked' ? 'bar' : 'line'),
      values: s.values || [],
    }));
    if (!labels.length) {
      ctx.fillStyle = PASTEL.dim;
      ctx.font = '13px Inter, system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('no data in this range', W / 2, H / 2);
      canvas._chart = null;
      return null;
    }

    const stk = spec.type === 'stacked' ? stackedTotals(series, labels) : null;
    /* Include any left-axis line series in the scale even when bars are
       stacked: the target lines sit above the stack and would be clipped. */
    const leftSeries = stk
      ? [{ values: stk, axis: 'left' }, ...series.filter((s) => s.kind === 'line' && s.axis === 'left')]
      : series;
    const lb = bounds(leftSeries, 'left') || { min: 0, max: 1 };
    const leftMin = spec.yMin !== undefined ? spec.yMin : (lb.min < 0 ? lb.min * 1.1 : 0);
    const leftMax = spec.yMax !== undefined ? spec.yMax : lb.max * 1.1;
    const rb = bounds(series, 'right');
    const rightMin = rb ? (rb.min < 0 ? rb.min * 1.1 : 0) : 0;
    const rightMax = rb ? rb.max * 1.1 : 1;

    const xAt = (i) => pad.l + (labels.length === 1 ? sw / 2 : (sw * i) / (labels.length - 1));
    const yLeft = (v) => pad.t + sh * (1 - (v - leftMin) / (leftMax - leftMin || 1));
    const yRight = (v) => pad.t + sh * (1 - (v - rightMin) / (rightMax - rightMin || 1));

    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, W, H);

    /* Provisional days are shaded, so nothing reads as a settled number. */
    if (spec.provisional) {
      ctx.fillStyle = PASTEL.prov;
      spec.provisional.forEach((p, i) => {
        if (!p) return;
        const half = labels.length > 1 ? sw / (labels.length - 1) / 2 : sw / 2;
        ctx.fillRect(xAt(i) - half, pad.t, half * 2, sh);
      });
    }

    /* Grid + axes. */
    ctx.strokeStyle = PASTEL.grid;
    ctx.lineWidth = 1;
    ctx.fillStyle = PASTEL.dim;
    ctx.font = '10px JetBrains Mono, monospace';
    for (let i = 0; i <= 4; i += 1) {
      const y = pad.t + (sh * i) / 4;
      ctx.beginPath();
      ctx.moveTo(pad.l, y);
      ctx.lineTo(W - pad.r, y);
      ctx.stroke();
      ctx.textAlign = 'right';
      ctx.fillText(fmt(leftMin + ((leftMax - leftMin) * (4 - i)) / 4, 0), pad.l - 6, y + 3);
      if (rb) {
        ctx.textAlign = 'left';
        ctx.fillStyle = AXIS_R;
        ctx.fillText(fmt(rightMin + ((rightMax - rightMin) * (4 - i)) / 4, 0), W - pad.r + 6, y + 3);
        ctx.fillStyle = PASTEL.dim;
      }
    }

    /* Thresholds (targets, ceilings, the planned deficit). */
    for (const t of spec.thresholds || []) {
      const y = yLeft(t.value);
      if (y < pad.t - 2 || y > pad.t + sh + 2) continue;
      ctx.save();
      ctx.setLineDash([5, 4]);
      ctx.strokeStyle = t.color || '#8fd3c7';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(pad.l, y);
      ctx.lineTo(W - pad.r, y);
      ctx.stroke();
      /* Label on a light chip: a threshold line crosses the bars, and plain
         text disappears into them (the planned-deficit line sat behind a bar). */
      ctx.font = '10px JetBrains Mono, monospace';
      ctx.textAlign = 'left';
      const tw = ctx.measureText(t.label).width;
      ctx.setLineDash([]);
      ctx.fillStyle = 'rgba(255,255,255,0.86)';
      ctx.fillRect(pad.l + 2, y - 14, tw + 6, 12);
      ctx.fillStyle = t.color || '#5da58f';
      ctx.fillText(t.label, pad.l + 5, y - 4);
      ctx.restore();
    }

    /* Zero line, when the series crosses it. */
    if (leftMin < 0 && leftMax > 0) {
      ctx.strokeStyle = '#cbd5e1';
      ctx.beginPath();
      ctx.moveTo(pad.l, yLeft(0));
      ctx.lineTo(W - pad.r, yLeft(0));
      ctx.stroke();
    }

    /* Bars: grouped, or stacked in series order. */
    const barSeries = series.filter((s) => s.kind === 'bar');
    if (barSeries.length) {
      const slot = labels.length > 1 ? sw / (labels.length - 1) : sw;
      const groupW = Math.min(slot * 0.62, 26);
      const barW = groupW / barSeries.length;
      labels.forEach((_, i) => {
        if (spec.type === 'stacked') {
          /* Segments ACCUMULATE: each sits on the running total, so its own
             value gives its height. Positioning each segment by its own value
             (the earlier bug) put a small segment's top BELOW a larger one's
             base, and the negative-height rect painted over the segment
             underneath — which is how protein disappeared on days where fat
             was small. Verified by sampling pixels in the bar column. */
          let cum = 0;
          barSeries.forEach((s) => {
            const v = s.values[i];
            if (v === null || v === undefined || !Number.isFinite(v)) return;
            const yTop = yLeft(cum + v);
            const yBase = yLeft(cum);
            ctx.fillStyle = s.color || PASTEL.line;
            ctx.globalAlpha = 0.78;
            ctx.fillRect(xAt(i) - groupW / 2, yTop, groupW, Math.max(1, yBase - yTop));
            ctx.globalAlpha = 1;
            cum += v;
          });
          return;
        }
        /* Grouped bars. Drawn from the zero line when the scale crosses it, so
           a negative bar (a surplus day) hangs below rather than above. */
        const base = leftMin < 0 && leftMax > 0 ? yLeft(0) : pad.t + sh;
        barSeries.forEach((s, si) => {
          const v = s.values[i];
          if (v === null || v === undefined || !Number.isFinite(v)) return;
          const y = yLeft(v);
          const top = Math.min(y, base);
          const h = Math.max(1, Math.abs(base - y));
          ctx.fillStyle = s.color || PASTEL.line;
          ctx.globalAlpha = 0.78;
          ctx.fillRect(xAt(i) - groupW / 2 + si * barW, top, barW, h);
          ctx.globalAlpha = 1;
        });
      });
    }

    /* Lines. */
    for (const s of series) {
      if (s.kind !== 'line') continue;
      const yFn = s.axis === 'right' ? yRight : yLeft;
      const color = s.color || (s.axis === 'right' ? AXIS_R : PASTEL.int);
      ctx.save();
      /* Dashed = a reference (a target or ceiling); solid = measured. */
      if (s.dashed) ctx.setLineDash([7, 5]);
      ctx.strokeStyle = color;
      ctx.lineWidth = s.dashed ? 1.5 : 2;
      ctx.beginPath();
      let pen = false;
      s.values.forEach((v, i) => {
        if (v === null || v === undefined || !Number.isFinite(v)) {
          pen = false; /* gap stays a gap */
          return;
        }
        const x = xAt(i);
        const y = yFn(v);
        if (!pen) {
          ctx.moveTo(x, y);
          pen = true;
        } else {
          ctx.lineTo(x, y);
        }
      });
      ctx.stroke();
      ctx.restore();
      if (s.dots !== false && !s.dashed && labels.length <= 62) {
        ctx.fillStyle = color;
        s.values.forEach((v, i) => {
          if (v === null || v === undefined || !Number.isFinite(v)) return;
          ctx.beginPath();
          ctx.arc(xAt(i), yFn(v), 2.6, 0, Math.PI * 2);
          ctx.fill();
        });
      }
    }

    /* X labels: first, middle, last — enough to orient without crowding. */
    ctx.fillStyle = PASTEL.dim;
    ctx.font = '10px JetBrains Mono, monospace';
    ctx.textAlign = 'center';
    const marks = labels.length > 2 ? [0, Math.floor((labels.length - 1) / 2), labels.length - 1] : [0];
    for (const i of marks) {
      ctx.fillText(String(labels[i]).slice(5), xAt(i), pad.t + sh + 16);
    }

    const state = {
      xAt, pad, sw, sh, W, H, labels, series, spec, stk,
      leftMin, leftMax, rightMin, rightMax, rb,
    };
    canvas._chart = state;
    return state;
  }

  /** Nearest label index for a pointer position. */
  function indexAt(state, px) {
    const { labels, pad, sw } = state;
    if (labels.length < 2) return 0;
    const rel = (px - pad.l) / (sw || 1);
    return Math.max(0, Math.min(labels.length - 1, Math.round(rel * (labels.length - 1))));
  }

  function attach(canvas) {
    const tip = tooltipFor(canvas);
    let dragging = false;
    let dragStart = null;

    canvas.addEventListener('mousemove', (ev) => {
      const st = canvas._chart;
      if (!st) return;
      const rect = canvas.getBoundingClientRect();
      const px = ev.clientX - rect.left;
      const i = indexAt(st, px);
      const rows = st.series
        .map((s) => `${s.name}: <b>${fmt(s.values[i])}</b>${s.unit ? ` ${s.unit}` : ''}`)
        .join('<br>');
      tip.innerHTML = `<div class="tip-date">${st.labels[i]}${st.spec.provisional && st.spec.provisional[i] ? ' · provisional' : ''}</div>${rows}`;
      tip.hidden = false;
      const cardW = (canvas.closest('.card') || canvas.parentElement).clientWidth;
      tip.style.left = `${Math.min(Math.max(px + 12, 8), Math.max(cardW - 160, 8))}px`;
      tip.style.top = `${Math.max(ev.clientY - rect.top - 10, 8)}px`;
      canvas.style.cursor = 'crosshair';
    });

    canvas.addEventListener('mouseleave', () => {
      tip.hidden = true;
      dragging = false;
      dragStart = null;
    });

    canvas.addEventListener('mousedown', (ev) => {
      const st = canvas._chart;
      if (!st) return;
      const rect = canvas.getBoundingClientRect();
      dragging = true;
      dragStart = indexAt(st, ev.clientX - rect.left);
    });

    canvas.addEventListener('mouseup', (ev) => {
      const st = canvas._chart;
      if (!st || !dragging || dragStart === null) return;
      dragging = false;
      const rect = canvas.getBoundingClientRect();
      const end = indexAt(st, ev.clientX - rect.left);
      if (Math.abs(end - dragStart) >= 2) {
        const lo = Math.min(dragStart, end);
        const hi = Math.max(dragStart, end);
        canvas.dispatchEvent(new CustomEvent('chart-zoom', {
          detail: { from: st.labels[lo], to: st.labels[hi] },
          bubbles: true,
        }));
      }
      dragStart = null;
    });
  }

  window.Charts = { render, attach, PASTEL, fmt };
})();
