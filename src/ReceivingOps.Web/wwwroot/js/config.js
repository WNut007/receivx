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

    // Reveal admin-only sections (Email test diagnostic). The endpoints
    // behind it have their own [Authorize(Roles="admin")] gate; this is
    // just UI cleanup so operators don't see controls they can't use.
    if (u.role === 'admin') {
      document.querySelectorAll('[data-admin-only]').forEach(el => el.hidden = false);
      loadSmtpConfig();
    }
  } catch (e) { /* not fatal */ }
}

/* ---- Email test diagnostic (admin only) ---- */
async function loadSmtpConfig() {
  try {
    const r = await fetch('/api/admin/smtp-config');
    if (!r.ok) return;
    const c = await r.json();
    document.getElementById('smtp-host').textContent = c.host || '(not set)';
    document.getElementById('smtp-port').textContent = c.port || '(not set)';
    document.getElementById('smtp-from').textContent = c.fromAddress || '(not set)';
    const credsEl = document.getElementById('smtp-creds');
    if (c.fullyConfigured) {
      credsEl.textContent = 'Configured';
      credsEl.classList.add('status-ok');
    } else if (c.host) {
      credsEl.textContent = 'Partial — set Username + Password';
      credsEl.classList.add('status-warning');
    } else {
      credsEl.textContent = 'Not configured (log-only mode)';
      credsEl.classList.add('status-warning');
    }
  } catch (e) { /* not fatal */ }
}

document.getElementById('email-test-send')?.addEventListener('click', async () => {
  const to = document.getElementById('email-test-to').value.trim();
  const resultEl = document.getElementById('email-test-result');
  const btn = document.getElementById('email-test-send');
  if (!to) {
    resultEl.hidden = false;
    resultEl.innerHTML = '<div class="alert alert-error">Please enter an email address.</div>';
    return;
  }
  btn.disabled = true;
  const origLabel = btn.innerHTML;
  btn.innerHTML = '<i class="bi bi-hourglass-split"></i> Sending…';
  resultEl.hidden = false;
  resultEl.innerHTML = '<div class="alert alert-info">Sending test email…</div>';

  try {
    const r = await fetch('/api/admin/email-test', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ to }),
    });
    const d = await r.json();
    if (d.success) {
      resultEl.innerHTML = `
        <div class="alert alert-success">
          <i class="bi bi-check-circle"></i>
          <div>
            <strong>${escapeHtml(d.message || 'Email sent')}</strong>
            <ul class="result-details">
              <li>Sent to: <code>${escapeHtml(d.sentTo)}</code></li>
              <li>Via host: <code>${escapeHtml(d.smtpHost || '(not set)')}</code></li>
              <li>From: <code>${escapeHtml(d.smtpFrom || '(not set)')}</code></li>
              <li>At: ${new Date(d.sentAt).toLocaleString()}</li>
            </ul>
            <p class="setting-help">If you don't see it within ~1 min, check spam + the
              <a href="/hangfire" target="_blank">Hangfire dashboard</a> for retry history.</p>
          </div>
        </div>`;
    } else {
      resultEl.innerHTML = `
        <div class="alert alert-error">
          <i class="bi bi-exclamation-triangle"></i>
          <div>
            <strong>Email failed</strong>
            <ul class="result-details">
              <li>Error: <code>${escapeHtml(d.error || '')}</code></li>
              ${d.errorType ? `<li>Type: <code>${escapeHtml(d.errorType)}</code></li>` : ''}
              ${d.innerError ? `<li>Inner: <code>${escapeHtml(d.innerError)}</code></li>` : ''}
            </ul>
            <details>
              <summary>Common Gmail SMTP issues</summary>
              <ul class="troubleshoot-list">
                <li><strong>"Username and Password not accepted"</strong> — Gmail rejects regular passwords; needs an App Password.
                  Generate at <a href="https://myaccount.google.com/apppasswords" target="_blank">myaccount.google.com/apppasswords</a>.</li>
                <li><strong>"App passwords not available"</strong> — enable 2-Step Verification first at
                  <a href="https://myaccount.google.com/security" target="_blank">myaccount.google.com/security</a>.</li>
                <li><strong>Connection timeout</strong> — outbound port 587 may be blocked by a firewall, or the host is wrong.</li>
                <li><strong>SSL/TLS errors</strong> — use port 587 + STARTTLS (default), not 465 + implicit SSL.</li>
              </ul>
            </details>
          </div>
        </div>`;
    }
  } catch (err) {
    resultEl.innerHTML = `<div class="alert alert-error">Network error: ${escapeHtml(err.message)}</div>`;
  } finally {
    btn.disabled = false;
    btn.innerHTML = origLabel;
  }
});

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

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
