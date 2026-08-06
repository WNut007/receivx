// Phase 11.2 — admin configuration editor.
//
// Scope of this file:
//   - Bootstrap: bail unless current user is admin (config.js already
//     toggles [data-admin-only] visibility; we double-check before
//     wiring fetches so non-admins don't issue 403s on page load).
//   - Tab switching: pill-style tabs, lazy panel load on activation.
//   - Per-section renderers: registered in TAB_RENDERERS — each
//     subsequent commit (4–7) plugs in one entry.
//   - Restart banner: shared helper consumed by every successful save.
//   - JSON helpers: fetchSection / putSection / postSecret / etc.
//
// The shell ships in commit 3; commits 4–7 add renderers. Until a tab
// has a renderer registered, it shows a "Coming soon" placeholder.

(function () {
  const root = document.getElementById('config-editor-root');
  if (!root) return;

  // Wait for config.js to determine the role from /api/auth/me. If
  // [data-admin-only] is still hidden by the time the DOM is ready, the
  // user isn't admin and we should not fire the section-list fetch.
  function isAdminVisible() {
    const adminSections = document.querySelectorAll('[data-admin-only]');
    return Array.from(adminSections).some(el => !el.hidden);
  }

  // -- JSON helpers ---------------------------------------------------
  async function fetchJson(url, opts = {}) {
    const res = await fetch(url, {
      headers: { 'Accept': 'application/json' },
      credentials: 'same-origin',
      ...opts,
    });
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      const err = new Error((body && body.error) || res.statusText);
      err.status = res.status;
      err.body = body;
      throw err;
    }
    return body;
  }

  const api = {
    sections: () => fetchJson('/api/admin/config/sections'),
    section: (name) => fetchJson(`/api/admin/config/sections/${encodeURIComponent(name)}`),
    putSection: (name, values) => fetchJson(`/api/admin/config/sections/${encodeURIComponent(name)}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ values }),
    }),
    postSecret: (name, key, value) => fetchJson(`/api/admin/config/sections/${encodeURIComponent(name)}/secret`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key, value }),
    }),
    resetSection: (name) => fetchJson(`/api/admin/config/sections/${encodeURIComponent(name)}`, {
      method: 'DELETE',
    }),
    regenerateSigningKey: () => fetchJson('/api/admin/config/exports/regenerate-signing-key', {
      method: 'POST',
    }),
    testErp: () => fetchJson('/api/admin/config/test/erp', { method: 'POST' }),
    testEmail: (to) => fetchJson('/api/admin/email-test', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ to }),
    }),
    warehouses: () => fetchJson('/api/warehouses'),
  };

  // -- Restart banner -------------------------------------------------
  function showRestartBanner() {
    const banner = document.getElementById('restart-banner');
    if (banner) banner.hidden = false;
  }
  const dismissBtn = document.getElementById('dismiss-restart-banner');
  if (dismissBtn) dismissBtn.addEventListener('click', () => {
    const banner = document.getElementById('restart-banner');
    if (banner) banner.hidden = true;
  });

  // -- Inline alert helper (success / error per tab) ------------------
  function setAlert(panel, kind, message) {
    let alert = panel.querySelector('.config-alert');
    if (!alert) {
      alert = document.createElement('div');
      alert.className = 'config-alert';
      panel.appendChild(alert);
    }
    alert.className = `config-alert is-${kind}`;
    alert.textContent = message;
  }
  function clearAlert(panel) {
    const alert = panel.querySelector('.config-alert');
    if (alert) alert.remove();
  }

  // -- Per-tab renderers (commits 4–7 populate this map) --------------
  // Signature: render(panel, sectionData) → void (async OK).
  // sectionData shape: { name, label, values: {key:value}, keys: [{key,isSecret}] }
  const TAB_RENDERERS = {};

  // Public registration helper so each commit's renderer file (or
  // inline IIFE) can attach without monkey-patching the module.
  window.registerConfigTabRenderer = function (name, fn) {
    TAB_RENDERERS[name] = fn;
  };

  // Expose helpers for renderers (commits 4–7 reach for these).
  window.__configEditor = { api, showRestartBanner, setAlert, clearAlert };

  // -- Tab switching --------------------------------------------------
  const loadedTabs = new Set();

  async function activateTab(name) {
    document.querySelectorAll('.config-tab').forEach(btn => {
      btn.classList.toggle('is-active', btn.dataset.tab === name);
    });
    document.querySelectorAll('.config-panel').forEach(panel => {
      panel.hidden = panel.dataset.panel !== name;
    });

    const panel = document.getElementById(`config-panel-${name}`);
    if (!panel) return;

    if (loadedTabs.has(name)) return;

    try {
      const data = await api.section(name);
      panel.innerHTML = '';  // clear loading placeholder
      const renderer = TAB_RENDERERS[name];
      if (renderer) {
        await renderer(panel, data);
      } else {
        panel.innerHTML = '<div class="config-panel-loading">Coming soon — renderer not yet registered.</div>';
      }
      loadedTabs.add(name);
    } catch (e) {
      panel.innerHTML = '';
      setAlert(panel, 'error', `Failed to load section: ${e.message}`);
    }
  }

  document.querySelectorAll('.config-tab').forEach(btn => {
    btn.addEventListener('click', () => activateTab(btn.dataset.tab));
  });

  // Initial load: wait a tick for config.js to flip [data-admin-only]
  // based on /api/auth/me before deciding whether to fire.
  setTimeout(() => {
    if (!isAdminVisible()) return;
    activateTab('Smtp');
  }, 250);
})();
