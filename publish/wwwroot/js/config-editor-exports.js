// Phase 11.2 commit 7 — Exports tab renderer.
//
// Fields:
//   Exports:BaseUrl     URL  public host for download links (non-secret)
//   Exports:SigningKey  HMAC key (secret) — NO "Change" workflow, only
//                        "Regenerate" button (system-generated, never
//                        operator-entered)
//
// Regenerate confirms loudly: pending download URLs become invalid the
// moment the new key is in effect (after restart).

(function () {
  const { api, showRestartBanner, setAlert, clearAlert } = window.__configEditor || {};
  if (!api) return;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g,
      c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  function render(panel, data) {
    const v = data.values;

    panel.innerHTML = `
      <div class="config-form" data-section="Exports">
        <div class="form-grid">
          <div class="config-field full-width">
            <label for="exports-BaseUrl">Base URL</label>
            <input type="url" id="exports-BaseUrl" data-key="Exports:BaseUrl"
              value="${esc(v['Exports:BaseUrl'])}" placeholder="https://your.public.host">
            <p class="config-hint">Public hostname for download links sent by email. Must be absolute http(s):// — use https:// in production.</p>
          </div>
          <div class="config-field full-width">
            <label>Signing key</label>
            <div class="config-secret-row">
              <input type="text" value="••••••••••••" readonly>
              <button type="button" class="btn-secret-change" data-action="regen-signing-key">Regenerate</button>
            </div>
            <p class="config-hint">
              HMAC-SHA256 key for download tokens. System-generated only —
              clicking Regenerate creates a fresh 32-byte key.
              <strong>Pending download URLs become invalid after restart.</strong>
            </p>
          </div>
        </div>

        <div class="config-actions">
          <button type="button" class="btn btn-primary" data-action="save-exports">
            <i class="bi bi-check2"></i> Save
          </button>
          <div class="config-actions-spacer"></div>
          <button type="button" class="btn btn-link" data-action="reset-exports">Reset section to defaults</button>
        </div>
      </div>
    `;

    panel.querySelector('[data-action="save-exports"]').addEventListener('click', () => onSave(panel));
    panel.querySelector('[data-action="regen-signing-key"]').addEventListener('click', () => onRegen(panel));
    panel.querySelector('[data-action="reset-exports"]').addEventListener('click', () => onReset(panel));
  }

  async function onSave(panel) {
    clearAlert(panel);
    // Only BaseUrl is non-secret here; SigningKey is regenerated, never PUT-ed.
    const values = {};
    panel.querySelectorAll('[data-key]').forEach(el => {
      values[el.dataset.key] = el.value;
    });
    try {
      const result = await api.putSection('Exports', values);
      setAlert(panel, 'success',
        `Saved ${result.count} key(s): ${result.changedKeys.join(', ')}. Restart required.`);
      showRestartBanner();
    } catch (e) {
      const detail = e.body && e.body.key ? `${e.body.key}: ${e.body.error}` : e.message;
      setAlert(panel, 'error', `Save failed — ${detail}`);
    }
  }

  async function onRegen(panel) {
    const ok = await confirmAction({
      title: 'Regenerate the signing key?',
      message: 'All pending download URLs (email links operators received recently) will stop working after the application restarts.',
      icon: 'warning', confirmLabel: 'Regenerate key', danger: true,
    });
    if (!ok) return;
    clearAlert(panel);
    const btn = panel.querySelector('[data-action="regen-signing-key"]');
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = 'Regenerating…';
    try {
      const r = await api.regenerateSigningKey();
      setAlert(panel, 'success', `Signing key regenerated. ${r.warning}`);
      showRestartBanner();
    } catch (e) {
      setAlert(panel, 'error', `Regenerate failed — ${e.message}`);
    } finally {
      btn.disabled = false;
      btn.innerHTML = orig;
    }
  }

  async function onReset(panel) {
    const ok = await confirmAction({
      title: 'Reset Exports section to defaults?',
      message: 'Deletes BaseUrl AND the signing key — every pending download URL will be invalidated, AND the dev-only placeholder signing key will be used after restart.',
      icon: 'warning', confirmLabel: 'Reset section', danger: true,
    });
    if (!ok) return;
    clearAlert(panel);
    try {
      const r = await api.resetSection('Exports');
      setAlert(panel, 'success', `Reset ${r.count} key(s). Restart required.`);
      showRestartBanner();
      const data = await api.section('Exports');
      render(panel, data);
    } catch (e) {
      setAlert(panel, 'error', `Reset failed — ${e.message}`);
    }
  }

  window.registerConfigTabRenderer('Exports', render);
})();
