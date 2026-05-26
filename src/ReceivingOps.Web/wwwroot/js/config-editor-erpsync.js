// Phase 11.2 commit 6 — Sync Schedule tab renderer.
//
// Fields (all non-secret → PUT):
//   ErpSync:Enabled              bool       master kill-switch
//   ErpSync:CronExpression       string     5-field cron (validated server-side via NCrontab)
//   ErpSync:TimeoutSeconds       int        60–3600
//   ErpSync:BackfillDays         int        1–365
//   ErpSync:DefaultWarehouseId   Guid       <select> populated from /api/warehouses

(function () {
  const { api, showRestartBanner, setAlert, clearAlert } = window.__configEditor || {};
  if (!api) return;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g,
      c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  async function render(panel, data) {
    const v = data.values;
    // Pre-fetch warehouses so the select renders without a flash of empty.
    // /api/warehouses needs only auth (not admin) — UI gate is the page,
    // not the endpoint.
    let warehouses = [];
    try { warehouses = await api.warehouses() || []; } catch { /* non-fatal */ }

    const selectedWhId = v['ErpSync:DefaultWarehouseId'] || '';
    const whOptions = ['<option value="">— Select warehouse —</option>'].concat(
      warehouses.map(w =>
        `<option value="${esc(w.id)}"${w.id === selectedWhId ? ' selected' : ''}>` +
        `${esc(w.code)} · ${esc(w.name)}</option>`)
    ).join('');

    panel.innerHTML = `
      <div class="config-form" data-section="ErpSync">
        <div class="form-grid">
          <div class="config-field">
            <label for="erpsync-Enabled">Enabled</label>
            <select id="erpsync-Enabled" data-key="ErpSync:Enabled">
              <option value="true"${v['ErpSync:Enabled'] === 'true' ? ' selected' : ''}>Yes — recurring sync runs on the cron schedule</option>
              <option value="false"${v['ErpSync:Enabled'] === 'false' ? ' selected' : ''}>No — manual triggers only</option>
            </select>
            <p class="config-hint">Master kill-switch for the recurring Hangfire job. Manual /Admin/ErpSync triggers work either way.</p>
          </div>
          <div class="config-field">
            <label for="erpsync-CronExpression">Cron expression</label>
            <input type="text" id="erpsync-CronExpression" data-key="ErpSync:CronExpression"
              value="${esc(v['ErpSync:CronExpression'])}" placeholder="0 * * * *">
            <p class="config-hint">5-field cron: minute hour dom month dow. <code>0 * * * *</code> = every hour at :00. Validated server-side.</p>
          </div>
          <div class="config-field">
            <label for="erpsync-TimeoutSeconds">Timeout (seconds)</label>
            <input type="number" id="erpsync-TimeoutSeconds" data-key="ErpSync:TimeoutSeconds"
              value="${esc(v['ErpSync:TimeoutSeconds'])}" min="60" max="3600">
            <p class="config-hint">Per-run DisableConcurrentExecution timeout. Range: 60–3600.</p>
          </div>
          <div class="config-field">
            <label for="erpsync-BackfillDays">Backfill days</label>
            <input type="number" id="erpsync-BackfillDays" data-key="ErpSync:BackfillDays"
              value="${esc(v['ErpSync:BackfillDays'])}" min="1" max="365">
            <p class="config-hint">How many days back from today to pull from BPI_PRS. Range: 1–365.</p>
          </div>
          <div class="config-field full-width">
            <label for="erpsync-DefaultWarehouseId">Default warehouse</label>
            <select id="erpsync-DefaultWarehouseId" data-key="ErpSync:DefaultWarehouseId">
              ${whOptions}
            </select>
            <p class="config-hint">Target warehouse for the recurring sync. Manual triggers pass their own warehouse and bypass this default.</p>
          </div>
        </div>

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
      message: 'Deletes saved overrides for ErpSync:*. appsettings.json values will apply after restart.',
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
