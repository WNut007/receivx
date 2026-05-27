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
let currentRows = [];       // current /api/pos page (Items only — Total in currentTotal)
let currentTotal = 0;       // unfiltered-by-paging row count from PaginatedResponse
let currentPage = 1;        // Phase 8.3 — 1-based, reset to 1 on filter changes
const PAGE_SIZE = 50;       // matches PaginatedRequest default; max 500 server-side
let paginationCtrl = null;  // mountPagination() handle, initialized in startup
let currentDetail = null;   // PoDetail being edited
let currentRole = null;     // 'admin' | 'supervisor' | etc — from /api/auth/me
let newPoPullAc = null;     // autocomplete controller for the New-PO linked-pull picker

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

  // Phase 8.4 ext — Export PO list is admin OR supervisor. Backend gates;
  // hide for operators to avoid showing a button they can't use.
  const exportBtn = document.getElementById('btn-export');
  if (exportBtn && (currentRole === 'admin' || currentRole === 'supervisor')) {
    exportBtn.hidden = false;
  }
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
  // OrderDate range — preset buckets + Custom range… read from the date
  // inputs. Filters by PurchaseOrders.OrderDate server-side.
  const range = computeDateRange(document.getElementById('f-date').value);
  if (range.from) params.set('orderDateFrom', range.from);
  if (range.to)   params.set('orderDateTo',   range.to);
  // Phase 8.3 — paginate. Filter changes reset currentPage to 1 in their
  // handlers (resetPageAndReload) so this just reads the current value.
  params.set('page', currentPage);
  params.set('pageSize', PAGE_SIZE);
  return params.toString();
}

// OrderDate is a DATE column (no time / no tz). Return YYYY-MM-DD strings;
// the server's DateOnly binder accepts them directly. Calendar-day buckets,
// matching Dashboard/Transactions/Reports naming.
function computeDateRange(label) {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const ymd = d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
  const offset = n => { const d = new Date(today); d.setDate(d.getDate() + n); return d; };
  if (label === 'today')       return { from: ymd(today),       to: ymd(today) };
  if (label === 'last_2_days') return { from: ymd(offset(-1)),  to: ymd(today) };
  if (label === 'yesterday')   return { from: ymd(offset(-1)),  to: ymd(offset(-1)) };
  if (label === 'this_week') {
    const day = today.getDay() || 7;       // Mon=1..Sun=7
    return { from: ymd(offset(-(day - 1))), to: ymd(today) };
  }
  if (label === 'last_week') {
    const day = today.getDay() || 7;
    const thisMonday = offset(-(day - 1));
    const lastMonday = new Date(thisMonday); lastMonday.setDate(lastMonday.getDate() - 7);
    const lastSunday = new Date(thisMonday); lastSunday.setDate(lastSunday.getDate() - 1);
    return { from: ymd(lastMonday), to: ymd(lastSunday) };
  }
  if (label === 'custom') {
    const from = document.getElementById('date-from')?.value || null;
    const to   = document.getElementById('date-to')?.value   || null;
    return { from, to };
  }
  return { from: null, to: null };
}

async function loadList() {
  const tbody = document.getElementById('po-tbody');
  tbody.innerHTML = `<tr><td colspan="9" class="empty-row"><i class="bi bi-hourglass-split"></i> Loading…</td></tr>`;
  try {
    // Phase 8.1: /api/pos returns PaginatedResponse<PoListRow> = { items, page, pageSize, total, ... }
    const resp = await jsonFetch('/api/pos?' + buildListQuery());
    currentRows  = resp.items || [];
    currentTotal = resp.total | 0;
    // Server echoes the effective page (clamped). If the operator deep-
    // linked past the last page, the server clamps to last page; mirror
    // that in our state so the pagination control highlights correctly.
    currentPage  = resp.page | 0 || 1;
    renderList();
    paginationCtrl?.update({ page: currentPage, total: currentTotal, pageSize: PAGE_SIZE });
  } catch (e) {
    console.error('loadList failed', e);
    showToast('Could not load purchase orders', e.message, 'danger');
    currentRows = []; currentTotal = 0;
    renderList();
    paginationCtrl?.update({ page: 1, total: 0, pageSize: PAGE_SIZE });
  }
}

// Filter changes invalidate page N — operator who narrows to "WH-01 +
// Status=Open" on page 5 of 20 doesn't expect to land on a 0-row page 5
// of the narrower result set. Reset to page 1 before fetching.
function resetPageAndReload() {
  currentPage = 1;
  loadList();
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
  // Result-count surface — distinguish page slice (currentRows) from
  // server total (currentTotal). With pagination the operator may be
  // looking at 50 of 51; the badge needs to make that explicit so
  // they don't think the missing PO is a bug.
  const linkageFiltered = list.length !== currentRows.length;
  const countLabel = linkageFiltered
    ? `${list.length} shown · ${currentRows.length} on page · ${currentTotal} total`
    : `${currentRows.length} of ${currentTotal} records`;
  document.getElementById('list-count').textContent = countLabel;
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
    // Phase 9.2 bumped colspan 12 → 13 (added Order ID column).
    tbody.innerHTML = `<tr><td colspan="13" class="empty-row">
      <i class="bi bi-inbox"></i> No lines yet — click <b>Add line</b>
    </td></tr>`;
  } else {
    // Phase 9.2 — admin + supervisor can edit line metadata on an open PO.
    // The /api/pos/{id}/lines/{lineId}/extended-fields endpoint enforces
    // the same gate server-side; this is convenience-only (hide what the
    // user can't use). operator never sees the pencil.
    const canEditLineMeta = (currentRole === 'admin' || currentRole === 'supervisor')
                            && currentDetail.status === 'open';
    tbody.innerHTML = lines.map(l => {
      const hasReceipts = l.receivedQty > 0;  // best client-side proxy for §7.13
      const isWritable = currentDetail.status === 'open';
      const canDelete = isWritable && !hasReceipts;
      const deleteTitle = hasReceipts
        ? '§7.13 — line has receipts; cannot be deleted'
        : (isWritable ? 'Delete this line' : 'PO is closed');
      const editBtn = canEditLineMeta ? `
            <button class="btn btn-icon" data-act="edit-line" data-line-id="${escHtml(l.id)}"
                    title="Edit ERP fields">
              <i class="bi bi-pencil"></i>
            </button>` : '';
      return `
        <tr data-line-id="${escHtml(l.id)}">
          <td class="num">${l.lineNumber}</td>
          <td><b style="font-family:'Roboto Mono',monospace;">${escHtml(l.itemCode)}</b></td>
          <td>${escHtml(l.description)}</td>
          <td class="num">${(l.orderedQty | 0).toLocaleString()}</td>
          <td class="num">${(l.receivedQty | 0).toLocaleString()}</td>
          <td class="num">${(l.remainingQty | 0).toLocaleString()}</td>
          ${erpCell(l.orderId,      'erp-col-first')}
          ${erpCell(l.invoiceNo)}
          ${erpCell(l.subInventory)}
          ${erpCell(l.toLocation)}
          ${erpCell(l.palletId)}
          ${erpCell(l.vmiPalletId)}
          <td style="text-align:right; white-space:nowrap;">
            ${editBtn}
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

// Phase 9 — renders one ERP-sourced cell. Em-dash + muted styling for
// nulls (distinguishes "ERP hasn't populated this" from "no value");
// full text in the title tooltip so truncated values are recoverable.
function erpCell(value, extraClass) {
  const present = value != null && value !== '';
  const cls = 'erp-col' + (extraClass ? ' ' + extraClass : '') + (present ? '' : ' is-empty');
  const display = present ? escHtml(value) : '—';
  const title = present ? ` title="${escHtml(value)}"` : '';
  return `<td class="${cls}"${title}>${display}</td>`;
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
  const ok = await confirmAction({
    title: 'Delete this PO line?',
    message: 'Refused if any receipt already references this line (§7.13).',
    icon: 'trash',
    confirmLabel: 'Delete line',
    danger: true,
  });
  if (!ok) return;
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
/**
 * Searchable autocomplete factory for the §3.5 linked-pull picker.
 * Replaces a preloaded combobox so the picker stays snappy when a
 * warehouse accumulates hundreds of open pulls. Returns a controller
 * with .reset() / .getValue() that the modal lifecycle calls into.
 *
 * Wrapper contract — the HTML must contain:
 *   .autocomplete-input       — text box the user types into
 *   .autocomplete-results     — dropdown container (hidden by default)
 *   .autocomplete-selected    — chip shown when a pull is picked
 *   input[type=hidden]        — carries the selected pull GUID for submit
 *   .lock-mode-hint           — optional Mode-B hint, toggled when locked
 *
 * @param {string} wrapperId
 * @param {() => string} getWarehouseId  Read at search-time (warehouse may change).
 */
function attachPullAutocomplete(wrapperId, getWarehouseId) {
  const wrap = document.getElementById(wrapperId);
  const input = wrap.querySelector('.autocomplete-input');
  const results = wrap.querySelector('.autocomplete-results');
  const selected = wrap.querySelector('.autocomplete-selected');
  const selectedLabel = selected.querySelector('.selected-label');
  const clearBtn = selected.querySelector('.clear-btn');
  const hidden = wrap.querySelector('input[type="hidden"]');
  const lockHint = wrap.querySelector('.lock-mode-hint');

  let items = [];
  let highlighted = -1;
  let debounce = null;
  let lastQuery = '';

  function reset() {
    hidden.value = '';
    selectedLabel.textContent = '';
    selected.hidden = true;
    input.hidden = false;
    input.value = '';
    results.hidden = true;
    if (lockHint) lockHint.hidden = true;
    items = [];
    highlighted = -1;
    lastQuery = '';
  }

  function selectItem(it) {
    hidden.value = it.id;
    const lockIcon = it.lockPoByPull ? '<i class="bi bi-lock-fill" aria-hidden="true"></i> ' : '';
    selectedLabel.innerHTML = lockIcon + escHtml(it.pullNumber);
    selected.hidden = false;
    input.hidden = true;
    results.hidden = true;
    if (lockHint) lockHint.hidden = !it.lockPoByPull;
  }

  async function search(q) {
    const whId = getWarehouseId();
    if (!whId || q.length < 2) {
      results.hidden = true;
      items = [];
      return;
    }
    // Drop stale results if a faster keystroke superseded this query
    lastQuery = q;
    try {
      const queryFor = q;
      const rows = await jsonFetch(
        `/api/pulls/search?warehouseId=${encodeURIComponent(whId)}` +
        `&q=${encodeURIComponent(q)}&take=10`);
      if (queryFor !== lastQuery) return;
      items = rows || [];
      highlighted = items.length > 0 ? 0 : -1;
      render();
    } catch (e) {
      items = [];
      render();
    }
  }

  function render() {
    if (items.length === 0) {
      results.innerHTML = '<div class="autocomplete-empty">No matching open pulls</div>';
    } else {
      results.innerHTML = items.map((it, i) => {
        const lockIcon = it.lockPoByPull ? '<i class="bi bi-lock-fill" aria-hidden="true"></i>' : '';
        const itemPlural = it.itemCount === 1 ? 'item' : 'items';
        return `
          <div class="autocomplete-item${i === highlighted ? ' highlighted' : ''}" data-idx="${i}">
            <div class="pull-number">${lockIcon}${escHtml(it.pullNumber)}</div>
            <div class="meta">
              <span>${fmtDate(it.pullDate)}</span>
              <span class="pull-status-pill ${escHtml(it.status)}">${escHtml(it.status)}</span>
              <span>${it.itemCount | 0} ${itemPlural}</span>
            </div>
          </div>`;
      }).join('');
    }
    results.hidden = false;
  }

  input.addEventListener('input', (e) => {
    clearTimeout(debounce);
    debounce = setTimeout(() => search(e.target.value.trim()), 250);
  });

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      results.hidden = true;
      return;
    }
    if (results.hidden || items.length === 0) return;
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      highlighted = Math.min(highlighted + 1, items.length - 1);
      render();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      highlighted = Math.max(highlighted - 1, 0);
      render();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (highlighted >= 0) selectItem(items[highlighted]);
    }
  });

  results.addEventListener('mousedown', (e) => {
    // mousedown so the click fires before the input's blur hides the dropdown
    const itemEl = e.target.closest('.autocomplete-item');
    if (!itemEl) return;
    e.preventDefault();
    const idx = parseInt(itemEl.dataset.idx, 10);
    if (!isNaN(idx) && items[idx]) selectItem(items[idx]);
  });

  results.addEventListener('mousemove', (e) => {
    const itemEl = e.target.closest('.autocomplete-item');
    if (!itemEl) return;
    const idx = parseInt(itemEl.dataset.idx, 10);
    if (!isNaN(idx) && idx !== highlighted) {
      highlighted = idx;
      render();
    }
  });

  clearBtn.addEventListener('click', reset);

  document.addEventListener('click', (e) => {
    if (!wrap.contains(e.target)) results.hidden = true;
  });

  return { reset, getValue: () => hidden.value };
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
  if (newPoPullAc) newPoPullAc.reset();
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
// Phase 8.3 — filter changes reset to page 1 (resetPageAndReload) so a
// narrower result doesn't strand the operator on an empty deep page.
let searchDebounce = null;
document.getElementById('f-search').addEventListener('input', () => {
  clearTimeout(searchDebounce);
  searchDebounce = setTimeout(resetPageAndReload, 200);
});
['f-warehouse','f-status'].forEach(id => {
  document.getElementById(id).addEventListener('change', resetPageAndReload);
});
document.getElementById('f-linkage').addEventListener('change', renderList);   // client-side cut

// Date Range — preset paths refetch immediately; Custom waits for Apply so
// the operator picks both dates before firing. Mirrors Dashboard/Transactions.
document.getElementById('f-date').addEventListener('change', (e) => {
  const isCustom = e.target.value === 'custom';
  document.getElementById('custom-date-row').classList.toggle('visible', isCustom);
  if (!isCustom) resetPageAndReload();
});
document.getElementById('date-apply').addEventListener('click', () => {
  const from = document.getElementById('date-from').value;
  const to   = document.getElementById('date-to').value;
  if (!from || !to) { showToast('Pick both dates', 'From and To required', 'danger'); return; }
  if (from > to)    { showToast('Invalid range', '"From" must be earlier than "To"', 'danger'); return; }
  resetPageAndReload();
});
document.getElementById('date-clear').addEventListener('click', () => {
  document.getElementById('date-from').value = '';
  document.getElementById('date-to').value = '';
  resetPageAndReload();
});

document.getElementById('btn-clear-filters').addEventListener('click', () => {
  document.getElementById('f-search').value = '';
  document.getElementById('f-warehouse').value = 'all';
  document.getElementById('f-status').value = 'open';
  document.getElementById('f-linkage').value = 'all';
  document.getElementById('f-date').value = 'last_2_days';
  document.getElementById('date-from').value = '';
  document.getElementById('date-to').value = '';
  document.getElementById('custom-date-row').classList.remove('visible');
  resetPageAndReload();
});
document.getElementById('btn-refresh').addEventListener('click', () => {
  if (currentDetail) openDetail(currentDetail.id);
  else loadList();
});

// Phase 8.4 ext — Export button (admin OR supervisor only; hidden until
// loadCurrentUser sets currentRole). Sends the current filter to
// /api/exports/pos; the server enqueues a Hangfire job that emails the
// requester a signed download link when the XLSX is ready.
async function exportPosList() {
  if (currentTotal === 0) {
    showToast('Nothing to export', 'Adjust filters first', 'danger');
    return;
  }
  const range = computeDateRange(document.getElementById('f-date').value);
  const whId = document.getElementById('f-warehouse').value;
  const status = document.getElementById('f-status').value;
  const req = {
    warehouseId:   whId && whId !== 'all' ? whId : null,
    status:        status && status !== 'all' ? status : null,
    q:             document.getElementById('f-search').value.trim() || null,
    orderDateFrom: range.from || null,
    orderDateTo:   range.to   || null,
    maxRows:       100000,
  };
  try {
    const resp = await fetch('/api/exports/pos', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    });
    if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!resp.ok) {
      let title = `Queue failed (${resp.status})`;
      try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
      showToast('Export not queued', title, 'danger');
      return;
    }
    const body = await resp.json();
    showToast('Export queued', body.message || `Check ${body.email}`);
  } catch (e) {
    console.error('export queue failed', e);
    showToast('Network error', 'Could not queue export', 'danger');
  }
}
document.getElementById('btn-export').addEventListener('click', exportPosList);

document.getElementById('btn-new-po').addEventListener('click', openNewPoModal);
// The autocomplete reads warehouseId lazily from the select on each search, so
// we only need to clear the current selection when the warehouse changes —
// the picker can't show pulls scoped to a different warehouse than the PO.
newPoPullAc = attachPullAutocomplete('n-pull-ac', () => document.getElementById('n-warehouse').value);
document.getElementById('n-warehouse').addEventListener('change', () => newPoPullAc.reset());
document.getElementById('n-save').addEventListener('click', saveNewPo);

document.getElementById('btn-back-to-list').addEventListener('click', backToList);
document.getElementById('btn-save-header').addEventListener('click', saveHeader);
document.getElementById('btn-add-line').addEventListener('click', openAddLineModal);
document.getElementById('l-save').addEventListener('click', saveAddLine);
document.getElementById('btn-close-po').addEventListener('click', openCloseModal);
document.getElementById('cp-confirm').addEventListener('click', confirmClose);

// Row click → openDetail; delete-line + edit-line buttons short-circuit
// the row-open so the operator can act on a line without leaving the detail.
document.addEventListener('click', (e) => {
  const delBtn = e.target.closest('[data-act="delete-line"]');
  if (delBtn) {
    e.preventDefault(); e.stopPropagation();
    deleteLine(delBtn.getAttribute('data-line-id'));
    return;
  }
  const editBtn = e.target.closest('[data-act="edit-line"]');
  if (editBtn) {
    e.preventDefault(); e.stopPropagation();
    openEditLineModal(editBtn.getAttribute('data-line-id'));
    return;
  }
  const row = e.target.closest('#po-tbody tr[data-id]');
  if (row) openDetail(row.getAttribute('data-id'));
});

// Phase 9.2 stub — the modal markup + full save flow land in commit 3
// (9.2.3). Until then the pencil shows a toast so the wiring is testable
// without dead-clicking. Replaced by the real openEditLineModal in 9.2.3.
function openEditLineModal(lineId) {
  showToast('Edit ERP fields', 'Modal lands in 9.2.3 (line ' + lineId + ')');
}

/* ---------- Startup ---------- */
// Restore the Date Range from ?dateRange=... if the URL specifies a
// recognized value; the HTML default is already "last_2_days" so a bare
// /Pos load drops into the operational window without JS doing anything.
(function restoreDateFilterFromUrl() {
  const sel = document.getElementById('f-date');
  const want = new URLSearchParams(window.location.search).get('dateRange');
  if (!sel || !want) return;
  if (Array.from(sel.options).some(o => o.value === want)) {
    sel.value = want;
    document.getElementById('custom-date-row')?.classList.toggle('visible', want === 'custom');
  }
})();

// Phase 8.3 — mount the shared pagination control. onChange triggers
// loadList with the new currentPage; loadList → renderList →
// paginationCtrl.update() closes the loop with the server-echoed page.
paginationCtrl = mountPagination(document.getElementById('pos-pagination'), {
  page: currentPage,
  pageSize: PAGE_SIZE,
  total: 0,
  label: 'purchase orders',
  ariaLabel: 'Purchase orders pagination',
  onChange: (newPage) => {
    currentPage = newPage;
    loadList();
  },
});

(async () => {
  await Promise.all([loadCurrentUser(), loadWarehouses()]);
  await loadList();
})();
