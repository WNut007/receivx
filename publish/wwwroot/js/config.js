/* =============================================================================
 * SETTINGS PAGE — Stage B (API-backed)
 * Reads + writes /api/me/preferences. Theme/nav choices apply immediately
 * client-side; the API call then persists. Account card pulls from /api/auth/me.
 * ========================================================================== */

const PREFS = {
  theme:    'light',
  position: 'horizontal',
  behavior: 'sticky',
  collapsed: false,
};

/* ---- helpers ---- */
function highlightToggle(group, value) {
  document.querySelectorAll('#' + group + ' .toggle-option').forEach(b => {
    b.classList.toggle('active', b.dataset.value === value);
  });
}
function highlightTheme(value) {
  document.querySelectorAll('.theme-card').forEach(b => {
    b.classList.toggle('active', b.dataset.theme === value);
  });
}

/* ---- save current PREFS to the server ---- */
let putInFlight = null;
async function pushPrefs() {
  const body = {
    theme: PREFS.theme,
    navPosition: PREFS.position,
    navBehavior: PREFS.behavior,
    navCollapsed: PREFS.collapsed,
  };
  // Coalesce rapid clicks: cancel the previous put by letting it finish; we
  // always send the latest PREFS snapshot, so order doesn't matter for ack.
  putInFlight = fetch('/api/me/preferences', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  try {
    const r = await putInFlight;
    if (!r.ok) {
      const err = await r.json().catch(() => ({ title: r.statusText }));
      showToast(err.title || 'Failed to save', 'bi-exclamation-triangle');
    }
  } catch (e) {
    showToast('Network error', 'bi-wifi-off');
  }
}

/* ---- load preferences from server ---- */
async function loadPrefs() {
  try {
    const r = await fetch('/api/me/preferences', { headers: { 'Accept': 'application/json' } });
    if (!r.ok) throw new Error(r.statusText);
    const p = await r.json();
    PREFS.theme    = p.theme    || 'light';
    PREFS.position = p.navPosition || 'horizontal';
    PREFS.behavior = p.navBehavior || 'sticky';
    PREFS.collapsed = !!p.navCollapsed;
  } catch (e) {
    // First paint already showed defaults; nothing to do.
  }
  document.documentElement.setAttribute('data-theme', PREFS.theme);
  highlightTheme(PREFS.theme);
  highlightToggle('nav-position', PREFS.position);
  highlightToggle('nav-behavior', PREFS.behavior);
}

/* ---- bind controls ---- */
document.querySelectorAll('.theme-card').forEach(card => {
  card.addEventListener('click', () => {
    PREFS.theme = card.dataset.theme;
    document.documentElement.setAttribute('data-theme', PREFS.theme);
    highlightTheme(PREFS.theme);
    if (window.AppNav) window.AppNav.refresh();
    pushPrefs();
    showToast('Theme updated', 'bi-palette');
  });
});

document.querySelectorAll('#nav-position .toggle-option').forEach(b => {
  b.addEventListener('click', () => {
    PREFS.position = b.dataset.value;
    highlightToggle('nav-position', PREFS.position);
    if (window.AppNav) window.AppNav.setPosition(PREFS.position);
    pushPrefs();
    showToast('Nav position updated', 'bi-layout-sidebar');
  });
});
document.querySelectorAll('#nav-behavior .toggle-option').forEach(b => {
  b.addEventListener('click', () => {
    PREFS.behavior = b.dataset.value;
    highlightToggle('nav-behavior', PREFS.behavior);
    if (window.AppNav) window.AppNav.setBehavior(PREFS.behavior);
    pushPrefs();
    showToast('Nav behavior updated', 'bi-pin');
  });
});

/* ---- Account card population from /api/auth/me ---- */
async function loadAccount() {
  try {
    const r = await fetch('/api/auth/me', { headers: { 'Accept': 'application/json' } });
    if (!r.ok) return;
    const u = await r.json();
    document.getElementById('acc-avatar').textContent = u.initials || (u.name || 'U').slice(0,2).toUpperCase();
    document.getElementById('acc-name').textContent = u.name || 'Guest';
    document.getElementById('acc-role').textContent = u.role || 'User';
    document.getElementById('acc-role2').textContent = u.role || 'User';
    document.getElementById('acc-username').textContent = u.username || '—';
    document.getElementById('acc-warehouse').textContent = u.warehouseName || '—';
    // No precise signedInAt yet; show a relative placeholder.
    const now = new Date();
    const time = now.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    const date = now.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' });
    document.getElementById('acc-meta').textContent = `Signed in ${time} ICT · ${date}`;
    document.getElementById('acc-signin').textContent = `Today, ${time}`;

    // Reveal admin-only sections. Phase 11.2 ships the editor; the
    // earlier Email-test diagnostic was retired into the editor's
    // Email tab + test-send button. The endpoints all have their own
    // [Authorize(Roles="admin")] gate — UI hiding is convenience only.
    //
    // Use roleKey (machine value: "admin") not role (display name:
    // "Administrator"). Matches the convention in app-nav.js +
    // receiving.js. v3.1.1 fixes a v2.1.9-era bug where the wrong
    // field kept the section permanently hidden for every admin.
    if ((u.roleKey || '').toLowerCase() === 'admin') {
      document.querySelectorAll('[data-admin-only]').forEach(el => el.hidden = false);
    }
  } catch (e) { /* not fatal */ }
}

/* Phase 11.2 — the Email-test diagnostic moved into config-editor.js
   as the Email tab + Send test button. Its helpers (loadSmtpConfig,
   email-test-send listener, escapeHtml) lived only here, so they're
   gone with the markup. The /api/admin/email-test endpoint is
   unchanged; the new editor consumes it directly. */

/* ---- buttons ---- */
document.getElementById('btn-save').addEventListener('click', () => {
  pushPrefs().then(() => showToast('All settings saved', 'bi-check-circle'));
});

document.getElementById('btn-discard').addEventListener('click', () => {
  location.reload();
});

document.getElementById('btn-reset').addEventListener('click', async () => {
  const ok = await confirmAction({
    title: 'Reset preferences to defaults?',
    message: 'Theme, nav layout, and behavior return to defaults. Your account stays signed in.',
    icon: 'warning',
    confirmLabel: 'Reset preferences',
  });
  if (!ok) return;
  PREFS.theme = 'light';
  PREFS.position = 'horizontal';
  PREFS.behavior = 'sticky';
  PREFS.collapsed = false;
  await pushPrefs();
  location.reload();
});

document.getElementById('btn-signout').addEventListener('click', async () => {
  const ok = await confirmAction({
    title: 'Sign out?',
    message: 'You will need to sign in again to return.',
    icon: 'info',
    confirmLabel: 'Sign out',
  });
  if (!ok) return;
  try {
    await fetch('/api/auth/logout', { method: 'POST' });
  } catch (e) { /* ignore */ }
  window.location.href = '/Account/Login';
});

/* ---- Toast ---- */
function showToast(msg, icon) {
  const t = document.getElementById('toast');
  document.getElementById('toast-msg').textContent = msg;
  if (icon) t.querySelector('.icon-wrap').innerHTML = `<i class="bi ${icon}"></i>`;
  t.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => t.classList.remove('show'), 2200);
}

/* ---- init ---- */
loadPrefs();
loadAccount();
