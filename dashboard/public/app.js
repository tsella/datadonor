'use strict';
/**
 * Client. Owns URL state, fetches JSON, draws panels. It contains no data
 * constants and never invents a value: every number on screen came from
 * /api/*, and a missing value renders as an em dash or a gap.
 *
 * The range lives in the URL (?from=&to=&grain=&metric=), so any view is
 * shareable and reloadable, and a drag-zoom on a chart is just a navigation.
 */
(function () {
  const $ = (id) => document.getElementById(id);

  /* Panels are declared as metric keys — the same registry the API serves, so
     a new metric becomes plottable without touching this file. */
  const PANELS = [
    {
      id: 'c-energy', unit: 'kcal', type: 'stacked',
      series: [
        { key: 'out.basal', kind: 'bar', color: '#c7b9f5' },
        { key: 'out.active', kind: 'bar', color: '#8fd3c7' },
        { key: 'intake.kcal', kind: 'line', color: '#60a5fa' },
      ],
    },
    {
      id: 'c-balance', unit: 'kcal', type: 'bar',
      series: [{ key: 'deficit', kind: 'bar', color: '#7fc4a8' }],
      refs: [{ key: 'target.planned_deficit', label: 'plan', color: '#8fd3c7' }],
    },
    {
      id: 'c-macros', unit: 'g', type: 'stacked',
      /* Actuals stacked (carbs, protein, fat) with the day's own target for each
         drawn as a dashed line. The targets move day to day — carbs especially —
         so they are real series, not a single averaged threshold line. */
      series: [
        { key: 'intake.c', kind: 'bar', color: '#a9cdf5' },
        { key: 'intake.p', kind: 'bar', color: '#8fd3c7' },
        { key: 'intake.f', kind: 'bar', color: '#f6d488' },
        { key: 'target.c', kind: 'line', dashed: true, color: '#4b8fd0' },
        { key: 'target.p', kind: 'line', dashed: true, color: '#5da58f' },
        { key: 'target.f', kind: 'line', dashed: true, color: '#d9a83c' },
      ],
    },
    {
      id: 'c-weight', unit: 'kg', type: 'line',
      series: [
        { key: 'weight.kg', kind: 'line', color: '#60a5fa' },
        { key: 'weight.avg7', kind: 'line', color: '#b48ad6' },
      ],
    },
    {
      id: 'c-recovery', unit: 'bpm / ms', type: 'line',
      series: [
        { key: 'rhr', kind: 'line', color: '#f4a3a3' },
        { key: 'hrv', kind: 'line', color: '#b48ad6', axis: 'right' },
      ],
    },
    {
      id: 'c-training', unit: 'kcal / min', type: 'bar',
      series: [
        { key: 'workout.kcal', kind: 'bar', color: '#f6d488' },
        { key: 'workout.minutes', kind: 'line', color: '#e0b45c', axis: 'right' },
      ],
    },
  ];

  const state = { from: null, to: null, grain: 'day', custom: [], meta: null };

  function readUrl() {
    const p = new URLSearchParams(window.location.search);
    state.from = p.get('from');
    state.to = p.get('to');
    state.grain = p.get('grain') === 'week' ? 'week' : 'day';
    state.custom = (p.get('metric') || '').split(',').map((s) => s.trim()).filter(Boolean);
  }

  function writeUrl() {
    const p = new URLSearchParams();
    p.set('from', state.from);
    p.set('to', state.to);
    if (state.grain !== 'day') p.set('grain', state.grain);
    if (state.custom.length) p.set('metric', state.custom.join(','));
    window.history.replaceState({}, '', `${window.location.pathname}?${p.toString()}`);
  }

  async function json(url) {
    const res = await fetch(url, { headers: { Accept: 'application/json' } });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || body.ok === false) throw new Error(body.error || `HTTP ${res.status}`);
    return body;
  }

  function fmt(v, digits) {
    if (v === null || v === undefined || !Number.isFinite(Number(v))) return '—';
    const n = Number(v);
    const d = digits === undefined ? (Math.abs(n) >= 100 ? 0 : 1) : digits;
    return n.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
  }

  function setBanner(lines) {
    const el = $('banner');
    if (!lines.length) {
      el.hidden = true;
      el.innerHTML = '';
      return;
    }
    el.hidden = false;
    el.innerHTML = lines.map((l) => `<div>${l}</div>`).join('');
  }

  /* ── summary strip ─────────────────────────────────────────────────── */
  function renderSummary(s) {
    const cells = [
      ['Days', `${s.days_complete} complete${s.days_provisional ? ` · ${s.days_provisional} provisional` : ''}`],
      ['Mean intake', `${fmt(s.mean_intake_kcal)} / ${fmt(s.mean_target_kcal)} kcal`],
      ['Mean out', `${fmt(s.mean_out_kcal)} kcal`],
      ['Mean deficit', `${fmt(s.mean_deficit_kcal)} kcal`],
      ['Protein', `${fmt(s.mean_protein_g)} / ${fmt(s.mean_protein_target_g)} g`],
      ['Floor hit', `${s.protein_floor_days} / ${s.days_complete} d`],
      ['Fat', `${fmt(s.mean_fat_g)} / ${fmt(s.mean_fat_ceiling_g)} g · over on ${s.fat_over_days} d`],
      ['Weight', `${fmt(s.mean_weight_kg)} kg${s.weight_first_kg && s.weight_last_kg && s.weight_first_kg !== s.weight_last_kg ? ` (${fmt(s.weight_last_kg - s.weight_first_kg, 1)} in range)` : ''}`],
      ['Sessions', `${s.sessions || 0} · ${fmt(s.total_workout_kcal, 0)} kcal · ${fmt(s.total_workout_minutes, 0)} min`],
      ['Sleep', `${fmt(s.mean_sleep_h, 1)} h`],
      ['RHR / HRV', `${fmt(s.mean_rhr, 0)} bpm / ${fmt(s.mean_hrv, 0)} ms`],
      ['Best deficit', s.best_deficit_day ? `${s.best_deficit_day.date} · ${fmt(s.best_deficit_day.deficit)}` : '—'],
    ];
    $('summary').innerHTML = cells
      .map(([k, v]) => `<div class="cell"><span class="k">${k}</span><span class="v">${v}</span></div>`)
      .join('');
  }

  /* ── charts ────────────────────────────────────────────────────────── */
  async function renderPanel(def) {
    const canvas = $(def.id);
    if (!canvas) return;
    const keys = def.series.map((s) => s.key).concat((def.refs || []).map((r) => r.key));
    const url = `/api/series?metric=${keys.join(',')}&from=${state.from}&to=${state.to}&grain=${state.grain}`;
    let data;
    try {
      data = await json(url);
    } catch (err) {
      canvas._chart = null;
      const ctx = canvas.getContext('2d');
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      return;
    }
    const byKey = new Map(data.series.map((s) => [s.key, s]));
    const labels = (byKey.get(def.series[0].key) || { points: [] }).points.map((p) => p.key);
    const provisional = (byKey.get(def.series[0].key) || { points: [] }).points.map((p) => Boolean(p.provisional));
    const series = def.series.map((s) => {
      const src = byKey.get(s.key);
      return {
        name: src ? src.label : s.key,
        unit: src ? src.unit : '',
        kind: s.kind,
        axis: s.axis,
        dashed: Boolean(s.dashed),
        color: s.color,
        values: src ? src.points.map((p) => p.value) : [],
      };
    });
    const thresholds = (def.refs || []).map((r) => {
      const src = byKey.get(r.key);
      const vals = src ? src.points.map((p) => p.value).filter((v) => Number.isFinite(v)) : [];
      return vals.length ? { value: vals.reduce((a, b) => a + b, 0) / vals.length, label: r.label, color: r.color } : null;
    }).filter(Boolean);
    const unitEl = document.getElementById(def.id.replace('c-', 'u-'));
    if (unitEl) unitEl.textContent = def.unit;
    /* Legend from the drawn series: solid swatch = measured, dashed = target.
       Without it the three target lines are only distinguishable by hovering. */
    const card = canvas.closest('.card');
    if (card) {
      let legend = card.querySelector('.legend');
      if (!legend) {
        legend = document.createElement('div');
        legend.className = 'legend';
        card.insertBefore(legend, canvas);
      }
      legend.innerHTML = series
        .filter((s) => s.values.some((v) => v !== null))
        .map((s) => `<span class="lg"><i class="${s.kind === 'line' ? 'ln' : 'br'}${s.dashed ? ' dash' : ''}" style="--c:${s.color}"></i>${s.name}</span>`)
        .join('');
    }
    Charts.render(canvas, { type: def.type, labels, series, thresholds, provisional });
  }

  async function renderCustom() {
    const canvas = $('c-custom');
    if (!canvas) return;
    if (!state.custom.length) {
      canvas._chart = null;
      const ctx = canvas.getContext('2d');
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = Charts.PASTEL.dim;
      ctx.font = '13px Inter, system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('pick one or more metrics below', canvas.clientWidth / 2, 60);
      return;
    }
    const url = `/api/series?metric=${state.custom.join(',')}&from=${state.from}&to=${state.to}&grain=${state.grain}`;
    try {
      const data = await json(url);
      const labels = data.series[0] ? data.series[0].points.map((p) => p.key) : [];
      const provisional = data.series[0] ? data.series[0].points.map((p) => Boolean(p.provisional)) : [];
      const colors = ['#60a5fa', '#8fd3c7', '#f6d488', '#b48ad6', '#f4a3a3', '#7fc4a8', '#c7b9f5'];
      /* Metrics of different units get different axes rather than one scale. */
      const units = [...new Set(data.series.map((s) => s.unit))];
      const series = data.series.map((s, i) => ({
        name: s.label,
        unit: s.unit,
        kind: i === 0 || s.agg === 'sum' ? 'bar' : 'line',
        axis: units[0] === s.unit ? 'left' : 'right',
        color: colors[i % colors.length],
        values: s.points.map((p) => p.value),
      }));
      Charts.render(canvas, { type: 'bar', labels, series, provisional });
    } catch (err) {
      canvas._chart = null;
    }
  }

  function renderPicker() {
    const el = $('metric-picker');
    const groups = new Map();
    for (const m of state.meta.metrics) {
      if (!groups.has(m.group)) groups.set(m.group, []);
      groups.get(m.group).push(m);
    }
    el.innerHTML = [...groups.entries()].map(([g, items]) => `
      <div class="pick-group">
        <span class="pick-head">${g}</span>
        ${items.map((m) => `<label class="pick"><input type="checkbox" value="${m.key}"
           ${state.custom.includes(m.key) ? 'checked' : ''}><span>${m.label} <em>${m.unit}</em></span></label>`).join('')}
      </div>`).join('');
    el.querySelectorAll('input[type=checkbox]').forEach((box) => {
      box.addEventListener('change', () => {
        state.custom = [...el.querySelectorAll('input:checked')].map((b) => b.value);
        writeUrl();
        renderCustom();
      });
    });
  }

  async function refresh({ refetchMeta = false } = {}) {
    const status = $('status');
    status.textContent = 'loading…';
    const t0 = performance.now();
    try {
      if (refetchMeta || !state.meta) state.meta = await json('/api/meta');
      if (!state.from || !state.to) {
        const cov = state.meta.coverage.food;
        state.to = state.meta.today;
        state.from = cov && cov.first
          ? (cov.first > addDays(state.to, -29) ? cov.first : addDays(state.to, -29))
          : addDays(state.to, -29);
        writeUrl();
      }
      $('from').value = state.from;
      $('to').value = state.to;
      $('grain').value = state.grain;
      $('tz-label').textContent = `${state.meta.timezone} · UTC${state.meta.offset_hours >= 0 ? '+' : ''}${state.meta.offset_hours}`;

      const [summary] = await Promise.all([
        json(`/api/summary?from=${state.from}&to=${state.to}`),
        ...PANELS.map(renderPanel),
        renderCustom(),
      ]);
      renderSummary(summary);
      renderPicker();

      const banners = [];
      const q = state.meta.quality;
      if (q.lag_warning) {
        banners.push(`⚠️ Watch sync is ${Math.round(q.lag_minutes / 60 * 10) / 10} h behind (last sample ${q.last_energy_sample_at || '—'}). Today is provisional.`);
      }
      if (summary.days_provisional) {
        banners.push(`Shaded day(s) are provisional — excluded from every average above.`);
      }
      const cov = state.meta.coverage.food;
      if (cov && cov.first && state.from < cov.first) {
        banners.push(`Food data starts ${cov.first} (energy goes back to ${state.meta.coverage.energy.first}); days before that have energy but no intake.`);
      }
      setBanner(banners);

      status.textContent = `range ${state.from} → ${state.to} · grain ${state.grain} · ${Math.round(performance.now() - t0)} ms`;
    } catch (err) {
      setBanner([`⚠️ ${err.message}`]);
      status.textContent = `error: ${err.message}`;
    }
  }

  function addDays(iso, n) {
    const d = new Date(`${iso}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  }

  function wire() {
    document.querySelectorAll('.preset').forEach((btn) => {
      btn.addEventListener('click', () => {
        const days = Number(btn.dataset.days);
        state.to = state.meta ? state.meta.today : state.to;
        state.from = addDays(state.to, -(days - 1));
        writeUrl();
        refresh();
      });
    });
    $('apply').addEventListener('click', () => {
      const f = $('from').value;
      const t = $('to').value;
      if (f) state.from = f;
      if (t) state.to = t;
      state.grain = $('grain').value;
      writeUrl();
      refresh();
    });
    ['from', 'to'].forEach((id) => $(id).addEventListener('change', () => $('apply').click()));
    $('grain').addEventListener('change', () => $('apply').click());
    document.addEventListener('chart-zoom', (ev) => {
      state.from = ev.detail.from;
      state.to = ev.detail.to;
      writeUrl();
      refresh();
    });
    window.addEventListener('resize', () => {
      PANELS.forEach(renderPanel);
      renderCustom();
    });
    document.querySelectorAll('canvas').forEach(Charts.attach);
  }

  readUrl();
  wire();
  refresh({ refetchMeta: true });
})();
