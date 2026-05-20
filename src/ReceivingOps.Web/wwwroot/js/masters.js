/* =============================================================================
 * MASTER DATA — Stage B (API-backed)
 *   Users:      /api/users    (admin only)
 *   Warehouses: /api/warehouses
 *   Audit:      /api/audit
 *
 * The verbatim mockup render functions are preserved; only the data layer was
 * rewired from localStorage to fetch().  Field-name shims convert the server's
 * (isActive, lastSignInAt, assignments[]) into the mockup-native shape
 * (active, lastSignIn, flat assignments[{userId,warehouseId,role}]).
 * ========================================================================== */

/* ---- State (populated by sync*() loaders below) ---- */
let users        = [];
let warehouses   = [];
let assignments  = [];   // flat [{ userId, warehouseId, role, warehouseCode }]
let auditLog     = [];

/* ---- noops kept so we don't have to touch the render code ---- */
function persist() {}
function log(_action, _message) {}

/* =============================================================================
 * API LAYER
 * =========================================================================== */
async function jsonFetch(url, opts) {
  const r = await fetch(url, {
    headers: { 'Accept': 'application/json', ...(opts?.headers || {}) },
    ...opts,
  });
  if (r.status === 204) return null;
  const text = await r.text();
  let body = null;
  if (text) {
    try { body = JSON.parse(text); }
    catch (e) { body = { title: text }; }
  }
  if (!r.ok) {
    const msg = body?.title || body?.detail || r.statusText || ('HTTP ' + r.status);
    const err = new Error(msg);
    err.status = r.status;
    err.body = body;
    throw err;
  }
  return body;
}

function normalizeUser(u) {
  return {
    id: u.id,
    username: u.username,
    name: u.name,
    email: u.email || '',
    phone: u.phone || '',
    role: u.role,
    active: !!u.isActive,
    lastSignIn: u.lastSignInAt || null,
    createdAt: u.createdAt,
  };
}
function normalizeWarehouse(w) {
  return {
    id: w.id,
    code: w.code,
    name: w.name,
    city: w.city || '',
    country: w.country || '',
    address: w.address || '',
    capacity: w.capacity || 0,
    timezone: w.timezone || 'Asia/Bangkok',
    managerId: w.managerId || '',
    phone: w.phone || '',
    active: !!w.isActive,
    createdAt: w.createdAt,
  };
}
function normalizeAudit(a) {
  return {
    id: a.id,
    action: a.actionType,
    message: escHtml(a.message),   // server messages are plain text; the render uses innerHTML
    actor: a.actorName || 'System',
    at: a.occurredAt,
  };
}

async function syncUsers() {
  const rows = await jsonFetch('/api/users');
  users = rows.map(normalizeUser);
  // Rebuild the flat assignments array from the inline per-user lists.
  assignments = [];
  for (const r of rows) {
    for (const a of (r.assignments || [])) {
      assignments.push({
        userId: r.id,
        warehouseId: a.warehouseId,
        warehouseCode: a.warehouseCode,
        role: a.role,
      });
    }
  }
}
async function syncWarehouses() {
  const rows = await jsonFetch('/api/warehouses');
  warehouses = rows.map(normalizeWarehouse);
}
async function syncAudit() {
  const q = document.getElementById('search-audit')?.value?.trim() || '';
  const act = document.getElementById('filter-audit-action')?.value || 'all';
  const params = new URLSearchParams();
  if (q) params.set('q', q);
  if (act && act !== 'all') params.set('action', act);
  params.set('take', '200');
  const rows = await jsonFetch('/api/audit?' + params.toString());
  auditLog = rows.map(normalizeAudit);
}

/* =============================================================================
 * Audit logging helper (server-side) — we no longer keep our own ledger,
 * but every mutation route already audits, so we just refetch when we land
 * back on the audit tab.
 * =========================================================================== */
function getCurrentActor() { return 'You'; }

/* =============================================================================
 * Helpers (unchanged from Stage A)
 * =========================================================================== */
function uid(prefix) { return prefix + '-' + Date.now() + '-' + Math.floor(Math.random()*1000); }
function initialsOf(name) {
  if (!name) return '??';
  return name.split(/\s+/).map(s => s[0]).slice(0,2).join('').toUpperCase();
}
function formatDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}
function formatDateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  return d.toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}
function userWarehouses(userId) {
  return assignments.filter(a => a.userId === userId);
}
function warehouseUsers(warehouseId) {
  return assignments.filter(a => a.warehouseId === warehouseId);
}
function escHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

/* =============================================================================
 * USERS
 * =========================================================================== */
function filteredUsers() {
  const q = document.getElementById('search-users').value.trim().toLowerCase();
  const role = document.getElementById('filter-users-role').value;
  const status = document.getElementById('filter-users-status').value;
  return users.filter(u => {
    if (role !== 'all' && u.role !== role) return false;
    if (status === 'active' && !u.active) return false;
    if (status === 'disabled' && u.active) return false;
    if (q) {
      const h = `${u.username} ${u.name} ${u.email} ${u.role}`.toLowerCase();
      if (!h.includes(q)) return false;
    }
    return true;
  });
}

function renderUsers() {
  const tbody = document.getElementById('users-tbody');
  const list = filteredUsers();
  if (list.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty-row">
      <i class="bi bi-inbox"></i>
      No users match your filter
    </td></tr>`;
  } else {
    tbody.innerHTML = list.map(u => {
      const whs = userWarehouses(u.id);
      const whChips = whs.length === 0
        ? `<span class="wh-chip none">No warehouses</span>`
        : whs.slice(0, 4).map(a => {
            const w = warehouses.find(x => x.id === a.warehouseId);
            const code = a.warehouseCode || (w && w.code) || '';
            const name = w ? w.name : code;
            return `<span class="wh-chip" title="${escHtml(name)} · ${escHtml(a.role)}">${escHtml(code)}</span>`;
          }).join('') + (whs.length > 4 ? `<span class="wh-chip">+${whs.length - 4}</span>` : '');
      return `
        <tr data-id="${u.id}">
          <td>
            <div class="user-cell">
              <div class="avatar">${escHtml(initialsOf(u.name))}</div>
              <div>
                <div class="user-name">${escHtml(u.name)}</div>
                <div class="user-username">${escHtml(u.username)} · ${escHtml(u.email)}</div>
              </div>
            </div>
          </td>
          <td><span class="role-badge ${u.role}">${escHtml(u.role)}</span></td>
          <td><div class="wh-chips">${whChips}</div></td>
          <td><span class="status-pill ${u.active ? 'active' : 'disabled'}">${u.active ? 'Active' : 'Disabled'}</span></td>
          <td style="font-family: 'Roboto Mono', monospace; font-size: 12px; color: var(--text-dim);">${formatDateTime(u.lastSignIn)}</td>
          <td>
            <div class="actions">
              <button class="btn btn-icon" data-act="edit-user" data-id="${u.id}" title="Edit"><i class="bi bi-pencil"></i></button>
              <button class="btn btn-icon danger" data-act="del-user" data-id="${u.id}" title="Delete"><i class="bi bi-trash"></i></button>
            </div>
          </td>
        </tr>
      `;
    }).join('');
  }

  document.getElementById('count-users').textContent = users.length;
  renderUserStats();
}

function renderUserStats() {
  document.getElementById('s-users-total').textContent = users.length;
  const active = users.filter(u => u.active);
  document.getElementById('s-users-active').textContent = active.length;
  document.getElementById('s-users-disabled').textContent = users.length - active.length;
  const avgWh = active.length === 0 ? 0
    : (active.reduce((sum, u) => sum + userWarehouses(u.id).length, 0) / active.length).toFixed(1);
  document.getElementById('s-users-avg-wh').textContent = avgWh;
}

function openUserModal(userId) {
  const isEdit = !!userId;
  const u = isEdit ? users.find(x => x.id === userId) : null;
  document.getElementById('userModalTitle').textContent = isEdit ? 'Edit User · ' + u.name : 'New User';
  document.getElementById('u-id').value = userId || '';
  document.getElementById('u-username').value = u ? u.username : '';
  document.getElementById('u-username').disabled = isEdit;  // username is immutable post-create
  document.getElementById('u-name').value = u ? u.name : '';
  document.getElementById('u-email').value = u ? u.email : '';
  document.getElementById('u-phone').value = u ? u.phone : '';
  document.getElementById('u-role').value = u ? u.role : 'operator';
  document.getElementById('u-password').value = '';
  document.getElementById('u-password').placeholder = isEdit ? 'Use Reset Password below' : 'Set initial password';
  document.getElementById('u-password').disabled = isEdit;  // edits go through reset-password
  document.getElementById('u-password-help').textContent = isEdit
    ? 'Use the Reset Password button to issue a new password for this user.'
    : 'Required for new users (min 4 chars).';
  document.getElementById('u-active').checked = u ? u.active : true;

  // Reset Password button — only visible in edit mode. Injected once into the
  // modal footer's left side, hidden in create mode.
  ensureResetPasswordButton(userId, isEdit);

  // Clear prior errors
  document.querySelectorAll('#userModal .form-field').forEach(f => f.classList.remove('error'));

  // Warehouse assignment editor
  const wrap = document.getElementById('u-warehouses');
  if (warehouses.length === 0) {
    wrap.innerHTML = `<div class="assign-row empty-state">No warehouses exist — create one first.</div>`;
  } else {
    const myAssigns = userId ? userWarehouses(userId) : [];
    const myMap = {};
    myAssigns.forEach(a => { myMap[a.warehouseId] = a.role; });
    wrap.innerHTML = warehouses.map(w => {
      const assigned = !!myMap[w.id];
      const role = myMap[w.id] || 'operator';
      return `
        <div class="assign-row ${w.active ? '' : 'disabled'}" data-wh="${w.id}">
          <input type="checkbox" data-wh-check="${w.id}" ${assigned ? 'checked' : ''}>
          <div class="assign-row-name">
            <span class="assign-row-code">${escHtml(w.code)}${w.active ? '' : ' · disabled'}</span>
            <span class="assign-row-label">${escHtml(w.name)} · ${escHtml(w.city || '—')}</span>
          </div>
          <select class="form-select" data-wh-role="${w.id}">
            <option value="supervisor" ${role==='supervisor'?'selected':''}>Supervisor</option>
            <option value="operator" ${role==='operator'?'selected':''}>Operator</option>
            <option value="viewer" ${role==='viewer'?'selected':''}>Viewer</option>
            <option value="admin" ${role==='admin'?'selected':''}>Admin</option>
          </select>
          <span style="color: var(--text-muted); font-family: 'Roboto Mono', monospace; font-size: 10px;">${assigned ? 'ASSIGNED' : ''}</span>
        </div>
      `;
    }).join('');
  }

  new bootstrap.Modal(document.getElementById('userModal')).show();
}

/**
 * Inject (once) a Reset Password button into the user modal's footer. It calls
 * POST /api/users/{id}/reset-password with a prompt-supplied password.
 *
 * Why dynamic instead of editing the mockup: keeps the slice/build toolchain
 * idempotent — re-running slice-masters won't clobber a hand-edit, and the
 * mockup file stays a 1:1 design reference.
 */
function ensureResetPasswordButton(userId, isEdit) {
  const footer = document.querySelector('#userModal .modal-footer');
  if (!footer) return;
  let btn = document.getElementById('btn-reset-password');
  if (!btn) {
    btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn btn-warning';
    btn.id = 'btn-reset-password';
    btn.style.marginRight = 'auto';   // push to the left, Cancel/Save stay on the right
    btn.innerHTML = `<i class="bi bi-key"></i> Reset Password`;
    footer.insertBefore(btn, footer.firstChild);
    btn.addEventListener('click', resetPasswordFromModal);
  }
  btn.style.display = isEdit ? 'inline-flex' : 'none';
  btn.dataset.userId = userId || '';
}

async function resetPasswordFromModal() {
  const btn = document.getElementById('btn-reset-password');
  const userId = btn?.dataset.userId;
  if (!userId) return;
  const u = users.find(x => x.id === userId);
  const pw = prompt(`Enter a new password for ${u ? u.name : 'this user'} (min 4 chars):`);
  if (pw === null) return;        // cancelled
  if (pw.length < 4) {
    showToast('Password must be at least 4 characters', '', 'danger');
    return;
  }
  try {
    await jsonFetch(`/api/users/${userId}/reset-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ newPassword: pw }),
    });
    showToast('Password reset', u?.username);
    if (activeTab === 'audit') syncAudit().then(renderAudit).catch(() => {});
  } catch (e) {
    showToast(e.message || 'Reset failed', '', 'danger');
  }
}

function validateUser() {
  let ok = true;
  const username = document.getElementById('u-username').value.trim();
  const name     = document.getElementById('u-name').value.trim();
  const email    = document.getElementById('u-email').value.trim();
  const password = document.getElementById('u-password').value;
  const editingId = document.getElementById('u-id').value;

  // username required, alphanumeric (server enforces uniqueness)
  const ffUsername = document.getElementById('ff-u-username');
  ffUsername.classList.remove('error');
  if (!editingId) {
    if (!username) {
      document.getElementById('err-u-username').textContent = 'Username is required';
      ffUsername.classList.add('error'); ok = false;
    } else if (!/^[a-zA-Z0-9_.]+$/.test(username)) {
      document.getElementById('err-u-username').textContent = 'Letters, numbers, underscore, dot only';
      ffUsername.classList.add('error'); ok = false;
    }
  }

  const ffName = document.getElementById('ff-u-name');
  ffName.classList.remove('error');
  if (!name) { ffName.classList.add('error'); ok = false; }

  const ffEmail = document.getElementById('ff-u-email');
  ffEmail.classList.remove('error');
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { ffEmail.classList.add('error'); ok = false; }

  if (!editingId && password.length < 4) {
    document.getElementById('u-password').focus();
    showToast('Password must be at least 4 characters', '', 'danger');
    ok = false;
  }

  return ok;
}

async function saveUser() {
  if (!validateUser()) return;

  const editingId = document.getElementById('u-id').value;
  const username  = document.getElementById('u-username').value.trim();
  const name      = document.getElementById('u-name').value.trim();
  const email     = document.getElementById('u-email').value.trim();
  const phone     = document.getElementById('u-phone').value.trim();
  const role      = document.getElementById('u-role').value;
  const password  = document.getElementById('u-password').value;
  const active    = document.getElementById('u-active').checked;

  // Build the assignments payload from the modal checkboxes
  const assignmentPayload = [];
  document.querySelectorAll('[data-wh-check]').forEach(cb => {
    if (cb.checked) {
      const whId = cb.getAttribute('data-wh-check');
      const r = document.querySelector(`[data-wh-role="${whId}"]`).value;
      assignmentPayload.push({ warehouseId: whId, role: r });
    }
  });

  try {
    let userId = editingId;
    if (editingId) {
      await jsonFetch(`/api/users/${editingId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, email, phone, role, isActive: active }),
      });
    } else {
      const created = await jsonFetch('/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username, name, email, phone, role, password, isActive: active,
          assignments: assignmentPayload,
        }),
      });
      userId = created.id;
    }

    // For edits, replace assignments. For new with no assignments, skip.
    if (editingId) {
      await jsonFetch(`/api/users/${userId}/assignments`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(assignmentPayload),
      });
    }

    await syncUsers();
    await syncWarehouses();
    renderUsers();
    renderWarehouses();
    bootstrap.Modal.getInstance(document.getElementById('userModal')).hide();
    showToast(editingId ? 'User updated' : 'User created', name);
    if (activeTab === 'audit') syncAudit().then(renderAudit).catch(() => {});
  } catch (e) {
    showToast(e.message || 'Save failed', '', 'danger');
  }
}

function deleteUser(id) {
  const u = users.find(x => x.id === id);
  if (!u) return;
  confirmAction(
    `Delete user "${u.name}"?`,
    `This removes the user and all their warehouse assignments. The audit log entry stays.`,
    async () => {
      try {
        await jsonFetch(`/api/users/${id}`, { method: 'DELETE' });
        await syncUsers();
        await syncWarehouses();
        renderUsers();
        renderWarehouses();
        showToast('User deleted', u.name, 'danger');
        if (activeTab === 'audit') syncAudit().then(renderAudit).catch(() => {});
      } catch (e) {
        showToast(e.message || 'Delete failed', '', 'danger');
      }
    }
  );
}

/* =============================================================================
 * WAREHOUSES
 * =========================================================================== */
function filteredWarehouses() {
  const q = document.getElementById('search-warehouses').value.trim().toLowerCase();
  const status = document.getElementById('filter-warehouses-status').value;
  return warehouses.filter(w => {
    if (status === 'active' && !w.active) return false;
    if (status === 'disabled' && w.active) return false;
    if (q) {
      const h = `${w.code} ${w.name} ${w.city} ${w.country}`.toLowerCase();
      if (!h.includes(q)) return false;
    }
    return true;
  });
}

function renderWarehouses() {
  const tbody = document.getElementById('warehouses-tbody');
  const list = filteredWarehouses();
  if (list.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" class="empty-row">
      <i class="bi bi-buildings"></i>
      No warehouses match your filter
    </td></tr>`;
  } else {
    tbody.innerHTML = list.map(w => {
      const userCount = warehouseUsers(w.id).length;
      const mgr = w.managerId ? users.find(u => u.id === w.managerId) : null;
      return `
        <tr data-id="${w.id}">
          <td><span style="font-family: 'Roboto Mono', monospace; font-size: 13px; font-weight: 600; color: var(--text);">${escHtml(w.code)}</span></td>
          <td>
            <div style="font-weight: 500; color: var(--text);">${escHtml(w.name)}</div>
            ${mgr ? `<div style="font-family: 'Roboto Mono', monospace; font-size: 11px; color: var(--text-muted); margin-top: 2px;">Mgr: ${escHtml(mgr.name)}</div>` : ''}
          </td>
          <td style="font-size: 13px; color: var(--text-dim);">${escHtml(w.city || '—')}, ${escHtml(w.country || '—')}</td>
          <td style="font-family: 'Roboto Mono', monospace; font-size: 13px; color: var(--text);">${(w.capacity || 0).toLocaleString()} <span style="color: var(--text-muted); font-size: 11px;">m²</span></td>
          <td><span style="font-family: 'Roboto Mono', monospace; font-size: 12px; color: var(--text-dim);">${userCount} user${userCount===1?'':'s'}</span></td>
          <td><span class="status-pill ${w.active ? 'active' : 'disabled'}">${w.active ? 'Active' : 'Disabled'}</span></td>
          <td>
            <div class="actions">
              <button class="btn btn-icon" data-act="edit-warehouse" data-id="${w.id}" title="Edit"><i class="bi bi-pencil"></i></button>
              <button class="btn btn-icon danger" data-act="del-warehouse" data-id="${w.id}" title="Delete"><i class="bi bi-trash"></i></button>
            </div>
          </td>
        </tr>
      `;
    }).join('');
  }
  document.getElementById('count-warehouses').textContent = warehouses.length;
  renderWarehouseStats();
}

function renderWarehouseStats() {
  document.getElementById('s-wh-total').textContent = warehouses.length;
  const active = warehouses.filter(w => w.active);
  document.getElementById('s-wh-active').textContent = active.length;
  const totalCap = warehouses.reduce((a, w) => a + (w.capacity || 0), 0);
  document.getElementById('s-wh-capacity').innerHTML = `${totalCap.toLocaleString()} <small>m²</small>`;
  const avgUsers = warehouses.length === 0 ? 0
    : (warehouses.reduce((sum, w) => sum + warehouseUsers(w.id).length, 0) / warehouses.length).toFixed(1);
  document.getElementById('s-wh-avg-users').textContent = avgUsers;
}

function openWarehouseModal(whId) {
  const isEdit = !!whId;
  const w = isEdit ? warehouses.find(x => x.id === whId) : null;
  document.getElementById('warehouseModalTitle').textContent = isEdit ? 'Edit Warehouse · ' + w.code : 'New Warehouse';
  document.getElementById('w-id').value = whId || '';
  document.getElementById('w-code').value = w ? w.code : '';
  document.getElementById('w-code').disabled = isEdit;  // code is immutable post-create on the server
  document.getElementById('w-name').value = w ? w.name : '';
  document.getElementById('w-city').value = w ? w.city : '';
  document.getElementById('w-country').value = w ? w.country : 'TH';
  document.getElementById('w-address').value = w ? w.address : '';
  document.getElementById('w-capacity').value = w ? w.capacity : '';
  document.getElementById('w-timezone').value = w ? w.timezone : 'Asia/Bangkok';
  document.getElementById('w-phone').value = w ? w.phone : '';
  document.getElementById('w-active').checked = w ? w.active : true;

  // Manager dropdown: only active users
  const mgrSel = document.getElementById('w-manager');
  mgrSel.innerHTML = `<option value="">— None —</option>` +
    users.filter(u => u.active).map(u =>
      `<option value="${u.id}" ${w && w.managerId === u.id ? 'selected' : ''}>${escHtml(u.name)} (${escHtml(u.username)})</option>`
    ).join('');

  document.querySelectorAll('#warehouseModal .form-field').forEach(f => f.classList.remove('error'));
  new bootstrap.Modal(document.getElementById('warehouseModal')).show();
}

function validateWarehouse() {
  let ok = true;
  const editingId = document.getElementById('w-id').value;
  const code = document.getElementById('w-code').value.trim();
  const name = document.getElementById('w-name').value.trim();

  const ffCode = document.getElementById('ff-w-code');
  ffCode.classList.remove('error');
  if (!editingId) {
    if (!code) {
      document.getElementById('err-w-code').textContent = 'Code is required';
      ffCode.classList.add('error'); ok = false;
    } else if (!/^[A-Z0-9-]+$/i.test(code)) {
      document.getElementById('err-w-code').textContent = 'Letters, numbers, dashes only';
      ffCode.classList.add('error'); ok = false;
    }
  }

  const ffName = document.getElementById('ff-w-name');
  ffName.classList.remove('error');
  if (!name) { ffName.classList.add('error'); ok = false; }

  return ok;
}

async function saveWarehouse() {
  if (!validateWarehouse()) return;

  const editingId = document.getElementById('w-id').value;
  const code      = document.getElementById('w-code').value.trim().toUpperCase();
  const name      = document.getElementById('w-name').value.trim();
  const city      = document.getElementById('w-city').value.trim();
  const country   = document.getElementById('w-country').value;
  const address   = document.getElementById('w-address').value.trim();
  const capacity  = parseInt(document.getElementById('w-capacity').value) || 0;
  const timezone  = document.getElementById('w-timezone').value;
  const managerId = document.getElementById('w-manager').value || null;
  const phone     = document.getElementById('w-phone').value.trim();
  const active    = document.getElementById('w-active').checked;

  const payload = { name, city, country, address, capacity, timezone, managerId, phone, isActive: active };

  try {
    if (editingId) {
      await jsonFetch(`/api/warehouses/${editingId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
    } else {
      await jsonFetch('/api/warehouses', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, ...payload }),
      });
    }
    await syncWarehouses();
    renderWarehouses();
    renderUsers();
    bootstrap.Modal.getInstance(document.getElementById('warehouseModal')).hide();
    showToast(editingId ? 'Warehouse updated' : 'Warehouse created', code);
    if (activeTab === 'audit') syncAudit().then(renderAudit).catch(() => {});
  } catch (e) {
    showToast(e.message || 'Save failed', '', 'danger');
  }
}

function deleteWarehouse(id) {
  const w = warehouses.find(x => x.id === id);
  if (!w) return;
  const userCount = warehouseUsers(id).length;
  confirmAction(
    `Delete warehouse "${w.code} · ${w.name}"?`,
    userCount > 0
      ? `This warehouse has ${userCount} assigned user${userCount===1?'':'s'}. Their assignments will be removed.`
      : `This action removes the warehouse and any historical references.`,
    async () => {
      try {
        await jsonFetch(`/api/warehouses/${id}`, { method: 'DELETE' });
        await syncWarehouses();
        await syncUsers();
        renderWarehouses();
        renderUsers();
        showToast('Warehouse deleted', w.code, 'danger');
        if (activeTab === 'audit') syncAudit().then(renderAudit).catch(() => {});
      } catch (e) {
        showToast(e.message || 'Delete failed', '', 'danger');
      }
    }
  );
}

/* =============================================================================
 * AUDIT LOG
 * =========================================================================== */
function filteredAudit() {
  // Server already applies q+action filters via syncAudit(); we re-filter
  // client-side for instant feedback while typing.
  const q = document.getElementById('search-audit').value.trim().toLowerCase();
  const act = document.getElementById('filter-audit-action').value;
  return auditLog.filter(a => {
    if (act !== 'all' && a.action !== act) return false;
    if (q) {
      const h = `${a.action} ${a.message} ${a.actor}`.toLowerCase();
      if (!h.includes(q)) return false;
    }
    return true;
  });
}

function renderAudit() {
  const list = filteredAudit();
  const wrap = document.getElementById('audit-list');
  if (list.length === 0) {
    wrap.innerHTML = `<div class="empty-row" style="padding: 56px 20px;">
      <i class="bi bi-journal-text"></i>
      No audit entries match
    </div>`;
  } else {
    wrap.innerHTML = list.map(a => `
      <div class="audit-row">
        <span class="audit-time">${formatDateTime(a.at)}</span>
        <span><span class="audit-action ${a.action}">${a.action}</span></span>
        <span class="audit-message">${a.message}</span>
        <span class="audit-actor">${escHtml(a.actor)}</span>
      </div>
    `).join('');
  }
  renderAuditCount();
}
function renderAuditCount() {
  document.getElementById('count-audit').textContent = auditLog.length;
}

/* =============================================================================
 * CONFIRM MODAL
 * =========================================================================== */
let _confirmCb = null;
function confirmAction(title, msg, cb) {
  document.getElementById('confirmTitle').textContent = title;
  document.getElementById('confirmMsg').textContent = msg;
  _confirmCb = cb;
  new bootstrap.Modal(document.getElementById('confirmModal')).show();
}
document.getElementById('btn-confirm-ok').addEventListener('click', () => {
  bootstrap.Modal.getInstance(document.getElementById('confirmModal')).hide();
  if (_confirmCb) _confirmCb();
  _confirmCb = null;
});

/* =============================================================================
 * TOAST
 * =========================================================================== */
function showToast(msg, sub, kind) {
  const t = document.getElementById('toast');
  document.getElementById('toast-msg').textContent = msg;
  document.getElementById('toast-sub').textContent = sub || '';
  t.classList.toggle('danger', kind === 'danger');
  document.getElementById('toast-icon').textContent = kind === 'danger' ? '!' : '✓';
  t.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => t.classList.remove('show'), 2400);
}

/* =============================================================================
 * TABS & EVENTS
 * =========================================================================== */
let activeTab = 'users';
document.querySelectorAll('.tab').forEach(t => {
  t.addEventListener('click', () => {
    activeTab = t.dataset.tab;
    document.querySelectorAll('.tab').forEach(b => b.classList.toggle('active', b === t));
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.toggle('active', p.dataset.panel === activeTab));
    if (activeTab === 'audit') {
      syncAudit().then(renderAudit).catch(e => showToast(e.message, '', 'danger'));
    }
  });
});

// User toolbar
document.getElementById('search-users').addEventListener('input', renderUsers);
document.getElementById('filter-users-role').addEventListener('change', renderUsers);
document.getElementById('filter-users-status').addEventListener('change', renderUsers);
document.getElementById('btn-new-user').addEventListener('click', () => openUserModal(null));
document.getElementById('btn-save-user').addEventListener('click', saveUser);

// Warehouse toolbar
document.getElementById('search-warehouses').addEventListener('input', renderWarehouses);
document.getElementById('filter-warehouses-status').addEventListener('change', renderWarehouses);
document.getElementById('btn-new-warehouse').addEventListener('click', () => openWarehouseModal(null));
document.getElementById('btn-save-warehouse').addEventListener('click', saveWarehouse);

// Audit toolbar — server-side search on Enter / blur; instant local filter on input
let _auditDebounce;
document.getElementById('search-audit').addEventListener('input', () => {
  renderAudit();   // instant local-filter pass
  clearTimeout(_auditDebounce);
  _auditDebounce = setTimeout(() => syncAudit().then(renderAudit).catch(() => {}), 250);
});
document.getElementById('filter-audit-action').addEventListener('change', () => {
  syncAudit().then(renderAudit).catch(() => {});
});
document.getElementById('btn-clear-audit').addEventListener('click', () => {
  showToast('Audit log cannot be cleared', 'Audit entries are permanent', 'danger');
});

// Row actions delegated
document.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const id = btn.getAttribute('data-id');
  const act = btn.getAttribute('data-act');
  if (act === 'edit-user') openUserModal(id);
  else if (act === 'del-user') deleteUser(id);
  else if (act === 'edit-warehouse') openWarehouseModal(id);
  else if (act === 'del-warehouse') deleteWarehouse(id);
});

/* =============================================================================
 * BOOTSTRAP — initial load
 * =========================================================================== */
(async function init() {
  try {
    await Promise.all([syncUsers(), syncWarehouses()]);
    renderUsers();
    renderWarehouses();
    renderAuditCount();
  } catch (e) {
    showToast(e.message || 'Failed to load master data', '', 'danger');
  }
})();
