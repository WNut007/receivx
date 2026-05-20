/* ============================================================================
 * dashboard.js — Pull Controller (Kanban view)
 * Ports the mockup interaction model to a fetch-backed data path:
 *   - Initial load: GET /api/pulls (server scopes by whRole)
 *   - Filter changes refetch with date/status/q in the query string
 *   - Drawer is still client-rendered from the cached row
 *   - Launch hands off to /Receiving?pull={n}&warehouse={c}&from=controller
 * The rest (theme, kanban DOM, drawer markup, Excel export) is unchanged.
 * ========================================================================== */
(function () {
  'use strict';

  // ============ THEME ============
  // Owned globally by app-nav.js — this just listens to the inline swatches
  // in the topbar so they stay in sync if a user clicks one here instead.
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
  applyTheme((function () { try { return localStorage.getItem(THEME_KEY) || 'light'; } catch (e) { return 'light'; } })());

  // ============ STATE ============
  const COLUMNS = [
    { key: 'pending',        label: 'Pending' },
    { key: 'in_progress',    label: 'In Progress' },
    { key: 'fully_received', label: 'Fully Received' },
    { key: 'closed',         label: 'Closed' },
  ];
  let pulls = [];                // current server result, adapted to mockup shape
  let selectedPullId = null;
  let customRange = null;        // { from: 'YYYY-MM-DD', to: 'YYYY-MM-DD' }
  let inflight = 0;

  // ============ DATE GROUP CLASSIFIER ============
  // Same buckets the date-filter dropdown uses. Computed against "today" so
  // the kanban groups by recency, not calendar week.
  function classifyDateGroup(iso) {
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const d = new Date(iso + 'T00:00:00');
    const dayMs = 86400000;
    const diffDays = Math.round((today - d) / dayMs);
    if (diffDays === 0)  return 'today';
    if (diffDays === 1)  return 'yesterday';
    if (diffDays <= 6)   return 'this_week';
    if (diffDays <= 13)  return 'last_week';
    return 'older';
  }

  // Format an ISO timestamp as "HH:mm · DD MMM".
  function fmtTimestamp(iso) {
    if (!iso) return null;
    const d = new Date(iso);
    if (isNaN(d.getTime())) return null;
    const time = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    const date = d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' });
    return `${time} · ${date}`;
  }

  // "5h 30m" / "1d 4h" — rough elapsed window.
  function fmtElapsed(fromIso, toIso) {
    if (!fromIso) return null;
    const from = new Date(fromIso);
    const to = toIso ? new Date(toIso) : new Date();
    if (isNaN(from.getTime())) return null;
    let mins = Math.max(0, Math.round((to - from) / 60000));
    const days = Math.floor(mins / 1440); mins -= days * 1440;
    const hours = Math.floor(mins / 60); mins -= hours * 60;
    if (days > 0) return `${days}d ${hours}h`;
    if (hours > 0) return `${hours}h ${mins}m`;
    return `${mins}m`;
  }

  // Server PullSummary → mockup pull shape so the existing render code stays put.
  function adapt(s) {
    const iso = s.pullDate.split('T')[0];
    const d = new Date(iso + 'T00:00:00');
    const dateStr = d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
    const tags = s.notes ? s.notes.split(',').map(t => t.trim()).filter(Boolean) : [];
    const operator = s.createdByName || '—';
    const elapsed = s.status === 'closed'
      ? fmtElapsed(s.firstReceiptAt, s.closedAt)
      : fmtElapsed(s.firstReceiptAt, null);
    const lastActivity = s.status === 'closed' && s.closedByName
      ? `Closed by ${s.closedByName} · ${fmtTimestamp(s.closedAt)?.split(' · ')[0] || '—'}`
      : fmtTimestamp(s.lastActivityAt);
    return {
      pullId:        s.id,            // GUID — used for drawer + handoff
      id:            s.pullNumber,
      date:          dateStr,
      dateISO:       iso,
      dateGroup:     classifyDateGroup(iso),
      warehouse:     s.warehouseCode,
      whName:        s.warehouseName,
      status:        s.status,
      itemCount:     s.itemCount,
      canceled:      s.canceledCount,
      newCount:      s.newCount,
      expected:      s.totalExpected,
      received:      s.totalReceived,
      windows:       s.windowsTotal,
      pendingWindows:s.windowsPending,
      firstReceipt:  fmtTimestamp(s.firstReceiptAt),
      lastActivity:  lastActivity,
      elapsed:       elapsed,
      operator:      operator,
      operatorCount: 1,               // server doesn't track multi-operator yet
      eta:           s.eta || '—',
      tags:          tags,
      isReopened:    s.isReopened,
    };
  }

  // ============ FETCH ============
  function currentWhFilter()   { return document.getElementById('wh-filter').value; }
  function currentDateFilter() { return document.getElementById('date-filter').value; }
  function currentSearch()     { return document.getElementById('search-input').value.trim(); }

  async function loadPulls() {
    const myId = ++inflight;
    const params = new URLSearchParams();
    const wh = currentWhFilter();
    if (wh && wh !== 'all') params.set('warehouse', wh);  // server treats as code → ignored unless wired
    const q = currentSearch();
    if (q) params.set('q', q);

    // Date filter — only "custom" sends server-side from/to; the named buckets
    // (today/yesterday/this_week/last_week) are computed client-side so a user
    // typing in search doesn't blow away last-week pulls server-side.
    const d = currentDateFilter();
    if (d === 'custom' && customRange) {
      params.set('dateFrom', customRange.from);
      params.set('dateTo',   customRange.to);
    }

    try {
      const r = await fetch('/api/pulls?' + params.toString(), { credentials: 'same-origin' });
      if (myId !== inflight) return;  // stale
      if (r.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!r.ok) throw new Error('Pulls fetch failed: ' + r.status);
      const data = await r.json();
      pulls = data.map(adapt);
      render();
    } catch (err) {
      console.error(err);
      showToast('Could not load pulls', err.message || 'Network error');
    }
  }

  // ============ FILTERS (client-side, after fetch) ============
  function pullPasses(p) {
    if (currentWhFilter() !== 'all' && p.warehouse !== currentWhFilter()) return false;
    const d = currentDateFilter();
    if (d !== 'all') {
      if (d === 'custom') {
        if (!customRange) return true;
        if (p.dateISO < customRange.from || p.dateISO > customRange.to) return false;
      } else if (p.dateGroup !== d) return false;
    }
    const q = currentSearch().toLowerCase();
    if (q) {
      const h = `${p.id} ${p.warehouse} ${p.whName} ${p.operator}`.toLowerCase();
      if (!h.includes(q)) return false;
    }
    return true;
  }

  // ============ KANBAN RENDER ============
  function render() {
    const board = document.getElementById('kanban');
    board.innerHTML = '';
    const filtered = pulls.filter(pullPasses);

    COLUMNS.forEach(col => {
      const colItems = filtered.filter(p => p.status === col.key);
      const column = document.createElement('div');
      column.className = 'column';
      column.innerHTML = `
        <div class="column-head">
          <div class="column-title">
            <span class="column-dot ${col.key}"></span>
            <span class="column-name">${col.label}</span>
          </div>
          <span class="column-count">${colItems.length}</span>
        </div>
        <div class="column-body"></div>
      `;
      board.appendChild(column);
      const body = column.querySelector('.column-body');
      if (colItems.length === 0) {
        body.innerHTML = `<div class="empty-col">No pulls</div>`;
      } else {
        colItems.forEach(p => body.appendChild(renderCard(p)));
      }
    });

    updateSummary(filtered);
  }

  function renderCard(p) {
    const pct = p.expected > 0 ? Math.round((p.received / p.expected) * 100) : 0;
    const card = document.createElement('div');
    card.className = `card-pull status-${p.status}` + (p.pullId === selectedPullId ? ' selected' : '');
    card.dataset.id = p.pullId;

    const tagsHtml = p.tags.map(t => `<span class="tag-pill ${t}">${t}</span>`).join('');
    const lockedIcon = p.status === 'closed'
      ? `<svg class="card-locked" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 1 1 8 0v4"/></svg>`
      : '';
    const progressLabel = p.status === 'pending' ? 'Not started'
                       : p.status === 'closed' ? 'Closed'
                       : p.status === 'fully_received' ? 'Ready to close'
                       : 'In progress';

    card.innerHTML = `
      ${lockedIcon}
      <div class="card-head">
        <span class="card-id">${p.id}</span>
        <span class="card-date">${p.date.split(' ').slice(0,2).join(' ')}</span>
      </div>
      <div class="card-wh">${p.warehouse} · ${p.whName}</div>
      <div class="card-progress">
        <div class="card-progress-head">
          <span>${progressLabel}</span>
          <span class="pct">${pct}%</span>
        </div>
        <div class="card-progress-track">
          <div class="card-progress-fill" style="width: ${pct}%"></div>
        </div>
      </div>
      <div class="card-meta">
        <div class="card-meta-item">
          <span class="card-meta-label">Items</span>
          <span class="card-meta-value">${p.itemCount} SKU${p.itemCount===1?'':'s'}</span>
        </div>
        <div class="card-meta-item">
          <span class="card-meta-label">Units</span>
          <span class="card-meta-value">${p.received.toLocaleString()} / ${p.expected.toLocaleString()}</span>
        </div>
        <div class="card-meta-item">
          <span class="card-meta-label">${p.status === 'closed' ? 'Duration' : p.lastActivity ? 'Last activity' : 'ETA'}</span>
          <span class="card-meta-value dim">${
            p.status === 'closed' ? (p.elapsed || '—') :
            p.lastActivity ? p.lastActivity.split(' · ')[0] : p.eta
          }</span>
        </div>
        <div class="card-meta-item">
          <span class="card-meta-label">${p.elapsed ? 'Elapsed' : 'Assigned'}</span>
          <span class="card-meta-value dim">${p.elapsed || p.operator.split(' ').slice(0,2).join(' ')}</span>
        </div>
      </div>
      ${tagsHtml ? `<div class="card-tags">${tagsHtml}</div>` : ''}
    `;
    card.addEventListener('click', () => openDrawer(p.pullId));
    return card;
  }

  function updateSummary(filtered) {
    document.getElementById('sum-total').textContent = filtered.length;
    document.getElementById('sum-inprogress').textContent = filtered.filter(p => p.status === 'in_progress').length;
    document.getElementById('sum-ready').textContent = filtered.filter(p => p.status === 'fully_received').length;
    const totalItems = filtered.reduce((a, p) => a + p.itemCount, 0);
    const totalExp = filtered.reduce((a, p) => a + p.expected, 0);
    const totalRec = filtered.reduce((a, p) => a + p.received, 0);
    document.getElementById('sum-items').innerHTML = `${totalItems} <small>SKUs</small>`;
    document.getElementById('sum-thru').innerHTML = `${totalRec.toLocaleString()} <small>units</small>`;
    const pct = totalExp > 0 ? ((totalRec / totalExp) * 100).toFixed(1) : 0;
    document.getElementById('sum-thru-sub').textContent = `${pct}% of expected`;
  }

  // ============ DRAWER ============
  const drawerEl = document.getElementById('detailDrawer');
  const drawer = new bootstrap.Offcanvas(drawerEl);

  function openDrawer(pullGuid) {
    const p = pulls.find(x => x.pullId === pullGuid);
    if (!p) return;
    selectedPullId = pullGuid;

    document.querySelectorAll('.card-pull').forEach(c => {
      c.classList.toggle('selected', c.dataset.id === pullGuid);
    });

    const pct = p.expected > 0 ? Math.round((p.received / p.expected) * 100) : 0;
    const outstanding = Math.max(0, p.expected - p.received);

    const eyebrowMap = {
      pending: 'Awaiting Start',
      in_progress: 'In Progress',
      fully_received: 'Ready to Close',
      closed: 'Closed & Locked'
    };
    document.getElementById('d-eyebrow').textContent = eyebrowMap[p.status] + ' · ' + p.date;
    document.getElementById('d-title').textContent = p.id;
    document.getElementById('d-subtitle').textContent = `${p.warehouse} · ${p.whName} · ${p.date}`;

    const block = document.getElementById('d-progress-block');
    block.className = 'progress-block status-' + p.status;
    document.getElementById('d-pct').textContent = pct;
    const statusLabel = p.status.replace('_', ' ').replace(/\b\w/g, c => c.toUpperCase());
    const sp = document.getElementById('d-status-pill');
    sp.className = 'progress-status-pill ' + p.status;
    sp.textContent = statusLabel;
    const fill = document.getElementById('d-progress-fill');
    fill.className = 'progress-fill-large ' + p.status;
    fill.style.width = pct + '%';
    document.getElementById('d-started').textContent = p.firstReceipt ? p.firstReceipt.split(' · ')[0] : '—';
    document.getElementById('d-eta').textContent = p.eta;

    document.getElementById('d-items').innerHTML = `${p.itemCount} <small>SKUs</small>`;
    document.getElementById('d-items-sub').textContent = `${p.canceled} canceled · ${p.newCount} new`;
    document.getElementById('d-expected').innerHTML = `${p.expected.toLocaleString()} <small>units</small>`;
    document.getElementById('d-expected-sub').textContent = `across ${p.windows} windows`;
    document.getElementById('d-received').innerHTML = `${p.received.toLocaleString()} <small>units</small>`;
    document.getElementById('d-received-sub').textContent = `${pct}% of expected`;
    document.getElementById('d-outstanding').innerHTML = `${outstanding.toLocaleString()} <small>units</small>`;
    document.getElementById('d-outstanding-sub').textContent = `${p.pendingWindows} window${p.pendingWindows===1?'':'s'} pending`;

    document.getElementById('d-first').textContent = p.firstReceipt || 'Not started yet';
    document.getElementById('d-last').textContent = p.lastActivity || 'No activity yet';
    document.getElementById('d-elapsed').textContent = p.elapsed
      ? `${p.elapsed} · ${p.status === 'closed' ? 'closed' : 'in progress'}`
      : 'Not started';
    document.getElementById('d-operator').textContent = p.operator;

    const launchBtn = document.getElementById('d-launch');
    if (p.status === 'closed') {
      launchBtn.innerHTML = `<i class="bi bi-eye me-1"></i> View (read-only)`;
    } else {
      launchBtn.innerHTML = `<i class="bi bi-box-arrow-up-right me-1"></i> Open in Receiving v3.2`;
    }

    drawer.show();
  }

  drawerEl.addEventListener('hidden.bs.offcanvas', () => {
    selectedPullId = null;
    document.querySelectorAll('.card-pull.selected').forEach(c => c.classList.remove('selected'));
  });

  // ============ LAUNCH ============
  document.getElementById('d-launch').addEventListener('click', launchReceiving);
  function launchReceiving() {
    if (!selectedPullId) return;
    const p = pulls.find(x => x.pullId === selectedPullId);
    if (!p) return;
    showToast('Launching Receiving v3.2', `${p.id} · ${p.warehouse}`);
    const target = `/Receiving?pull=${encodeURIComponent(p.id)}&warehouse=${encodeURIComponent(p.warehouse)}&from=controller`;
    setTimeout(() => { window.location.href = target; }, 450);
  }

  // ============ TOAST ============
  function showToast(msg, sub) {
    const t = document.getElementById('toast');
    document.getElementById('toast-msg').textContent = msg;
    document.getElementById('toast-sub').textContent = sub;
    t.classList.add('show');
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => t.classList.remove('show'), 2400);
  }

  // ============ EXPORT TO EXCEL ============
  // Identical to the mockup — operates on the in-memory filtered list.
  function exportToExcel() {
    try {
      if (typeof XLSX === 'undefined') {
        showToast('Export failed', 'Excel library not loaded');
        return;
      }
      const filtered = pulls.filter(pullPasses);
      if (filtered.length === 0) {
        showToast('Nothing to export', 'Adjust filters and try again');
        return;
      }
      const now = new Date();
      const stamp = now.toISOString().slice(0, 10);
      const wb = XLSX.utils.book_new();
      const statusLabels = { pending: 'Pending', in_progress: 'In Progress', fully_received: 'Fully Received', closed: 'Closed' };
      const rows = filtered.map(p => {
        const pct = p.expected > 0 ? Math.round((p.received / p.expected) * 100) : 0;
        return {
          'Pull #': p.id,
          'Date': p.date,
          'Warehouse': p.warehouse,
          'Warehouse Name': p.whName,
          'Status': statusLabels[p.status] || p.status,
          'Items (SKUs)': p.itemCount,
          'Canceled Items': p.canceled,
          'New Items': p.newCount,
          'Expected (units)': p.expected,
          'Received (units)': p.received,
          'Outstanding': Math.max(0, p.expected - p.received),
          'Progress %': pct,
          'Windows': p.windows,
          'Pending Windows': p.pendingWindows,
          'First Receipt': p.firstReceipt || '—',
          'Last Activity': p.lastActivity || '—',
          'Elapsed': p.elapsed || '—',
          'ETA': p.eta,
          'Operator': p.operator,
          'Tags': (p.tags || []).join(', '),
        };
      });
      const ws = XLSX.utils.json_to_sheet(rows);
      XLSX.utils.book_append_sheet(wb, ws, 'Pulls');
      XLSX.writeFile(wb, `pull-controller_${stamp}.xlsx`);
      showToast('Export complete', `${filtered.length} pull${filtered.length===1?'':'s'}`);
    } catch (err) {
      console.error(err);
      showToast('Export failed', err.message || 'Unknown error');
    }
  }
  document.getElementById('btn-export').addEventListener('click', exportToExcel);

  // ============ KEYBOARD ============
  document.addEventListener('keydown', (e) => {
    if (drawerEl.classList.contains('show') && e.key === 'Enter') launchReceiving();
  });

  // ============ FILTER LISTENERS ============
  document.getElementById('wh-filter').addEventListener('change', render);
  // Debounce search so we don't refilter on every keystroke (but no refetch
  // since server already returned everything for this date range).
  let searchTimer = null;
  document.getElementById('search-input').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(render, 120);
  });

  document.getElementById('date-filter').addEventListener('change', (e) => {
    const row = document.getElementById('custom-date-row');
    row.classList.toggle('visible', e.target.value === 'custom');
    if (e.target.value !== 'custom') customRange = null;
    if (e.target.value === 'custom' && customRange) loadPulls();
    else render();
  });

  document.getElementById('date-apply').addEventListener('click', () => {
    const from = document.getElementById('date-from').value;
    const to = document.getElementById('date-to').value;
    if (!from || !to) { showToast('Pick both dates', 'From and To required'); return; }
    if (from > to)   { showToast('Invalid range', '"From" must be earlier than "To"'); return; }
    customRange = { from, to };
    loadPulls();
    showToast('Range applied', `${from} → ${to}`);
  });

  document.getElementById('date-clear').addEventListener('click', () => {
    document.getElementById('date-from').value = '';
    document.getElementById('date-to').value = '';
    customRange = null;
    loadPulls();
  });

  // ============ INIT ============
  // Populate the user chip from cached session (set by login + app-nav).
  (function populateUserChip() {
    try {
      const s = JSON.parse(localStorage.getItem('auth.session') || 'null');
      if (s) {
        document.querySelector('.user-chip > span:first-child').textContent = s.name || 'Guest';
        document.querySelector('.user-chip .avatar').textContent = s.initials || '??';
      }
    } catch (e) {}
  })();

  // Replace the hardcoded WH options with the live active set. The current
  // selection (or "all") is preserved if still present after the fetch.
  async function populateWhFilter() {
    const sel = document.getElementById('wh-filter');
    if (!sel) return;
    const prev = sel.value;
    try {
      const r = await fetch('/api/warehouses?status=active', {
        headers: { 'Accept': 'application/json' },
      });
      if (!r.ok) return;
      const rows = await r.json();
      const opts = ['<option value="all">All warehouses</option>'];
      for (const w of rows) {
        const label = `${w.code} · ${w.name}`;
        opts.push(`<option value="${w.code}">${label}</option>`);
      }
      sel.innerHTML = opts.join('');
      const found = Array.from(sel.options).some(o => o.value === prev);
      sel.value = found ? prev : 'all';
    } catch (e) { /* keep the static fallback options */ }
  }

  populateWhFilter().then(loadPulls);
})();
