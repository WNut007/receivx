// Phase 11.2 commit 4 — Email tab renderer.
//
// Form fields:
//   Host, Port, FromAddress, FromName, Username — text/number inputs
//   UseStartTls                                 — checkbox
//   Password                                    — masked "***" + Change btn
//
// Actions:
//   Save (PUT non-secrets)
//   Send test (calls existing /api/admin/email-test endpoint)
//   Reset to defaults (DELETE section)

(function () {
  const { api, showRestartBanner, setAlert, clearAlert } = window.__configEditor || {};
  if (!api) return;  // editor shell not loaded — defensive

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g,
      c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  function render(panel, data) {
    const v = data.values;

    panel.innerHTML = `
      <div class="config-form" data-section="Smtp">
        <div class="form-grid">
          <div class="config-field">
            <label for="smtp-Host">SMTP host</label>
            <input type="text" id="smtp-Host" data-key="Smtp:Host" value="${esc(v['Smtp:Host'])}" placeholder="smtp.gmail.com">
          </div>
          <div class="config-field">
            <label for="smtp-Port">Port</label>
            <input type="number" id="smtp-Port" data-key="Smtp:Port" value="${esc(v['Smtp:Port'])}" min="1" max="65535">
          </div>
          <div class="config-field">
            <label for="smtp-UseStartTls">Use STARTTLS</label>
            <select id="smtp-UseStartTls" data-key="Smtp:UseStartTls">
              <option value="true"${v['Smtp:UseStartTls'] === 'true' ? ' selected' : ''}>Yes</option>
              <option value="false"${v['Smtp:UseStartTls'] === 'false' ? ' selected' : ''}>No</option>
            </select>
          </div>
          <div class="config-field">
            <label for="smtp-FromAddress">From address</label>
            <input type="email" id="smtp-FromAddress" data-key="Smtp:FromAddress" value="${esc(v['Smtp:FromAddress'])}">
          </div>
          <div class="config-field">
            <label for="smtp-FromName">From name</label>
            <input type="text" id="smtp-FromName" data-key="Smtp:FromName" value="${esc(v['Smtp:FromName'])}">
          </div>
          <div class="config-field">
            <label for="smtp-Username">Username</label>
            <input type="text" id="smtp-Username" data-key="Smtp:Username" value="${esc(v['Smtp:Username'])}">
          </div>
          <div class="config-field full-width">
            <label for="smtp-Password">Password</label>
            <div class="config-secret-row">
              <input type="text" id="smtp-Password" value="••••••••••••" readonly>
              <button type="button" class="btn-secret-change" data-action="change-smtp-password">Change</button>
            </div>
            <p class="config-hint">Stored encrypted via ASP.NET Data Protection. Gmail requires an App Password (myaccount.google.com/apppasswords).</p>
          </div>
        </div>

        <div class="config-actions">
          <button type="button" class="btn btn-primary" data-action="save-smtp">
            <i class="bi bi-check2"></i> Save
          </button>
          <button type="button" class="btn" data-action="test-smtp">
            <i class="bi bi-envelope"></i> Send test
          </button>
          <div class="config-actions-spacer"></div>
          <button type="button" class="btn btn-link" data-action="reset-smtp">Reset section to defaults</button>
        </div>
      </div>
    `;

    panel.querySelector('[data-action="save-smtp"]').addEventListener('click', () => onSave(panel));
    panel.querySelector('[data-action="test-smtp"]').addEventListener('click', () => onTestSend(panel));
    panel.querySelector('[data-action="reset-smtp"]').addEventListener('click', () => onReset(panel));
    panel.querySelector('[data-action="change-smtp-password"]').addEventListener('click', () => onChangePassword(panel));
  }

  async function onSave(panel) {
    clearAlert(panel);
    const values = {};
    panel.querySelectorAll('[data-key]').forEach(el => {
      values[el.dataset.key] = el.value;
    });
    try {
      const result = await api.putSection('Smtp', values);
      setAlert(panel, 'success',
        `Saved ${result.count} key(s): ${result.changedKeys.join(', ')}. Restart required.`);
      showRestartBanner();
    } catch (e) {
      const detail = e.body && e.body.key ? `${e.body.key}: ${e.body.error}` : e.message;
      setAlert(panel, 'error', `Save failed — ${detail}`);
    }
  }

  async function onChangePassword(panel) {
    clearAlert(panel);
    // Inline reveal pattern: replace the masked row with a real password
    // input + Save/Cancel. Kept inline (vs. a modal) for parity with the
    // rest of the editor's affordances — no extra layer of indirection.
    const field = panel.querySelector('#smtp-Password').closest('.config-field');
    const hint = field.querySelector('.config-hint')?.outerHTML ?? '';
    field.innerHTML = `
      <label>New password</label>
      <input type="password" id="smtp-Password-new" autocomplete="new-password">
      <div class="config-secret-row" style="margin-top: 8px;">
        <button type="button" class="btn btn-primary" data-action="save-smtp-password">Save password</button>
        <button type="button" class="btn-secret-change" data-action="cancel-smtp-password">Cancel</button>
      </div>
      ${hint}
    `;
    field.querySelector('[data-action="save-smtp-password"]').addEventListener('click', async () => {
      const val = field.querySelector('#smtp-Password-new').value;
      if (!val) {
        setAlert(panel, 'error', 'Password cannot be empty (use Reset to clear).');
        return;
      }
      try {
        await api.postSecret('Smtp', 'Smtp:Password', val);
        setAlert(panel, 'success', 'Smtp:Password updated (encrypted). Restart required.');
        showRestartBanner();
        // Reload the panel so the Change UI snaps back to masked.
        const data = await api.section('Smtp');
        render(panel, data);
      } catch (e) {
        setAlert(panel, 'error', `Save failed — ${e.message}`);
      }
    });
    field.querySelector('[data-action="cancel-smtp-password"]').addEventListener('click', async () => {
      const data = await api.section('Smtp');
      render(panel, data);
      clearAlert(panel);
    });
  }

  async function onTestSend(panel) {
    clearAlert(panel);
    const to = prompt('Send test email to:');
    if (!to) return;
    try {
      const r = await api.testEmail(to);
      if (r.success) {
        setAlert(panel, 'success',
          `Test sent to ${r.sentTo} via ${r.smtpHost || 'log-only mode'}. ${r.message || ''}`);
      } else {
        setAlert(panel, 'error', `Send failed: ${r.error || 'unknown error'}`);
      }
    } catch (e) {
      const err = (e.body && e.body.error) || e.message;
      setAlert(panel, 'error', `Send failed: ${err}`);
    }
  }

  async function onReset(panel) {
    const ok = await confirmAction({
      title: 'Reset Email section to defaults?',
      message: 'Deletes saved overrides for Smtp:*. appsettings.json / user-secrets values will apply after restart.',
      icon: 'warning', confirmLabel: 'Reset section', danger: true,
    });
    if (!ok) return;
    clearAlert(panel);
    try {
      const r = await api.resetSection('Smtp');
      setAlert(panel, 'success', `Reset ${r.count} key(s). Restart required.`);
      showRestartBanner();
      const data = await api.section('Smtp');
      render(panel, data);
    } catch (e) {
      setAlert(panel, 'error', `Reset failed — ${e.message}`);
    }
  }

  window.registerConfigTabRenderer('Smtp', render);
})();
