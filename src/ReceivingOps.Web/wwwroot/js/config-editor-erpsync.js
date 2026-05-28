// Phase 13.6 — Sync Schedule tab renderer (dual-source).
//
// Shared keys (non-secret → PUT):
//   ErpSync:Enabled           bool       master kill-switch
//   ErpSync:CronExpression    string     5-field cron (NCrontab validated server-side)
//   ErpSync:TimeoutSeconds    int        60–3600
//
// Per-source keys (Bpi + Prb fieldsets — symmetric triplet):
//   ErpSync:Sources:<X>:Enabled              bool
//   ErpSync:Sources:<X>:BackfillDays         int   1–365
//   ErpSync:Sources:<X>:DefaultWarehouseId   Guid  <select> from /api/warehouses
//
// v3.1.2 cron-preset escape hatch preserved — the dropdown writes to a
// hidden #erpsync-CronExpression input that the save loop reads via [data-key].

(function () {
  const { api, showRestartBanner, setAlert, clearAlert } = window.__configEditor || {};
  if (!api) return;

  const SCHEDULE_PRESETS = [
    { label: 'Every 15 minutes',    cron: '*/15 * * * *' },
    { label: 'Every 30 minutes',    cron: '*/30 * * * *' },
    { label: 'Every hour (at :00)', cron: '0 * * * *' },
    { label: 'Every 2 hours',       cron: '0 */2 * * *' },
    { label: 'Every 4 hours',       cron: '0 */4 * * *' },
    { label: 'Every 6 hours',       cron: '0 */6 * * *' },
    { label: 'Every 12 hours',      cron: '0 */12 * * *' },
    { label: 'Daily at midnight',   cron: '0 0 * * *' },
    { label: 'Daily at 2 AM',       cron: '0 2 * * *' },
    { label: 'Daily at 8 AM',       cron: '0 8 * * *' },
  ];
  const CUSTOM = '__custom__';

  // Per-source fieldset config — adding a third source = appending one entry.
  const SOURCES = [
    {
      name: 'Bpi',
      label: 'BPI_PRS source',
      hint: 'Legacy ERP source (Phase 10). Enabled by default in v3.2 deployments.',
    },
    {
      name: 'Prb',
      label: 'PRB_PRS source',
      hint: 'Second ERP source (Phase 13). Disabled by default — opt in once schema + connectivity are confirmed.',
    },
  ];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g,
      c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  function renderSourceFieldset(src, v, whOptionsHtml) {
    const k = (suffix) => `ErpSync:Sources:${src.name}:${suffix}`;
    const enabledKey = k('Enabled');
    const backfillKey = k('BackfillDays');
    const whKey = k('DefaultWarehouseId');
    const id = (suffix) => `erpsync-${src.name}-${suffix}`;
    return `
      <fieldset class="config-source-fieldset" data-source="${src.name}">
        <legend>${esc(src.label)}</legend>
        <p class="config-hint">${esc(src.hint)}</p>
        <div class="form-grid">
          <div class="config-field">
            <label for="${id('Enabled')}">Enabled</label>
            <select id="${id('Enabled')}" data-key="${enabledKey}">
              <option value="true"${v[enabledKey] === 'true' ? ' selected' : ''}>Yes — include this source on each sync fire</option>
              <option value="false"${v[enabledKey] === 'false' ? ' selected' : ''}>No — skip this source</option>
            </select>
            <p class="config-hint">Per-source toggle. Independent of the master kill-switch.</p>
          </div>
          <div class="config-field">
            <label for="${id('BackfillDays')}">Backfill days</label>
            <input type="number" id="${id('BackfillDays')}" data-key="${backfillKey}"
              value="${esc(v[backfillKey])}" min="1" max="365">
            <p class="config-hint">Days back from today to read from ${esc(src.name.toUpperCase())}_PRS. Range: 1–365.</p>
          </div>
          <div class="config-field full-width">
            <label for="${id('DefaultWarehouseId')}">Default warehouse</label>
            <select id="${id('DefaultWarehouseId')}" data-key="${whKey}">
              ${whOptionsHtml(v[whKey] || '')}
            </select>
            <p class="config-hint">Target warehouse for this source on the recurring path. Manual triggers pass their own warehouse.</p>
          </div>
        </div>
      </fieldset>
    `;
  }

  async function render(panel, data) {
    const v = data.values;
    // Pre-fetch warehouses so per-source <select>s render without a flash of empty.
    let warehouses = [];
    try { warehouses = await api.warehouses() || []; } catch { /* non-fatal */ }

    const whOptionsHtml = (selectedId) => ['<option value="">— Select warehouse —</option>'].concat(
      warehouses.map(w =>
        `<option value="${esc(w.id)}"${w.id === selectedId ? ' selected' : ''}>` +
        `${esc(w.code)} · ${esc(w.name)}</option>`)
    ).join('');

    const currentCron = v['ErpSync:CronExpression'] || '';
    const isCustomCron = !SCHEDULE_PRESETS.some(p => p.cron === currentCron);

    panel.innerHTML = `
      <div class="config-form" data-section="ErpSync">
        <div class="form-grid">
          <div class="config-field">
            <label for="erpsync-Enabled">Enabled (master)</label>
            <select id="erpsync-Enabled" data-key="ErpSync:Enabled">
              <option value="true"${v['ErpSync:Enabled'] === 'true' ? ' selected' : ''}>Yes — recurring sync runs on the cron schedule</option>
              <option value="false"${v['ErpSync:Enabled'] === 'false' ? ' selected' : ''}>No — manual triggers only</option>
            </select>
            <p class="config-hint">Master kill-switch for the recurring Hangfire job. Per-source toggles below decide which sources participate inside each fire.</p>
          </div>
          <div class="config-field">
            <label for="erpsync-CronPreset">Schedule</label>
            <select id="erpsync-CronPreset">
              ${SCHEDULE_PRESETS.map(p =>
                `<option value="${esc(p.cron)}"${p.cron === currentCron ? ' selected' : ''}>${esc(p.label)}</option>`
              ).join('')}
              <option value="${CUSTOM}"${isCustomCron ? ' selected' : ''}>Custom (advanced)…</option>
            </select>
            <input type="hidden" id="erpsync-CronExpression" data-key="ErpSync:CronExpression"
              value="${esc(v['ErpSync:CronExpression'])}">
            <div id="erpsync-CronCustomWrap" class="config-field-secondary"${isCustomCron ? '' : ' hidden'}>
              <label for="erpsync-CronCustom">Cron expression (advanced)</label>
              <input type="text" id="erpsync-CronCustom" placeholder="0 * * * *"
                value="${esc(v['ErpSync:CronExpression'])}">
              <p class="config-hint">5-field cron: minute hour dom month dow. Server validates via NCrontab. <a href="https://crontab.guru/" target="_blank" rel="noopener">crontab.guru</a> can help build expressions.</p>
            </div>
          </div>
          <div class="config-field">
            <label for="erpsync-TimeoutSeconds">Timeout (seconds)</label>
            <input type="number" id="erpsync-TimeoutSeconds" data-key="ErpSync:TimeoutSeconds"
              value="${esc(v['ErpSync:TimeoutSeconds'])}" min="60" max="3600">
            <p class="config-hint">Per-run DisableConcurrentExecution timeout. Shared across sources. Range: 60–3600.</p>
          </div>
        </div>

        ${SOURCES.map(s => renderSourceFieldset(s, v, whOptionsHtml)).join('')}

        <div class="config-actions">
          <button type="button" class="btn btn-primary" data-action="save-erpsync">
            <i class="bi bi-check2"></i> Save
          </button>
          <div class="config-actions-spacer"></div>
          <button type="button" class="btn btn-link" data-action="reset-erpsync">Reset section to defaults</button>
        </div>
      </div>
    `;

    panel.querySelector('[data-action="save-erpsync"]').addEventListener('click', () => onSave(panel));
    panel.querySelector('[data-action="reset-erpsync"]').addEventListener('click', () => onReset(panel));

    // ---- v3.1.2 cron preset wiring (unchanged from single-source layout) ----
    const presetSel = panel.querySelector('#erpsync-CronPreset');
    const customWrap = panel.querySelector('#erpsync-CronCustomWrap');
    const customInput = panel.querySelector('#erpsync-CronCustom');
    const hiddenCron = panel.querySelector('#erpsync-CronExpression');

    presetSel.addEventListener('change', () => {
      if (presetSel.value === CUSTOM) {
        customWrap.hidden = false;
        customInput.value = hiddenCron.value;
        customInput.focus();
      } else {
        customWrap.hidden = true;
        hiddenCron.value = presetSel.value;
      }
    });
    customInput.addEventListener('input', () => {
      hiddenCron.value = customInput.value.trim();
    });
  }

  async function onSave(panel) {
    clearAlert(panel);
    const values = {};
    panel.querySelectorAll('[data-key]').forEach(el => {
      values[el.dataset.key] = el.value;
    });
    try {
      const result = await api.putSection('ErpSync', values);
      setAlert(panel, 'success',
        `Saved ${result.count} key(s): ${result.changedKeys.join(', ')}. Restart required.`);
      showRestartBanner();
    } catch (e) {
      const detail = e.body && e.body.key ? `${e.body.key}: ${e.body.error}` : e.message;
      setAlert(panel, 'error', `Save failed — ${detail}`);
    }
  }

  async function onReset(panel) {
    const ok = await confirmAction({
      title: 'Reset Sync Schedule section to defaults?',
      message: 'Deletes saved overrides for ErpSync:* (shared + per-source). appsettings.json values will apply after restart.',
      icon: 'warning', confirmLabel: 'Reset section', danger: true,
    });
    if (!ok) return;
    clearAlert(panel);
    try {
      const r = await api.resetSection('ErpSync');
      setAlert(panel, 'success', `Reset ${r.count} key(s). Restart required.`);
      showRestartBanner();
      const data = await api.section('ErpSync');
      await render(panel, data);
    } catch (e) {
      setAlert(panel, 'error', `Reset failed — ${e.message}`);
    }
  }

  window.registerConfigTabRenderer('ErpSync', render);
})();
