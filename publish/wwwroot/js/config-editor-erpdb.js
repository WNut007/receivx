// Phase 11.2 commit 5 — ERP Connection tab renderer.
//
// Only one key in this section: ErpDb:ConnectionString (secret).
// The Save flow goes through POST /sections/ErpDb/secret directly —
// no PUT for non-secrets needed.
//
// "Test connection" hits POST /api/admin/config/test/erp which opens
// the live IErpDbConnectionFactory + runs SELECT @@VERSION (5s timeout).

(function () {
  const { api, showRestartBanner, setAlert, clearAlert } = window.__configEditor || {};
  if (!api) return;

  function render(panel, data) {
    // ErpDb:ConnectionString is encrypted in the DB and masked here;
    // we never know the prior plaintext in the UI. The Change workflow
    // is the only way to set/replace it.
    panel.innerHTML = `
      <div class="config-form" data-section="ErpDb">
        <div class="form-grid" style="grid-template-columns: 1fr;">
          <div class="config-field full-width">
            <label>Connection string</label>
            <div class="config-secret-row">
              <input type="text" value="••••••••••••" readonly>
              <button type="button" class="btn-secret-change" data-action="change-erp-cs">Change</button>
            </div>
            <p class="config-hint">
              Format: <code>Server=...;Database=...;User Id=...;Password=...;TrustServerCertificate=true</code>.
              Stored encrypted. The credentials inside are also masked from the API surface — only the encryption layer ever sees plaintext.
            </p>
          </div>
        </div>

        <div class="config-actions">
          <button type="button" class="btn" data-action="test-erp">
            <i class="bi bi-plug"></i> Test connection
          </button>
          <div class="config-actions-spacer"></div>
          <button type="button" class="btn btn-link" data-action="reset-erpdb">Reset section to defaults</button>
        </div>
      </div>
    `;

    panel.querySelector('[data-action="change-erp-cs"]').addEventListener('click', () => onChange(panel));
    panel.querySelector('[data-action="test-erp"]').addEventListener('click', () => onTest(panel));
    panel.querySelector('[data-action="reset-erpdb"]').addEventListener('click', () => onReset(panel));
  }

  async function onChange(panel) {
    clearAlert(panel);
    const field = panel.querySelector('.config-field');
    const hintHtml = field.querySelector('.config-hint')?.outerHTML ?? '';
    field.innerHTML = `
      <label for="erpdb-cs-new">New connection string</label>
      <textarea id="erpdb-cs-new" rows="3" autocomplete="off"
        placeholder="Server=...;Database=...;User Id=...;Password=...;TrustServerCertificate=true"></textarea>
      <div class="config-secret-row" style="margin-top: 8px;">
        <button type="button" class="btn btn-primary" data-action="save-erpdb-cs">Save</button>
        <button type="button" class="btn-secret-change" data-action="cancel-erpdb-cs">Cancel</button>
      </div>
      ${hintHtml}
    `;
    field.querySelector('[data-action="save-erpdb-cs"]').addEventListener('click', async () => {
      const val = field.querySelector('#erpdb-cs-new').value.trim();
      if (!val) {
        setAlert(panel, 'error', 'Connection string cannot be empty (use Reset to clear).');
        return;
      }
      try {
        await api.postSecret('ErpDb', 'ErpDb:ConnectionString', val);
        setAlert(panel, 'success', 'ErpDb:ConnectionString updated (encrypted). Restart required.');
        showRestartBanner();
        const data = await api.section('ErpDb');
        render(panel, data);
      } catch (e) {
        setAlert(panel, 'error', `Save failed — ${e.message}`);
      }
    });
    field.querySelector('[data-action="cancel-erpdb-cs"]').addEventListener('click', async () => {
      const data = await api.section('ErpDb');
      render(panel, data);
      clearAlert(panel);
    });
  }

  async function onTest(panel) {
    clearAlert(panel);
    const btn = panel.querySelector('[data-action="test-erp"]');
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<i class="bi bi-hourglass-split"></i> Testing…';
    try {
      const r = await api.testErp();
      if (r.success) {
        setAlert(panel, 'success',
          `Connected to ${r.server}/${r.database}. Banner: ${r.banner || '(none)'}`);
      } else {
        setAlert(panel, 'error', `Connection failed: ${r.error || 'unknown error'}`);
      }
    } catch (e) {
      const err = (e.body && e.body.error) || e.message;
      setAlert(panel, 'error', `Connection failed: ${err}`);
    } finally {
      btn.disabled = false;
      btn.innerHTML = orig;
    }
  }

  async function onReset(panel) {
    const ok = await confirmAction({
      title: 'Reset ERP Connection section to defaults?',
      message: 'Deletes the saved connection string. appsettings.json / user-secrets fallback will apply after restart.',
      icon: 'warning', confirmLabel: 'Reset section', danger: true,
    });
    if (!ok) return;
    clearAlert(panel);
    try {
      const r = await api.resetSection('ErpDb');
      setAlert(panel, 'success', `Reset ${r.count} key(s). Restart required.`);
      showRestartBanner();
      const data = await api.section('ErpDb');
      render(panel, data);
    } catch (e) {
      setAlert(panel, 'error', `Reset failed — ${e.message}`);
    }
  }

  window.registerConfigTabRenderer('ErpDb', render);
})();
