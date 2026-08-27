/* ============================================================================
 * login.js — Receiving OPS sign-in.
 * Ports the mockup's interaction model to fetch-based API calls.
 *   - Theme switcher: client-side only (localStorage), same key as the rest of the app.
 *   - Warehouse dropdown: GET /api/auth/warehouses-for/{username}
 *   - Submit: POST /api/auth/login → redirect to data.redirectTo
 * ========================================================================== */
(function () {
  'use strict';

  // ============ THEME ============
  const THEME_KEY = 'pullController.theme';
  function applyTheme(name) {
    document.documentElement.setAttribute('data-theme', name);
    document.querySelectorAll('.theme-swatch').forEach(b => {
      b.classList.toggle('active', b.dataset.theme === name);
    });
    try { localStorage.setItem(THEME_KEY, name); } catch (e) {}
  }
  document.querySelectorAll('.theme-swatch').forEach(b => {
    b.addEventListener('click', () => applyTheme(b.dataset.theme));
  });
  (function init() {
    let t = 'light';
    try { t = localStorage.getItem(THEME_KEY) || 'light'; } catch (e) {}
    applyTheme(t);
  })();

  // ============ DEMO FILL ============
  document.getElementById('demo-fill').addEventListener('click', () => {
    document.getElementById('username').value = 'swattana';
    document.getElementById('password').value = 'demo1234';
    document.getElementById('username').focus();
    refreshWarehouseOptions();
  });

  // ============ PASSWORD TOGGLE ============
  const pwInput = document.getElementById('password');
  const togglePw = document.getElementById('toggle-pw');
  togglePw.addEventListener('click', () => {
    const showing = pwInput.type === 'text';
    pwInput.type = showing ? 'password' : 'text';
    togglePw.querySelector('i').className = showing ? 'bi bi-eye' : 'bi bi-eye-slash';
  });

  // ============ DYNAMIC WAREHOUSE DROPDOWN ============
  const whSelect = document.getElementById('warehouse');
  const whHelp = document.getElementById('warehouse-help');
  const usernameInput = document.getElementById('username');

  // Avoid stampede: only one request per username in flight.
  let warehouseFetchToken = 0;

  async function refreshWarehouseOptions() {
    const uname = usernameInput.value.trim();
    if (!uname) {
      whSelect.innerHTML = `<option value="">Enter username first…</option>`;
      whSelect.disabled = true;
      whHelp.textContent = 'Warehouses unlock based on your assignments';
      whHelp.style.color = 'var(--text-muted)';
      return;
    }

    const myToken = ++warehouseFetchToken;

    let warehouses;
    try {
      const r = await fetch(`/api/auth/warehouses-for/${encodeURIComponent(uname)}`, {
        headers: { 'Accept': 'application/json' },
      });
      if (!r.ok) throw new Error('Lookup failed');
      warehouses = await r.json();
    } catch (e) {
      // Network error — keep dropdown disabled. Don't block typing.
      if (myToken === warehouseFetchToken) {
        whSelect.innerHTML = `<option value="">Connection error</option>`;
        whSelect.disabled = true;
        whHelp.textContent = 'Could not reach server';
        whHelp.style.color = 'var(--error)';
      }
      return;
    }

    // Ignore stale responses (user typed again before this one arrived).
    if (myToken !== warehouseFetchToken) return;

    if (!warehouses || warehouses.length === 0) {
      whSelect.innerHTML = `<option value="">No warehouses available</option>`;
      whSelect.disabled = true;
      whHelp.textContent = 'No active warehouses assigned to this account';
      whHelp.style.color = 'var(--text-muted)';
      return;
    }

    whSelect.innerHTML = warehouses.map(w =>
      `<option value="${w.id}" data-code="${w.code}" data-name="${w.name}">${w.code} · ${w.name}</option>`
    ).join('');
    whSelect.disabled = false;
    whHelp.textContent = `${warehouses.length} warehouse${warehouses.length === 1 ? '' : 's'} available`;
    whHelp.style.color = 'var(--accent)';
  }

  // Debounce typing slightly so we don't hammer the API on every keystroke.
  let typeTimer = null;
  usernameInput.addEventListener('input', () => {
    clearTimeout(typeTimer);
    typeTimer = setTimeout(refreshWarehouseOptions, 200);
  });
  usernameInput.addEventListener('blur', refreshWarehouseOptions);

  // ============ SUBMIT ============
  const form = document.getElementById('login-form');
  const errBox = document.getElementById('form-error');
  const errMsg = document.getElementById('form-error-msg');
  const btn = document.getElementById('btn-signin');

  function showError(msg) {
    errMsg.textContent = msg;
    errBox.classList.add('show');
  }
  function hideError() { errBox.classList.remove('show'); }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    hideError();
    const username = usernameInput.value.trim();
    const password = document.getElementById('password').value;
    const remember = document.getElementById('remember').checked;
    const warehouseId = whSelect.value;

    if (!username) return showError('Username is required');
    if (!password) return showError('Password is required');
    if (!warehouseId) return showError('Please select a warehouse');

    btn.classList.add('loading');
    btn.disabled = true;

    try {
      const r = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({ username, password, warehouseId, remember }),
      });

      if (r.ok) {
        const data = await r.json();
        // Prime the app-nav session cache from /api/auth/me so the next page
        // load doesn't flash through its async auth-guard reload.
        try {
          const meRes = await fetch('/api/auth/me', { credentials: 'same-origin' });
          if (meRes.ok) {
            const me = await meRes.json();
            localStorage.setItem('auth.session', JSON.stringify({
              username:      me.username,
              name:          me.name,
              email:         me.email,
              role:          me.role,
              roleKey:       me.roleKey,
              initials:      me.initials,
              warehouse:     me.warehouseCode,
              warehouseId:   me.warehouseId,
              warehouseName: me.warehouseName,
              signedInAt:    new Date().toISOString(),
            }));
          }
        } catch (_) { /* non-fatal — app-nav will retry */ }
        window.location.href = data.redirectTo || '/Dashboard';
        return;
      }

      // RFC 7807 ProblemDetails
      let msg = 'Sign-in failed';
      try {
        const err = await r.json();
        msg = err.title || msg;
      } catch (_) {}
      showError(msg);
    } catch (e) {
      showError('Network error — please try again');
    } finally {
      btn.classList.remove('loading');
      btn.disabled = false;
    }
  });

  // Auto-focus + initial dropdown state
  usernameInput.focus();
  refreshWarehouseOptions();
})();
