/* =============================================================================
 * Purchase Orders admin page — §3.5 Phase 5c.
 * Backed by /api/pos/* (Phase 4d) and /api/pulls (for the linked-pull picker).
 * Two surfaces in one page: list view (#view-list) ↔ detail/edit view
 * (#view-detail). Toggled by openDetail(id) / backToList().
 *
 * Auth contract:
 *   - Page is gated CanManagePulls (supervisor + admin) — see PosController.
 *   - "Close PO" button is hidden client-side for non-admin sessions. Backend
 *     /api/pos/{id}/close also enforces CanManagePulls, but the spec wants
 *     UI gating to be admin-only.
 *
 * Critical invariants reflected in this UI:
 *   - PO.PullId is set at create-time and immutable thereafter (§3.5).
 *     The detail view's pull dropdown is permanently disabled.
 *   - Line delete refused if any receipt references the line (§7.13). We
 *     pre-disable the delete button when ReceivedQty > 0 (best client proxy)
 *     and surface the server's 409 as a toast if a cancelled-only history
 *     slips past the check.
 *   - "Close PO" needs a reason — captured in the audit row server-side.
 * =========================================================================== */

let warehouses = [];        // /api/warehouses?status=active
let currentRows = [];       // current /api/pos page
let currentDetail = null;   // PoDetail being edited
let currentRole = null;     // 'admin' | 'supervisor' | etc — from /api/auth/me
let pullsForWarehouse = []; // /api/pulls cache, keyed implicitly by the warehouse selected last

/* ---------- Helpers ---------- */
function escHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function fmtDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}
function isoDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  return d.toISOString().slice(0, 10);
}

/* ---------- Toast ---------- */
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

/* ---------- HTTP shim with consistent ProblemDetails surfacing ---------- */
async function jsonFetch(url, opts) {
  const resp = await fetch(url, opts);
  if (resp.status === 401) { window.location.href = '/Account/Login'; throw new Error('unauthorized'); }
  if (resp.status === 204) return null;
  const text = await resp.text();
  let body = null;
  if (text) {
    try { body = JSON.parse(text); } catch { body = { title: text }; }
  }
  if (!resp.ok) {
    const title = (body && body.title) ? body.title : (`HTTP ${resp.status}`);
    const err = new Error(title); err.status = resp.status; err.body = body;
    throw err;
  }
  return body;
}

/* ---------- Bootstrap data ---------- */
async function loadWarehouses() {
  try {
    warehouses = await jsonFetch('/api/warehouses?status=active');
  } catch (e) {
    console.error('loadWarehouses', e);
    warehouses = [];
  }
  // Populate every WH-bound dropdown
  const opts = ['<option value="all">All warehouses</option>']
    .concat(warehouses.map(w => `<option value="${escHtml(w.id)}">${escHtml(w.code)} · ${escHtml(w.name)}</option>`));
  document.getElementById('f-warehouse').innerHTML = opts.join('');

  const newWhSel = document.getElementById('n-warehouse');
  newWhSel.innerHTML = warehouses
    .map(w => `<option value="${escHtml(w.id)}">${escHtml(w.code)} · ${escHtml(w.name)}</option>`)
    .join('');
}

async function loadCurrentUser() {
  try {
    const me = await jsonFetch('/api/auth/me');
    currentRole = me?.roleKey || me?.role || null;
  } catch {
    currentRole = null;
  }
  // §5c — Close PO is admin-only. Hide the button for non-admins (backend still gates).
  const closeBtn = document.getElementById('btn-close-po');
  if (closeBtn && currentRole !== 'admin') closeBtn.style.display = 'none';
}

/* ---------- List view ---------- */
function buildListQuery() {
  const params = new URLSearchParams();
  const q = document.getElementById('f-search').value.trim();
  if (q) params.set('q', q);
  const whId = document.getElementById('f-warehouse').value;
  if (whId && whId !== 'all') params.set('warehouseId', whId);
  const status = document.getElementById('f-status').value;
  if (status && status !== 'all') params.set('status', status);
  return params.toString();
}

async function loadList() {
  const tbody = document.getElementById('po-tbody');
  tbody.innerHTML = `<tr><td colspan="9" class="empty-row"><i class="bi bi-hourglass-split"></i> Loading…</td></tr>`;
  try {
    currentRows = await jsonFetch('/api/pos?' + buildListQuery());
    renderList();
  } catch (e) {
    console.error('loadList failed', e);
    showToast('Could not load purchase orders', e.message, 'danger');
    currentRows = [];
    renderList();
  }
}

function renderList() {
  const tbody = document.getElementById('po-tbody');
  const linkage = document.getElementById('f-linkage').value;
  let list = currentRows;
  // Linkage is a client-side cut so we don't need a server flag.
  if (linkage === 'linked')   list = list.filter(r => r.pullId);
  if (linkage === 'unlinked') list = list.filter(r => !r.pullId);

  if (list.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" class="empty-row">
      <i class="bi bi-inbox"></i> No POs match your filter
    </td></tr>`;
  } else {
    tbody.innerHTML = list.map(r => {
      const pullPill = r.pullNumber
        ? `<span class="pull-pill"><i class="bi bi-link-45deg lock-icon"></i> ${escHtml(r.pullNumber)}</span>`
        : `<span class="pull-pill unlinked">cross-pull</span>`;
      const statusCls = r.status || 'open';
      const closedCls = (r.status === 'closed' || r.status === 'canceled') ? ' closed-row' : '';
      return `
        <tr class="${closedCls.trim()}" data-id="${escHtml(r.id)}">
          <td><b>${escHtml(r.poNumber)}</b></td>
          <td>${escHtml(r.vendorName || '—')}<div class="immutable-hint" style="margin-top:0;">${escHtml(r.vendorCode || '')}</div></td>
          <td>${escHtml(r.warehouseCode)}</td>
          <td>${pullPill}</td>
          <td class="num">${r.lineCount | 0}</td>
          <td class="num">${(r.totalOrdered | 0).toLocaleString()}</td>
          <td class="num">${(r.totalReceived | 0).toLocaleString()}</td>
          <td><span class="po-status ${escHtml(statusCls)}">${escHtml(statusCls)}</span></td>
          <td>${fmtDate(r.orderDate)}</td>
        </tr>
      `;
    }).join('');
  }
  document.getElementById('list-count').textContent = `${list.length} of ${currentRows.length} records`;
  document.getElementById('footer-list').textContent =
    list.length === 0 ? '—' : `${list.length} purchase orders`;
}

/* ---------- Detail view ---------- */
async function openDetail(id) {
  try {
    currentDetail = await jsonFetch('/api/pos/' + encodeURIComponent(id));
  } catch (e) {
    showToast('Could not open PO', e.message, 'danger');
    return;
  }
  document.getElementById('view-list').style.display = 'none';
  document.getElementById('view-detail').style.display = '';

  document.getElementById('d-title').textContent = currentDetail.poNumber;
  const statusEl = document.getElementById('d-status');
  statusEl.textContent = currentDetail.status;
  statusEl.className = 'po-status ' + currentDetail.status;

  document.getElementById('d-po-number').textContent = currentDetail.poNumber;
  document.getElementById('d-warehouse').textContent = currentDetail.warehouseCode + (currentDetail.warehouseName ? (' · ' + currentDetail.warehouseName) : '');
  document.getElementById('d-vendor-code').value = currentDetail.vendorCode || '';
  document.getElementById('d-vendor-name').value = currentDetail.vendorName || '';
  document.getElementById('d-order-date').value = isoDate(currentDetail.orderDate);
  document.getElementById('d-expected-date').value = isoDate(currentDetail.expectedDate);
  document.getElementById('d-notes').value = currentDetail.notes || '';
  document.getElementById('d-created-by').textContent =
    (currentDetail.createdByName || '—') + ' · ' + fmtDate(currentDetail.createdAt);

  // Pull dropdown: rendered DISABLED with only the current value shown.
  // This enforces §3.5 immutability — the input physically cannot be changed.
  const pullSel = document.getElementById('d-pull-id');
  if (currentDetail.pullId) {
    pullSel.innerHTML = `<option value="${escHtml(currentDetail.pullId)}" selected>${escHtml(currentDetail.pullNumber || '—')}</option>`;
  } else {
    pullSel.innerHTML = `<option value="" selected>(none — cross-pull pool)</option>`;
  }
  pullSel.disabled = true;   // §3.5 — immutable after create

  // Disable header edits + lines if PO is closed/canceled.
  const isWritable = currentDetail.status === 'open';
  ['d-vendor-code','d-vendor-name','d-order-date','d-expected-date','d-notes'].forEach(id => {
    document.getElementById(id).disabled = !isWritable;
  });
  document.getElementById('btn-save-header').disabled = !isWritable;
  document.getElementById('btn-add-line').disabled = !isWritable;
  const closeBtn = document.getElementById('btn-close-po');
  if (currentRole === 'admin') closeBtn.style.display = isWritable ? '' : 'none';

  renderLines();
}

function renderLines() {
  const tbody = document.getElementById('po-lines-tbody');
  const lines = currentDetail.lines || [];
  if (lines.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" class="empty-row">
      <i class="bi bi-inbox"></i> No lines yet — click <b>Add line</b>
    </td></tr>`;
  } else {
    tbody.innerHTML = lines.map(l => {
      const hasReceipts = l.receivedQty > 0;  // best client-side proxy for §7.13
      const isWritable = currentDetail.status === 'open';
      const canDelete = isWritable && !hasReceipts;
      const deleteTitle = hasReceipts
        ? '§7.13 — line has receipts; cannot be deleted'
        : (isWritable ? 'Delete this line' : 'PO is closed');
      return `
        <tr data-line-id="${escHtml(l.id)}">
          <td class="num">${l.lineNumber}</td>
          <td><b style="font-family:'Roboto Mono',monospace;">${escHtml(l.itemCode)}</b></td>
          <td>${escHtml(l.description)}</td>
          <td class="num">${(l.orderedQty | 0).toLocaleString()}</td>
          <td class="num">${(l.receivedQty | 0).toLocaleString()}</td>
          <td class="num">${(l.remainingQty | 0).toLocaleString()}</td>
          <td style="text-align:right;">
            <button class="btn btn-icon danger" data-act="delete-line" data-line-id="${escHtml(l.id)}"
                    title="${escHtml(deleteTitle)}" ${canDelete ? '' : 'disabled'}>
              <i class="bi bi-trash"></i>
            </button>
          </td>
        </tr>
      `;
    }).join('');
  }
  document.getElementById('footer-detail').textContent =
    lines.length === 0 ? '—' : `${lines.length} lines · ${lines.reduce((s, l) => s + (l.orderedQty|0), 0).toLocaleString()} pcs ordered`;
}

function backToList() {
  currentDetail = null;
  document.getElementById('view-detail').style.display = 'none';
  document.getElementById('view-list').style.display = '';
  loadList();
}

async function saveHeader() {
  if (!currentDetail) return;
  const body = {
    vendorCode:   document.getElementById('d-vendor-code').value.trim() || null,
    vendorName:   document.getElementById('d-vendor-name').value.trim() || null,
    orderDate:    document.getElementById('d-order-date').value || null,
    expectedDate: document.getElementById('d-expected-date').value || null,
    notes:        document.getElementById('d-notes').value.trim() || null,
    pullId:       currentDetail.pullId || null,   // §3.5 — must echo current value
  };
  const btn = document.getElementById('btn-save-header');
  btn.disabled = true;
  try {
    currentDetail = await jsonFetch('/api/pos/' + encodeURIComponent(currentDetail.id), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    showToast('Header saved', currentDetail.poNumber);
    renderLines();
  } catch (e) {
    showToast('Save failed', e.message, 'danger');
  } finally {
    btn.disabled = false;
  }
}

/* ---------- Add-line modal ---------- */
function openAddLineModal() {
  if (!currentDetail) return;
  const nextLine = (currentDetail.lines && currentDetail.lines.length > 0)
    ? Math.max(...currentDetail.lines.map(l => l.lineNumber)) + 1
    : 1;
  document.getElementById('l-line-number').value = nextLine;
  document.getElementById('l-item-code').value = '';
  document.getElementById('l-description').value = '';
  document.getElementById('l-ordered-qty').value = '';
  new bootstrap.Modal(document.getElementById('addLineModal')).show();
}

async function saveAddLine() {
  if (!currentDetail) return;
  const body = {
    lineNumber:  parseInt(document.getElementById('l-line-number').value, 10) || 0,
    itemCode:    document.getElementById('l-item-code').value.trim(),
    description: document.getElementById('l-description').value.trim(),
    orderedQty:  parseInt(document.getElementById('l-ordered-qty').value, 10) || 0,
  };
  if (!body.lineNumber || !body.itemCode || !body.description || !body.orderedQty) {
    return showToast('Fill all fields', 'Line #, Item, Description, Qty required', 'danger');
  }
  const btn = document.getElementById('l-save');
  btn.disabled = true;
  try {
    await jsonFetch(`/api/pos/${encodeURIComponent(currentDetail.id)}/lines`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    bootstrap.Modal.getInstance(document.getElementById('addLineModal')).hide();
    showToast('Line added', `${body.itemCode} · ${body.orderedQty} pcs`);
    await openDetail(currentDetail.id);
  } catch (e) {
    showToast('Add line failed', e.message, 'danger');
  } finally {
    btn.disabled = false;
  }
}

async function deleteLine(lineId) {
  if (!currentDetail) return;
  if (!confirm('Delete this line? Refused if any receipt references it (§7.13).')) return;
  try {
    await jsonFetch(`/api/pos/${encodeURIComponent(currentDetail.id)}/lines/${encodeURIComponent(lineId)}`, {
      method: 'DELETE',
    });
    showToast('Line deleted');
    await openDetail(currentDetail.id);
  } catch (e) {
    showToast('Delete refused', e.message, 'danger');
  }
}

/* ---------- New-PO modal ---------- */
async function refreshPullPicker(targetSelectId, warehouseId) {
  const sel = document.getElementById(targetSelectId);
  if (!sel) return;
  sel.innerHTML = `<option value="">(none — cross-pull pool)</option>`;
  if (!warehouseId) return;
  try {
    // Open pulls = pending OR in_progress; the server's filter is single-string,
    // so call twice and merge. Tiny dataset; cheap.
    const [pending, inProg] = await Promise.all([
      jsonFetch(`/api/pulls?warehouseId=${encodeURIComponent(warehouseId)}&status=pending`),
      jsonFetch(`/api/pulls?warehouseId=${encodeURIComponent(warehouseId)}&status=in_progress`),
    ]);
    const merged = [].concat(pending || [], inProg || []);
    pullsForWarehouse = merged;
    sel.innerHTML += merged.map(p =>
      `<option value="${escHtml(p.id)}">${escHtml(p.pullNumber)}${p.lockPoByPull ? ' · 🔒 locked' : ''}</option>`
    ).join('');
  } catch (e) {
    console.error('refreshPullPicker', e);
  }
}

function openNewPoModal() {
  document.getElementById('n-po-number').value = '';
  document.getElementById('n-vendor-code').value = '';
  document.getElementById('n-vendor-name').value = '';
  document.getElementById('n-order-date').value = new Date().toISOString().slice(0, 10);
  document.getElementById('n-expected-date').value = '';
  document.getElementById('n-notes').value = '';
  const whSel = document.getElementById('n-warehouse');
  if (whSel.options.length > 0) whSel.selectedIndex = 0;
  refreshPullPicker('n-pull-id', whSel.value);
  new bootstrap.Modal(document.getElementById('newPoModal')).show();
}

async function saveNewPo() {
  const body = {
    poNumber:     document.getElementById('n-po-number').value.trim(),
    warehouseId:  document.getElementById('n-warehouse').value,
    vendorCode:   document.getElementById('n-vendor-code').value.trim() || null,
    vendorName:   document.getElementById('n-vendor-name').value.trim() || null,
    orderDate:    document.getElementById('n-order-date').value || null,
    expectedDate: document.getElementById('n-expected-date').value || null,
    notes:        document.getElementById('n-notes').value.trim() || null,
    pullId:       document.getElementById('n-pull-id').value || null,
    lines:        [],
  };
  if (!body.poNumber || !body.warehouseId || !body.orderDate) {
    return showToast('Fill required fields', 'PO #, warehouse, order date are required', 'danger');
  }
  const btn = document.getElementById('n-save');
  btn.disabled = true;
  try {
    const detail = await jsonFetch('/api/pos', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    bootstrap.Modal.getInstance(document.getElementById('newPoModal')).hide();
    showToast('PO created', detail.poNumber);
    await openDetail(detail.id);
  } catch (e) {
    showToast('Create failed', e.message, 'danger');
  } finally {
    btn.disabled = false;
  }
}

/* ---------- Close PO modal ---------- */
function openCloseModal() {
  if (!currentDetail) return;
  document.getElementById('cp-po-number').textContent = currentDetail.poNumber;
  document.getElementById('cp-vendor').textContent = currentDetail.vendorName || '—';
  const outstanding = (currentDetail.lines || []).reduce((s, l) => s + Math.max(0, (l.orderedQty | 0) - (l.receivedQty | 0)), 0);
  document.getElementById('cp-outstanding').textContent = outstanding.toLocaleString() + ' pcs';
  document.getElementById('cp-pull').textContent = currentDetail.pullNumber || '(cross-pull)';
  document.getElementById('cp-reason').value = '';
  new bootstrap.Modal(document.getElementById('closePoModal')).show();
}

async function confirmClose() {
  if (!currentDetail) return;
  const reason = document.getElementById('cp-reason').value.trim();
  if (!reason) return showToast('Reason required', 'Audit trail captures it', 'danger');
  const btn = document.getElementById('cp-confirm');
  btn.disabled = true;
  try {
    await jsonFetch(`/api/pos/${encodeURIComponent(currentDetail.id)}/close`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ reason }),
    });
    bootstrap.Modal.getInstance(document.getElementById('closePoModal')).hide();
    showToast('PO closed', currentDetail.poNumber);
    await openDetail(currentDetail.id);
  } catch (e) {
    showToast('Close failed', e.message, 'danger');
  } finally {
    btn.disabled = false;
  }
}

/* ---------- Events ---------- */
let searchDebounce = null;
document.getElementById('f-search').addEventListener('input', () => {
  clearTimeout(searchDebounce);
  searchDebounce = setTimeout(loadList, 200);
});
['f-warehouse','f-status'].forEach(id => {
  document.getElementById(id).addEventListener('change', loadList);
});
document.getElementById('f-linkage').addEventListener('change', renderList);   // client-side cut
document.getElementById('btn-clear-filters').addEventListener('click', () => {
  document.getElementById('f-search').value = '';
  document.getElementById('f-warehouse').value = 'all';
  document.getElementById('f-status').value = 'open';
  document.getElementById('f-linkage').value = 'all';
  loadList();
});
document.getElementById('btn-refresh').addEventListener('click', () => {
  if (currentDetail) openDetail(currentDetail.id);
  else loadList();
});

document.getElementById('btn-new-po').addEventListener('click', openNewPoModal);
document.getElementById('n-warehouse').addEventListener('change', (e) => refreshPullPicker('n-pull-id', e.target.value));
document.getElementById('n-save').addEventListener('click', saveNewPo);

document.getElementById('btn-back-to-list').addEventListener('click', backToList);
document.getElementById('btn-save-header').addEventListener('click', saveHeader);
document.getElementById('btn-add-line').addEventListener('click', openAddLineModal);
document.getElementById('l-save').addEventListener('click', saveAddLine);
document.getElementById('btn-close-po').addEventListener('click', openCloseModal);
document.getElementById('cp-confirm').addEventListener('click', confirmClose);

// Row click → openDetail; delete-line button → deleteLine (no row-open)
document.addEventListener('click', (e) => {
  const delBtn = e.target.closest('[data-act="delete-line"]');
  if (delBtn) {
    e.preventDefault(); e.stopPropagation();
    deleteLine(delBtn.getAttribute('data-line-id'));
    return;
  }
  const row = e.target.closest('#po-tbody tr[data-id]');
  if (row) openDetail(row.getAttribute('data-id'));
});

/* ---------- Startup ---------- */
(async () => {
  await Promise.all([loadCurrentUser(), loadWarehouses()]);
  await loadList();
})();
