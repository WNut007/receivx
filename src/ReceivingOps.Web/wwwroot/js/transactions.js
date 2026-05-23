/* =============================================================================
 * Transactions page — Stage B: backed by GET /api/transactions (§6 / §9.4).
 * Filter UI builds a query string on every change/input; server returns paged
 * rows in vw_TransactionsJournal shape. The "operators" dropdown is populated
 * from whatever rows came back (there's no /api/users yet — §15 #11).
 * =========================================================================== */

const PAGE_SIZE = 500;            // generous enough for the dashboard view; will
                                  // need real paging UI when datasets get bigger.

let currentRows = [];             // last server response (camelCase journal rows)
let currentTotal = 0;
let hourFilter = null;            // set by ?hour= URL param; cleared via banner X
let sortBy = null;                // §5b — null = server order; 'po' = client sort by PoNumber·LineNumber·ReceivedAt
let sortDir = 'asc';              // 'asc' | 'desc'

/* ---------- DOM helpers ---------- */
function escHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function formatTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  if (sameDay) return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  return d.toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}
function formatFull(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

/* ---------- URL → filter state ---------- */
function applyUrlFiltersToUi() {
  const params = new URLSearchParams(window.location.search);
  const searchTerms = [];
  if (params.get('pull')) searchTerms.push(params.get('pull'));
  if (params.get('item')) searchTerms.push(params.get('item'));
  if (searchTerms.length > 0) {
    document.getElementById('f-search').value = searchTerms.join(' ');
    // When linked from another page, default to "all time" so the user actually
    // sees the rows (the 2-day default would hide older pulls that the link
    // explicitly targeted).
    document.getElementById('f-date').value = 'all';
  }
  // ?dateRange=... overrides whatever value the HTML <option selected> set.
  // Wins over the "linked-from-elsewhere → all" fallback above when present.
  const dr = params.get('dateRange');
  const dateSel = document.getElementById('f-date');
  if (dr && dateSel && [...dateSel.options].some(o => o.value === dr)) {
    dateSel.value = dr;
  }
  // Reveal the custom-range row if the selected option is "custom".
  document.getElementById('custom-date-row')?.classList.toggle('visible',
    dateSel?.value === 'custom');
  if (params.get('warehouse')) {
    const wh = params.get('warehouse');
    const sel = document.getElementById('f-warehouse');
    if ([...sel.options].some(o => o.value === wh)) sel.value = wh;
  }
  const hour = params.get('hour');
  if (hour !== null && hour !== '') {
    const h = parseInt(hour, 10);
    if (!isNaN(h)) {
      hourFilter = h;
      const banner = document.getElementById('hour-filter-banner');
      banner.style.display = 'flex';
      const label = document.getElementById('hour-filter-label');
      const ctx = [];
      if (params.get('pull')) ctx.push(params.get('pull'));
      if (params.get('item')) ctx.push(params.get('item'));
      label.innerHTML = `<i class="bi bi-clock"></i> ${String(h).padStart(2,'0')}:00${ctx.length ? ' · ' + ctx.join(' · ') : ''}`;
    }
  }

  // "Minimize" — only meaningful when the user landed here from the
  // /Receiving drawer's "Open full view ↗" link, which always includes
  // ?pull=. Wire it to /Receiving/{pull} so the inverse navigation is
  // symmetric.
  const pull = params.get('pull');
  const minBtn = document.getElementById('btn-minimize');
  if (minBtn && pull) {
    minBtn.href = '/Receiving/' + encodeURIComponent(pull);
    minBtn.style.display = '';
  }
}

/* ---------- Build query string from filter UI ---------- */
function buildQueryString() {
  const params = new URLSearchParams();

  const q = document.getElementById('f-search').value.trim();
  if (q) params.set('q', q);

  const wh = document.getElementById('f-warehouse').value;
  if (wh && wh !== 'all') params.set('warehouseCode', wh);

  const act = document.getElementById('f-action').value;
  // Client labels → server `kind` values per vw_TransactionsJournal.
  const kindMap = { 'receive': 'receive', 'cancel': 'reversal', 'voided': 'voided' };
  if (act && act !== 'all' && kindMap[act]) params.set('kind', kindMap[act]);

  const dateF = document.getElementById('f-date').value;
  const dateRange = computeDateRange(dateF);
  if (dateRange.from) params.set('dateFrom', dateRange.from.toISOString());
  if (dateRange.to)   params.set('dateTo',   dateRange.to.toISOString());

  const op = document.getElementById('f-operator').value;
  if (op && op !== 'all') params.set('receivedByName', op);

  if (hourFilter !== null) params.set('hour', String(hourFilter));

  params.set('take', String(PAGE_SIZE));
  params.set('skip', '0');
  return params.toString();
}

// Calendar-day buckets, matching Dashboard/Reports naming. Filter source =
// Receipts.ReceivedAt (handled server-side via dateFrom/dateTo). The "to"
// end is exclusive day-boundary (next day's 00:00), which the server's
// `r.ReceivedAt < @DateTo` comparison handles natively.
function computeDateRange(label) {
  const now = new Date();
  const startOfDay = (offset = 0) =>
    new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
  if (label === 'today') {
    return { from: startOfDay(0), to: null };
  }
  if (label === 'last_2_days') {
    // Today + Yesterday — calendar days, NOT rolling 48h.
    return { from: startOfDay(-1), to: null };
  }
  if (label === 'yesterday') {
    return { from: startOfDay(-1), to: startOfDay(0) };
  }
  if (label === 'this_week') {
    const d = startOfDay(0);
    const day = d.getDay() || 7;       // Mon=1..Sun=7
    d.setDate(d.getDate() - (day - 1));
    return { from: d, to: null };
  }
  if (label === 'last_week') {
    const thisMonday = startOfDay(0);
    const day = thisMonday.getDay() || 7;
    thisMonday.setDate(thisMonday.getDate() - (day - 1));
    const lastMonday = new Date(thisMonday); lastMonday.setDate(lastMonday.getDate() - 7);
    return { from: lastMonday, to: thisMonday };
  }
  if (label === 'custom') {
    // Both inputs are <input type="date"> → YYYY-MM-DD strings.
    const fromStr = document.getElementById('date-from')?.value;
    const toStr   = document.getElementById('date-to')?.value;
    const from = fromStr ? new Date(fromStr + 'T00:00:00') : null;
    // Exclusive end-of-day for "to": +1 day so the picked date is fully included.
    const to   = toStr   ? new Date(new Date(toStr + 'T00:00:00').getTime() + 86400000) : null;
    return { from, to };
  }
  return { from: null, to: null };
}

/* ---------- Fetch + render ---------- */
async function loadData() {
  const tbody = document.getElementById('tx-tbody');
  tbody.innerHTML = `<tr><td colspan="11" class="empty-row"><i class="bi bi-hourglass-split"></i> Loading…</td></tr>`;

  try {
    const resp = await fetch('/api/transactions?' + buildQueryString());
    if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!resp.ok) {
      let title = `Load failed (${resp.status})`;
      try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
      showToast('Could not load transactions', title, 'danger');
      currentRows = []; currentTotal = 0;
      render();
      return;
    }
    const page = await resp.json();
    currentRows = page.rows || [];
    currentTotal = page.total | 0;
    refreshOperators();
    render();
  } catch (e) {
    console.error('loadData failed', e);
    showToast('Network error', 'Could not reach server', 'danger');
    currentRows = []; currentTotal = 0;
    render();
  }
}

function actionPillHtml(r) {
  if (r.kind === 'reversal' || r.qtyReceived < 0) return `<span class="action-pill cancel"><i class="bi bi-arrow-counterclockwise"></i> Cancel</span>`;
  if (r.kind === 'voided'   || r.reversedById)    return `<span class="action-pill voided"><i class="bi bi-slash-circle"></i> Voided</span>`;
  return `<span class="action-pill receive"><i class="bi bi-plus-circle"></i> Receive</span>`;
}

function render() {
  const tbody = document.getElementById('tx-tbody');
  const list = sortBy === 'po' ? sortRowsByPo(currentRows, sortDir) : currentRows;
  if (list.length === 0) {
    tbody.innerHTML = `<tr><td colspan="11" class="empty-row">
      <i class="bi bi-inbox"></i>
      No transactions match your filter
    </td></tr>`;
  } else {
    tbody.innerHTML = list.map(r => {
      const isReversal = r.qtyReceived < 0 || r.kind === 'reversal';
      const isVoided   = !!r.reversedById || r.kind === 'voided';
      const cls = (isReversal ? 'reversal' : '') + (isVoided ? ' voided' : '');
      const qtyDisplay = isReversal
        ? `−${Math.abs(r.qtyReceived).toLocaleString()}`
        : r.qtyReceived.toLocaleString();
      const lotPallet = `
        <div class="meta-line">
          <b>${escHtml(r.lotBatch || '—')}</b>
          <span class="sep">·</span>
          ${escHtml(r.palletId || '—')}
        </div>
        <div class="meta-line" style="color: var(--text-muted);">Bin ${escHtml(r.binLocation || '—')}</div>
      `;
      const reversalLink = r.reversesReceiptId
        ? `<span class="reversal-of" data-jump="${escHtml(r.reversesReceiptId)}">↺ Reverses ${escHtml(r.reversesReceiptId.slice(0,8))}</span>`
        : (r.reversedById
          ? `<span class="reversal-of" data-jump="${escHtml(r.reversedById)}">↩ Reversed by ${escHtml(r.reversedById.slice(0,8))}</span>`
          : '');
      const actions = isReversal
        ? '<span style="color: var(--text-muted); font-family: \'Roboto Mono\', monospace; font-size: 10px;">REVERSAL</span>'
        : (isVoided
          ? '<span style="color: var(--text-muted); font-family: \'Roboto Mono\', monospace; font-size: 10px;">VOIDED</span>'
          : `<button class="btn btn-icon danger" data-act="cancel" data-id="${escHtml(r.id)}" title="Cancel this receipt"><i class="bi bi-arrow-counterclockwise"></i> Cancel</button>`);
      return `
        <tr class="${cls}" data-id="${escHtml(r.id)}">
          <td class="no-strike">
            <div class="actor-cell">
              <span class="actor-name" style="font-family: 'Roboto Mono', monospace; font-size: 12px;">${formatTime(r.receivedAt)}</span>
              <span class="actor-when">${escHtml(r.id.slice(0,8))}</span>
            </div>
          </td>
          <td class="no-strike">${actionPillHtml(r)}</td>
          <td>
            <a class="pull-link" data-jump-pull="${escHtml(r.pullNumber)}">${escHtml(r.pullNumber)}</a>
            <div class="pull-meta">${escHtml(r.warehouseCode)}</div>
          </td>
          <td>
            <div class="item-cell">
              <span class="item-code">${escHtml(r.itemCode)}</span>
              <span class="item-desc">${escHtml(r.itemDescription)}</span>
              ${reversalLink}
            </div>
          </td>
          <td class="col-po" title="${escHtml(r.vendorName || '')}">
            <b>${escHtml(r.poNumber || '—')}</b>${r.poLineNumber ? ` · L${escHtml(String(r.poLineNumber).padStart(2,'0'))}` : ''}
            ${r.vendorName ? `<span class="po-vendor">${escHtml(r.vendorName)}</span>` : ''}
          </td>
          <td class="num">${String(r.hourOfDay).padStart(2,'0')}:00</td>
          <td class="num" style="${isReversal ? 'color: var(--error);' : ''}">${qtyDisplay}</td>
          <td>${lotPallet}</td>
          <td><span class="qc-badge ${escHtml(r.qcStatus)}">${escHtml(r.qcStatus)}</span></td>
          <td>
            <div class="actor-cell">
              <span class="actor-name">${escHtml(r.receivedByName)}</span>
              ${r.note ? `<span class="actor-when" style="text-transform: none; letter-spacing: 0;">${escHtml(r.note)}</span>` : ''}
            </div>
          </td>
          <td class="actions-cell" style="text-align: right;">${actions}</td>
        </tr>
      `;
    }).join('');
  }
  renderStats(list);
}

function renderStats(list) {
  document.getElementById('s-total').textContent = list.length;
  const positives = list.filter(r => r.qtyReceived > 0);
  const negatives = list.filter(r => r.qtyReceived < 0);
  document.getElementById('s-receipts').textContent = positives.length;
  document.getElementById('s-reversals').textContent = negatives.length;
  const net = list.reduce((sum, r) => sum + r.qtyReceived, 0);
  document.getElementById('s-net').textContent = net.toLocaleString();
  const operators = new Set(list.map(r => r.receivedByName));
  document.getElementById('s-operators').textContent = operators.size;

  // Server returns Total separately from the page slice; surface it so the
  // user knows when filters narrowed the dataset.
  const more = currentTotal > list.length ? ` (of ${currentTotal} total)` : '';
  document.getElementById('result-count').innerHTML = `<b style="color: var(--text);">${list.length}</b>${more} records`;
  document.getElementById('footer-summary').textContent =
    list.length === 0 ? '—' :
    `${list.length} transactions · ${positives.length} receipts (+${positives.reduce((a,r) => a+r.qtyReceived, 0).toLocaleString()}) · ${negatives.length} reversals (${negatives.reduce((a,r) => a+r.qtyReceived, 0).toLocaleString()}) · net ${net.toLocaleString()}`;
}

function refreshOperators() {
  // §15 #11 will give us a real operator dropdown source. Until then, derive
  // names from the current result set so the dropdown is at least usable.
  const ops = [...new Set(currentRows.map(r => r.receivedByName).filter(Boolean))].sort();
  const sel = document.getElementById('f-operator');
  const cur = sel.value;
  sel.innerHTML = `<option value="all">All operators</option>` + ops.map(o => `<option value="${escHtml(o)}">${escHtml(o)}</option>`).join('');
  sel.value = ops.includes(cur) || cur === 'all' ? cur : 'all';
}

// §5b — client-side sort. Tiebreak: LineNumber asc, then ReceivedAt DESC
// (so the newest receipt within a PO·Line group ends up first).
function sortRowsByPo(rows, dir) {
  const mult = dir === 'desc' ? -1 : 1;
  const arr = rows.slice();
  arr.sort((a, b) => {
    const pa = a.poNumber || '';
    const pb = b.poNumber || '';
    if (pa !== pb) return pa.localeCompare(pb) * mult;
    const la = a.poLineNumber | 0;
    const lb = b.poLineNumber | 0;
    if (la !== lb) return (la - lb) * mult;
    // ReceivedAt tiebreak always DESC (most recent within group first), per spec.
    const ta = new Date(a.receivedAt).getTime() || 0;
    const tb = new Date(b.receivedAt).getTime() || 0;
    return tb - ta;
  });
  return arr;
}

/* ---------- Cancel flow ---------- */
let cancelTarget = null;

function openCancelModal(receiptId) {
  const r = currentRows.find(x => x.id === receiptId);
  if (!r) return;
  if (r.qtyReceived < 0) return showToast('Cannot cancel a reversal entry', '', 'danger');
  if (r.reversedById)    return showToast('This receipt is already voided', '', 'danger');

  cancelTarget = r;
  document.getElementById('c-id').textContent   = r.id;
  document.getElementById('c-when').textContent = formatFull(r.receivedAt);
  document.getElementById('c-item').textContent = r.itemCode + ' · ' + r.itemDescription;
  document.getElementById('c-qty').textContent  = '−' + r.qtyReceived.toLocaleString() + ' pcs';
  document.getElementById('c-pull').textContent = r.pullNumber + ' · ' + String(r.hourOfDay).padStart(2,'0') + ':00';
  document.getElementById('c-by').textContent   = r.receivedByName;
  document.getElementById('c-note').value = '';
  document.querySelectorAll('input[name="reason"]').forEach(rb => rb.checked = false);
  new bootstrap.Modal(document.getElementById('cancelModal')).show();
}

async function confirmCancel() {
  if (!cancelTarget) return;
  const reasonRadio = document.querySelector('input[name="reason"]:checked');
  if (!reasonRadio) return showToast('Pick a reason', 'Required to create reversal', 'danger');
  const reason = reasonRadio.value;
  const note   = document.getElementById('c-note').value.trim();
  const id = cancelTarget.id;

  const btn = document.getElementById('btn-confirm-cancel');
  btn.disabled = true;
  try {
    const resp = await fetch(`/api/receipts/${encodeURIComponent(id)}/cancel`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ reason, note: note || null }),
    });
    if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!resp.ok) {
      let title = `Cancel rejected (${resp.status})`;
      try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
      showToast('Cancel failed', title, 'danger');
      return;
    }
    bootstrap.Modal.getInstance(document.getElementById('cancelModal')).hide();
    cancelTarget = null;
    showToast('Reversal created', `${id.slice(0,8)} · cancelled`);
    await loadData();
  } catch (e) {
    console.error('cancel failed', e);
    showToast('Network error', 'Could not reach server', 'danger');
  } finally {
    btn.disabled = false;
  }
}

/* ---------- Export — uses what's currently rendered ---------- */
function exportToExcel() {
  try {
    if (typeof XLSX === 'undefined') return showToast('Export failed', 'Library not loaded', 'danger');
    const list = currentRows;
    if (list.length === 0) return showToast('Nothing to export', '', 'danger');

    const now = new Date();
    const wb = XLSX.utils.book_new();

    const positives = list.filter(r => r.qtyReceived > 0);
    const negatives = list.filter(r => r.qtyReceived < 0);
    const net = list.reduce((a,r) => a + r.qtyReceived, 0);
    const meta = [
      { Field: 'Report',         Value: 'Receipt Transactions Journal' },
      { Field: 'Exported At',    Value: now.toLocaleString('en-GB') },
      { Field: 'Total',          Value: list.length },
      { Field: 'Server Total',   Value: currentTotal },
      { Field: 'Receipts',       Value: positives.length },
      { Field: 'Reversals',      Value: negatives.length },
      { Field: 'Net Units',      Value: net },
    ];
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(meta), 'Header');

    const rows = list.map(r => ({
      'Receipt ID':    r.id,
      'Type':          r.qtyReceived < 0 ? 'Reversal' : (r.reversedById ? 'Voided' : 'Receipt'),
      'When':          formatFull(r.receivedAt),
      'Pull':          r.pullNumber,
      'Warehouse':     r.warehouseCode,
      'Item Code':     r.itemCode,
      'Description':   r.itemDescription,
      'PO':            r.poNumber || '',
      'PO Line':       r.poLineNumber || '',
      'Vendor':        r.vendorName || '',
      'Hour':          String(r.hourOfDay).padStart(2,'0') + ':00',
      'Quantity':      r.qtyReceived,
      'Lot/Batch':     r.lotBatch,
      'Pallet':        r.palletId,
      'Bin':           r.binLocation,
      'QC':            r.qcStatus,
      'Note':          r.note,
      'Operator':      r.receivedByName,
      'Reverses':      r.reversesReceiptId || '',
      'Reversed By':   r.reversedById || '',
      'Reason':        r.cancelReason || '',
    }));
    const ws = XLSX.utils.json_to_sheet(rows);
    ws['!cols'] = [
      {wch:36},{wch:10},{wch:18},{wch:10},{wch:8},{wch:18},{wch:32},
      {wch:14},{wch:7},{wch:22},
      {wch:6},{wch:9},{wch:16},{wch:12},{wch:10},{wch:10},{wch:32},{wch:14},{wch:36},{wch:36},{wch:14}
    ];
    XLSX.utils.book_append_sheet(wb, ws, 'Transactions');

    XLSX.writeFile(wb, `transactions_${now.toISOString().slice(0,10)}.xlsx`);
    showToast('Export complete', `${list.length} transactions`);
  } catch (e) {
    console.error(e);
    showToast('Export failed', e.message, 'danger');
  }
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

/* ---------- Events ---------- */
// Debounce the search input so we don't spam the server on every keystroke.
let searchDebounce = null;
function onFilterChange() {
  clearTimeout(searchDebounce);
  searchDebounce = setTimeout(loadData, 200);
}

document.getElementById('f-search').addEventListener('input', onFilterChange);
['f-warehouse','f-action','f-operator'].forEach(id => {
  const el = document.getElementById(id);
  if (el) el.addEventListener('change', loadData);
});

// Date Range gets its own handler — toggles the custom-range row + reloads.
document.getElementById('f-date').addEventListener('change', (e) => {
  const isCustom = e.target.value === 'custom';
  document.getElementById('custom-date-row').classList.toggle('visible', isCustom);
  // For preset ranges, fetch immediately. For custom, wait for Apply so the
  // operator picks both dates before firing.
  if (!isCustom) loadData();
});

document.getElementById('date-apply').addEventListener('click', () => {
  const from = document.getElementById('date-from').value;
  const to   = document.getElementById('date-to').value;
  if (!from || !to) { showToast('Pick both dates', 'From and To required', 'danger'); return; }
  if (from > to)    { showToast('Invalid range', '"From" must be earlier than "To"', 'danger'); return; }
  loadData();
});

document.getElementById('date-clear').addEventListener('click', () => {
  document.getElementById('date-from').value = '';
  document.getElementById('date-to').value = '';
  loadData();
});

document.getElementById('btn-clear-filters').addEventListener('click', () => {
  document.getElementById('f-search').value = '';
  document.getElementById('f-warehouse').value = 'all';
  document.getElementById('f-action').value = 'all';
  document.getElementById('f-date').value = 'last_2_days';
  document.getElementById('f-operator').value = 'all';
  document.getElementById('date-from').value = '';
  document.getElementById('date-to').value = '';
  document.getElementById('custom-date-row').classList.remove('visible');
  // Also clear sort + hour banner — both are part of the filter set even though they're not dropdowns.
  sortBy = null; sortDir = 'asc';
  document.querySelectorAll('.data-table th.sortable').forEach(th => th.classList.remove('sort-asc','sort-desc'));
  hourFilter = null;
  document.getElementById('hour-filter-banner').style.display = 'none';
  loadData();
});

// §5b — PO column sort. Client-side on the currently rendered page; no refetch.
document.querySelectorAll('.data-table th.sortable').forEach(th => {
  th.addEventListener('click', () => {
    const key = th.dataset.sort;
    if (sortBy === key) {
      sortDir = sortDir === 'asc' ? 'desc' : 'asc';
    } else {
      sortBy = key;
      sortDir = 'asc';
    }
    document.querySelectorAll('.data-table th.sortable').forEach(h => h.classList.remove('sort-asc','sort-desc'));
    th.classList.add(sortDir === 'asc' ? 'sort-asc' : 'sort-desc');
    render();
  });
});

document.getElementById('btn-refresh').addEventListener('click', () => {
  loadData();
  showToast('Refreshed');
});

document.getElementById('btn-export').addEventListener('click', exportToExcel);
document.getElementById('btn-confirm-cancel').addEventListener('click', confirmCancel);

document.addEventListener('click', (e) => {
  const cancelBtn = e.target.closest('[data-act="cancel"]');
  if (cancelBtn) { openCancelModal(cancelBtn.getAttribute('data-id')); return; }

  const jump = e.target.closest('[data-jump]');
  if (jump) {
    const targetId = jump.getAttribute('data-jump');
    const row = document.querySelector(`tr[data-id="${targetId}"]`);
    if (row) {
      row.scrollIntoView({ behavior: 'smooth', block: 'center' });
      row.style.transition = 'background 0.3s ease';
      const orig = row.style.background;
      row.style.background = 'var(--accent-bg)';
      setTimeout(() => { row.style.background = orig; }, 1200);
    }
    return;
  }

  const pullLink = e.target.closest('[data-jump-pull]');
  if (pullLink) {
    const pullId = pullLink.getAttribute('data-jump-pull');
    window.location.href = `/Receiving?pull=${encodeURIComponent(pullId)}&from=transactions`;
  }
});

document.getElementById('hour-filter-clear').addEventListener('click', () => {
  hourFilter = null;
  document.getElementById('hour-filter-banner').style.display = 'none';
  loadData();
});

/* ---------- Startup ---------- */
applyUrlFiltersToUi();
loadData();
