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
      warehouseId:   s.warehouseId,
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
      etaRaw:        s.eta || '',
      notesRaw:      s.notes || '',
      tags:          tags,
      isReopened:    s.isReopened,
      // §3.5 — mirror of Pulls.LockPoByPull; surfaces in card + drawer + modal
      lockPoByPull:  !!s.lockPoByPull,
      // v2.1 Hour Cap — surfaces in drawer badge + modal echo + filter (default true).
      lockHourCap:   s.lockHourCap === undefined ? true : !!s.lockHourCap,
      // v2.x — close authorization (used by renderCloseAuth on closed pulls only).
      closedByName:  s.closedByName || null,
      closedByRole:  s.closedByRole || null,
      signatureSvg:  s.signatureSvg || null,
      // v2.x Phase 7.1 — vendor invoice / delivery-batch ID. Editable post-create.
      referenceNumber: s.referenceNumber || null,
    };
  }

  // ============ FETCH ============
  function currentWhFilter()   { return document.getElementById('wh-filter').value; }
  function currentDateFilter() { return document.getElementById('date-filter').value; }
  function currentLockFilter() { return document.getElementById('lock-filter')?.value || 'all'; }
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
      } else if (d === 'last_2_days') {
        // Calendar-day semantics: today OR yesterday. Matches the warehouse
        // mental model ("วันนี้กับเมื่อวาน") — NOT rolling 48 hours, which
        // would clip into day-before-yesterday and confuse operators.
        if (p.dateGroup !== 'today' && p.dateGroup !== 'yesterday') return false;
      } else if (p.dateGroup !== d) return false;
    }
    const lock = currentLockFilter();
    if (lock === 'locked'   && !p.lockPoByPull) return false;
    if (lock === 'unlocked' &&  p.lockPoByPull) return false;
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
          <span class="column-count-badge status-${col.key.replace(/_/g, '-')}">${colItems.length}</span>
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

    const lockBadge = p.lockPoByPull
      ? `<span class="lock-badge" title="Pull-locked PO allocation (§3.5)"><i class="bi bi-lock-fill"></i></span>`
      : '';
    card.innerHTML = `
      ${lockedIcon}
      <div class="card-head">
        <span class="card-id">${p.id}${lockBadge}</span>
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

  // Paints the drawer header / progress / Item Summary / Timeline / strict-mode
  // pills / launch button from a pull object (the adapted in-memory shape, not
  // the raw API response). Factored out of openDrawer so refreshPullDetailDrawer
  // can re-render the same surface after a mutation without re-running drawer.show().
  function renderDrawerSections(p) {
    if (!p) return;
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

    // §3.5 — lock mode pill + linked POs
    const modeEl = document.getElementById('d-lock-mode');
    if (modeEl) {
      modeEl.innerHTML = p.lockPoByPull
        ? `<span class="lock-mode-pill locked"><i class="bi bi-lock-fill"></i> Pull-locked</span>`
        : `<span class="lock-mode-pill unlocked"><i class="bi bi-globe"></i> Warehouse-wide</span>`;
    }
    // v2.1 Hour Cap — strict (green) / loose (amber) pill below the PO-allocation pill.
    const hcapEl = document.getElementById('d-hcap-mode');
    if (hcapEl) {
      hcapEl.innerHTML = p.lockHourCap
        ? `<span class="lock-mode-pill hcap-strict"><i class="bi bi-clock-fill"></i> Strict</span>`
        : `<span class="lock-mode-pill hcap-loose"><i class="bi bi-clock"></i> Loose (over-receive allowed)</span>`;
    }
    const linkedLinkEl = document.getElementById('d-linked-pos-link');
    const linkedEl = document.getElementById('d-linked-pos');
    if (linkedEl && linkedLinkEl) {
      if (p.lockPoByPull) {
        linkedEl.textContent = 'Loading…';
        linkedLinkEl.href = `/Pos?pullId=${encodeURIComponent(p.pullId)}`;
        linkedLinkEl.style.pointerEvents = 'auto';
        // Fetch linked-POs count for this pull; counted client-side.
        fetch('/api/pos?warehouseId=' + encodeURIComponent(p.warehouseId || ''))
          .then(r => r.ok ? r.json() : [])
          .then(rows => {
            const n = rows.filter(r => r.pullId === p.pullId).length;
            linkedEl.textContent = `${n} PO${n === 1 ? '' : 's'} linked`;
          })
          .catch(() => { linkedEl.textContent = '—'; });
      } else {
        linkedEl.textContent = 'n/a (cross-pull pool)';
        linkedLinkEl.removeAttribute('href');
        linkedLinkEl.style.pointerEvents = 'none';
      }
    }

    const launchBtn = document.getElementById('d-launch');
    if (p.status === 'closed') {
      launchBtn.innerHTML = `<i class="bi bi-eye me-1"></i> View (read-only)`;
    } else {
      launchBtn.innerHTML = `<i class="bi bi-box-arrow-up-right me-1"></i> Open in Receiving v3.2`;
    }

    // v2.x — close authorization section (rendered only when status === 'closed').
    renderCloseAuth(p);
  }

  // Renders the drawer's CLOSE AUTHORIZATION section from the pull's
  // signature + closer name/role/timestamp. Hidden entirely on open pulls so
  // the active workflow drawer stays uncluttered. Reopened pulls (status !==
  // 'closed' but signatureSvg still set per §7.5) also hide the section —
  // the badge is past tense; if the pull is back in motion the close-auth
  // history is no longer the load-bearing signal.
  function renderCloseAuth(p) {
    const section = document.getElementById('d-close-auth');
    if (!section) return;
    if (p.status !== 'closed') {
      section.style.display = 'none';
      return;
    }
    section.style.display = '';

    document.getElementById('d-closer-name').textContent = p.closedByName || '(unknown)';
    document.getElementById('d-closer-role').textContent = p.closedByRole || '';

    // p.firstReceipt comes pre-formatted by adapt(); for closed-at, use the raw
    // server timestamp through the same fmtTimestamp helper if available, else
    // fall back to lastActivity (which adapt() sets to "Closed by X · DATE"
    // for closed pulls — that's already the right shape for the line).
    document.getElementById('d-close-time').textContent =
      p.lastActivity && p.status === 'closed' ? p.lastActivity : '—';

    const canvas = document.getElementById('d-signature-canvas');
    const btnDownload = document.getElementById('d-download-sig');
    canvas.innerHTML = '';
    const sig = (p.signatureSvg || '').trim();
    if (sig) {
      // Two storage shapes are tolerated:
      //   1. Inline <svg>...</svg> markup (what new closes write)
      //   2. data:image/* URL (legacy / canvas-toDataURL closes)
      // Anything else falls into the invalid bucket so a corrupt row doesn't
      // crash the drawer.
      if (sig.startsWith('<svg')) {
        canvas.innerHTML = sig;
      } else if (sig.startsWith('data:image/')) {
        const img = new Image();
        img.alt = 'Close signature';
        img.src = sig;
        canvas.appendChild(img);
      } else {
        canvas.innerHTML = '<span class="muted">Invalid signature data</span>';
      }
      btnDownload.disabled = false;
      btnDownload.onclick = () => downloadSignaturePng(sig, p.id);
    } else {
      canvas.innerHTML = '<span class="muted">No signature on file</span>';
      btnDownload.disabled = true;
      btnDownload.onclick = null;
    }
  }

  // SVG / data-URL → PNG via off-screen canvas. White background filled
  // before drawImage so transparency renders correctly when the operator
  // opens the file in a generic viewer. Uses object URLs so memory is
  // released as soon as the click finishes.
  async function downloadSignaturePng(sigSource, pullNumber) {
    const isData = sigSource.startsWith('data:image/');
    const blob = isData ? null : new Blob([sigSource], { type: 'image/svg+xml' });
    const url = isData ? sigSource : URL.createObjectURL(blob);
    const img = new Image();
    img.onload = () => {
      const w = img.width || 400;
      const h = img.height || 120;
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);
      canvas.toBlob((png) => {
        const link = document.createElement('a');
        const href = URL.createObjectURL(png);
        link.href = href;
        link.download = `${pullNumber || 'pull'}-signature.png`;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(href);
      }, 'image/png');
      if (!isData) URL.revokeObjectURL(url);
    };
    img.onerror = () => {
      showToast('Download failed', 'Could not rasterize signature', 'error');
      if (!isData) URL.revokeObjectURL(url);
    };
    img.src = url;
  }

  function openDrawer(pullGuid) {
    const p = pulls.find(x => x.pullId === pullGuid);
    if (!p) return;
    selectedPullId = pullGuid;

    document.querySelectorAll('.card-pull').forEach(c => {
      c.classList.toggle('selected', c.dataset.id === pullGuid);
    });

    renderDrawerSections(p);
    drawer.show();

    // v2.1 Phase 6.3 — lazy-load the items grid. Fire-and-forget; render
    // updates the DOM when it lands so the drawer doesn't block on it.
    loadItemsForDrawer(pullGuid).catch(() => {
      const tbody = document.getElementById('d-items-tbody');
      const empty = document.getElementById('d-items-empty');
      if (tbody) tbody.innerHTML = '';
      if (empty) {
        empty.textContent = 'Failed to load items.';
        empty.classList.remove('d-none');
      }
    });
  }

  // Post-mutation refresh — fetches the full PullDetail (header summary +
  // items in one round-trip), updates the in-memory pulls[] cache so a later
  // close+reopen of the drawer also shows fresh totals, then re-renders both
  // the drawer sections and the items table. Called from every mutation
  // success handler (saveAddItem / saveEditItem / deleteItem /
  // refreshWindowsModal) so the operator never sees stale summary cards
  // after a CRUD action.
  async function refreshPullDetailDrawer(pullGuid) {
    if (!pullGuid) return;
    try {
      const r = await fetch('/api/pulls/' + encodeURIComponent(pullGuid));
      if (!r.ok) {
        // Best-effort fall back to items-only refresh so the table at least
        // reflects the mutation even if the summary call failed.
        await loadItemsForDrawer(pullGuid);
        return;
      }
      const detail = await r.json();
      const fresh = adapt(detail);
      const idx = pulls.findIndex(x => x.pullId === fresh.pullId);
      if (idx >= 0) pulls[idx] = fresh; else pulls.push(fresh);
      renderDrawerSections(fresh);
      drawerItems = detail.items || [];
      drawerPullIdForItems = pullGuid;
      renderItemsTable();
    } catch (e) {
      console.error('refreshPullDetailDrawer failed', e);
      try { await loadItemsForDrawer(pullGuid); } catch {}
    }
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

  // ============ §3.5 / §7.15 — PULL CREATE / EDIT MODAL ============
  // One modal serves both create and edit. In edit mode, PullNumber + Warehouse
  // + the LockPoByPull checkbox are all disabled (immutable post-create).
  // The server enforces all three; this is UI defense-in-depth + a clear hint.
  const pullModalEl = document.getElementById('pullModal');
  const pullModal = pullModalEl ? new bootstrap.Modal(pullModalEl) : null;
  let pullModalMode = 'create';   // 'create' | 'edit'
  let editingPullId = null;        // GUID when mode === 'edit'
  let warehousesCache = null;      // /api/warehouses?status=active

  async function ensureWarehouses() {
    if (warehousesCache) return warehousesCache;
    try {
      const r = await fetch('/api/warehouses?status=active');
      warehousesCache = r.ok ? await r.json() : [];
    } catch { warehousesCache = []; }
    return warehousesCache;
  }

  function populateWarehouseSelect(sel, current) {
    sel.innerHTML = warehousesCache
      .map(w => `<option value="${w.id}">${w.code} · ${w.name}</option>`)
      .join('');
    if (current) sel.value = current;
  }

  async function openCreatePullModal() {
    if (!pullModal) return;
    pullModalMode = 'create';
    editingPullId = null;
    document.getElementById('pm-title').textContent = 'New Pull';
    document.getElementById('pm-save').textContent = 'Create pull';

    await ensureWarehouses();
    populateWarehouseSelect(document.getElementById('pm-warehouse'), null);

    document.getElementById('pm-pull-number').value = '';
    document.getElementById('pm-pull-number').disabled = false;
    document.getElementById('pm-warehouse').disabled = false;
    document.getElementById('pm-pull-date').value = new Date().toISOString().slice(0, 10);
    document.getElementById('pm-eta').value = '';
    document.getElementById('pm-reference').value = '';
    document.getElementById('pm-notes').value = '';

    const lockChk = document.getElementById('pm-lock-po-by-pull');
    lockChk.checked = true;            // v2.1 default — pull-locked is the safe choice
    lockChk.disabled = false;
    document.getElementById('pm-lock-card').classList.remove('locked-immutable');
    document.getElementById('pm-lock-help').textContent =
      'When enabled, only POs explicitly linked to this pull can be received against. ' +
      'Cannot be changed after creation (§7.15 / §3.5 Mode B).';

    // v2.1 Hour Cap — strict by default for new pulls.
    const hcapChk = document.getElementById('pm-lock-hour-cap');
    hcapChk.checked = true;
    hcapChk.disabled = false;
    document.getElementById('pm-hcap-card').classList.remove('locked-immutable');
    document.getElementById('pm-hcap-help').textContent =
      'When enabled, receives that would exceed a window’s expected qty are rejected. ' +
      'Uncheck for vendors that over-ship intentionally. Immutable after creation.';

    pullModal.show();
  }

  async function openEditPullModal() {
    if (!pullModal || !selectedPullId) return;
    const p = pulls.find(x => x.pullId === selectedPullId);
    if (!p) return;
    pullModalMode = 'edit';
    editingPullId = p.pullId;
    document.getElementById('pm-title').textContent = 'Edit Pull · ' + p.id;
    document.getElementById('pm-save').textContent = 'Save changes';

    await ensureWarehouses();
    populateWarehouseSelect(document.getElementById('pm-warehouse'), p.warehouseId || null);

    document.getElementById('pm-pull-number').value = p.id;
    document.getElementById('pm-pull-number').disabled = true;   // immutable
    document.getElementById('pm-warehouse').disabled = true;     // immutable
    document.getElementById('pm-pull-date').value = p.dateISO;
    document.getElementById('pm-eta').value = p.etaRaw || '';
    document.getElementById('pm-reference').value = p.referenceNumber || '';
    document.getElementById('pm-notes').value = p.notesRaw || '';

    const lockChk = document.getElementById('pm-lock-po-by-pull');
    lockChk.checked = p.lockPoByPull;
    lockChk.disabled = true;                                     // §7.15 immutable
    document.getElementById('pm-lock-card').classList.toggle('locked-immutable', p.lockPoByPull);
    document.getElementById('pm-lock-help').innerHTML =
      '<i class="bi bi-lock-fill"></i> Immutable after pull creation (§7.15). ' +
      'Cancel and re-issue if the allocation mode needs to change.';

    // v2.1 Hour Cap — echo current value; disabled + immutability hint, like PO lock.
    const hcapChk = document.getElementById('pm-lock-hour-cap');
    hcapChk.checked = p.lockHourCap;
    hcapChk.disabled = true;
    document.getElementById('pm-hcap-card').classList.toggle('locked-immutable', p.lockHourCap);
    document.getElementById('pm-hcap-help').innerHTML =
      '<i class="bi bi-clock-fill"></i> Immutable after pull creation. ' +
      'Cancel and re-issue if the hour-cap policy needs to change.';

    drawer.hide();
    pullModal.show();
  }

  async function savePullModal() {
    if (!pullModal) return;
    const body = {
      pullDate:        document.getElementById('pm-pull-date').value || null,
      eta:             document.getElementById('pm-eta').value.trim() || null,
      notes:           document.getElementById('pm-notes').value.trim() || null,
      referenceNumber: document.getElementById('pm-reference').value.trim() || null,
      lockPoByPull:    document.getElementById('pm-lock-po-by-pull').checked,
      lockHourCap:     document.getElementById('pm-lock-hour-cap').checked,
    };

    let url, method;
    if (pullModalMode === 'create') {
      body.pullNumber  = document.getElementById('pm-pull-number').value.trim();
      body.warehouseId = document.getElementById('pm-warehouse').value;
      if (!body.pullNumber || !body.warehouseId || !body.pullDate) {
        return showToast('Missing required field', 'Pull #, warehouse, date');
      }
      url = '/api/pulls';
      method = 'POST';
    } else {
      url = '/api/pulls/' + encodeURIComponent(editingPullId);
      method = 'PUT';
    }

    const btn = document.getElementById('pm-save');
    btn.disabled = true;
    try {
      const r = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (r.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!r.ok) {
        let title = 'Save failed (' + r.status + ')';
        try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
        showToast('Could not save pull', title);
        return;
      }
      pullModal.hide();
      showToast(pullModalMode === 'create' ? 'Pull created' : 'Pull updated',
                pullModalMode === 'create'
                    ? body.pullNumber + (body.lockPoByPull ? ' · locked' : '')
                    : 'Saved');
      await loadPulls();
    } catch (e) {
      showToast('Network error', e.message || 'Could not reach server');
    } finally {
      btn.disabled = false;
    }
  }

  document.getElementById('btn-new-pull')?.addEventListener('click', openCreatePullModal);
  document.getElementById('d-edit')?.addEventListener('click', openEditPullModal);
  document.getElementById('pm-save')?.addEventListener('click', savePullModal);

  // ============ v2.1 PHASE 6.3 — PULLITEM ADMIN (items + windows) ============
  // Lazy-loaded into the drawer when it opens. CRUD is split across 3 modals
  // (Add Item / Edit Item / Windows) — see Index.cshtml for the rationale.
  const itemAddModalEl   = document.getElementById('itemAddModal');
  const itemEditModalEl  = document.getElementById('itemEditModal');
  const windowsModalEl   = document.getElementById('windowsModal');
  const itemAddModal   = itemAddModalEl   ? new bootstrap.Modal(itemAddModalEl)   : null;
  const itemEditModal  = itemEditModalEl  ? new bootstrap.Modal(itemEditModalEl)  : null;
  const windowsModal   = windowsModalEl   ? new bootstrap.Modal(windowsModalEl)   : null;

  // Cache the items currently rendered into the drawer so the edit/windows
  // flows don't have to re-fetch for header info (still re-fetch on every
  // mutation so the cache never goes stale).
  let drawerItems = [];
  // Tracked separately so we don't have to re-resolve `selectedPullId` inside
  // the modals (drawer can close while a modal is up).
  let drawerPullIdForItems = null;
  // Item open in editItemModal / windowsModal
  let editingItemId = null;

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[c]));
  }

  async function loadItemsForDrawer(pullGuid) {
    drawerPullIdForItems = pullGuid;
    try {
      const r = await fetch('/api/pulls/' + encodeURIComponent(pullGuid) + '/items');
      drawerItems = r.ok ? await r.json() : [];
    } catch { drawerItems = []; }
    renderItemsTable();
  }

  function renderItemsTable() {
    const tbody = document.getElementById('d-items-tbody');
    const empty = document.getElementById('d-items-empty');
    const countEl = document.getElementById('d-items-count');
    if (!tbody) return;
    countEl.textContent = drawerItems.length ? '(' + drawerItems.length + ')' : '';
    if (!drawerItems.length) {
      tbody.innerHTML = '';
      empty.classList.remove('d-none');
      return;
    }
    empty.classList.add('d-none');
    tbody.innerHTML = drawerItems.map(it => {
      const windows = it.windows || [];
      const exp = windows.reduce((a, w) => a + (w.expectedQty || 0), 0);
      const rcv = windows.reduce((a, w) => a + (w.receivedQty || 0), 0);
      const vendor = it.vendorCode
        ? esc(it.vendorCode) + (it.vendorName ? ' · ' + esc(it.vendorName) : '')
        : (it.vendorName ? esc(it.vendorName) : '—');
      const tagCell = it.tag
        ? '<span class="badge tag-' + esc(it.tag) + '">' + esc(it.tag) + '</span>'
        : '<span class="text-muted">—</span>';
      return '<tr data-item-id="' + esc(it.id) + '">' +
        '<td><code>' + esc(it.itemCode) + '</code></td>' +
        '<td>' + esc(it.description) + '</td>' +
        '<td>' + vendor + '</td>' +
        '<td>' + tagCell + '</td>' +
        '<td><span class="status-' + esc(it.status) + '">' + esc(it.status) + '</span></td>' +
        '<td class="text-end"><small>' + windows.length + ' · ' +
          exp.toLocaleString() + ' exp · ' + rcv.toLocaleString() + ' rcv</small></td>' +
        '<td class="actions-col">' +
          '<button class="btn btn-link" data-act="windows" title="Manage windows"><i class="bi bi-clock"></i></button>' +
          '<button class="btn btn-link" data-act="edit" title="Edit item"><i class="bi bi-pencil"></i></button>' +
          '<button class="btn btn-link text-danger" data-act="delete" title="Delete item"><i class="bi bi-trash"></i></button>' +
        '</td>' +
      '</tr>';
    }).join('');
  }

  // ---- delegated row actions
  document.getElementById('d-items-tbody')?.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    const tr = btn.closest('tr[data-item-id]');
    if (!tr) return;
    const itemId = tr.dataset.itemId;
    const act = btn.dataset.act;
    if (act === 'edit') openEditItemModal(itemId);
    else if (act === 'delete') deleteItem(itemId);
    else if (act === 'windows') openWindowsModal(itemId);
  });

  // ---- Add Item modal ----------------------------------------------------
  function openAddItemModal() {
    if (!itemAddModal || !selectedPullId) return;
    const p = pulls.find(x => x.pullId === selectedPullId);
    if (!p) return;
    drawerPullIdForItems = selectedPullId;
    document.getElementById('iam-pull-label').textContent = p.id;
    document.getElementById('iam-item-code').value = '';
    document.getElementById('iam-description').value = '';
    document.getElementById('iam-vendor-code').value = '';
    document.getElementById('iam-vendor-name').value = '';
    document.getElementById('iam-tag').value = '';
    document.getElementById('iam-remark').value = '';
    // Seed with one empty row so the user sees the table shape.
    document.getElementById('iam-windows-tbody').innerHTML = '';
    appendAddWindowRow();
    itemAddModal.show();
  }

  function appendAddWindowRow() {
    const tbody = document.getElementById('iam-windows-tbody');
    const hourOpts = Array.from({ length: 24 }, (_, h) =>
      '<option value="' + h + '">' + String(h).padStart(2, '0') + ':00</option>').join('');
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td><select class="form-select iam-w-hour">' + hourOpts + '</select></td>' +
      '<td><input type="number" class="form-control iam-w-qty" min="1" placeholder="qty"></td>' +
      '<td class="actions-col">' +
        '<button class="btn btn-link text-danger" data-act="rm" title="Remove"><i class="bi bi-x-lg"></i></button>' +
      '</td>';
    tbody.appendChild(tr);
  }

  document.getElementById('iam-add-window')?.addEventListener('click', appendAddWindowRow);
  document.getElementById('iam-windows-tbody')?.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-act="rm"]');
    if (!btn) return;
    const tbody = document.getElementById('iam-windows-tbody');
    if (tbody.children.length <= 1) {
      showToast('At least one window required', '');
      return;
    }
    btn.closest('tr').remove();
  });

  async function saveAddItem() {
    if (!drawerPullIdForItems) return;
    const itemCode = document.getElementById('iam-item-code').value.trim();
    const description = document.getElementById('iam-description').value.trim();
    if (!itemCode || !description) return showToast('Missing required field', 'Item code + description');

    const rows = Array.from(document.querySelectorAll('#iam-windows-tbody tr'));
    const hours = new Set();
    const windows = [];
    for (const tr of rows) {
      const h = parseInt(tr.querySelector('.iam-w-hour').value, 10);
      const q = parseInt(tr.querySelector('.iam-w-qty').value, 10);
      if (Number.isNaN(q) || q <= 0) return showToast('Bad window qty', 'Each window needs qty > 0');
      if (hours.has(h)) return showToast('Duplicate hour', 'Hour ' + String(h).padStart(2,'0') + ' used twice');
      hours.add(h);
      windows.push({ hourOfDay: h, expectedQty: q });
    }
    if (windows.length === 0) return showToast('At least one window required', '');

    const body = {
      itemCode, description,
      vendorCode: document.getElementById('iam-vendor-code').value.trim() || null,
      vendorName: document.getElementById('iam-vendor-name').value.trim() || null,
      tag: document.getElementById('iam-tag').value || null,
      remark: document.getElementById('iam-remark').value.trim() || null,
      windows,
    };

    const btn = document.getElementById('iam-save');
    btn.disabled = true;
    try {
      const r = await fetch('/api/pulls/' + encodeURIComponent(drawerPullIdForItems) + '/items', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (r.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!r.ok) {
        let title = 'Save failed (' + r.status + ')';
        try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
        showToast('Could not add item', title);
        return;
      }
      itemAddModal.hide();
      showToast('Item added', itemCode);
      await refreshPullDetailDrawer(drawerPullIdForItems);
    } finally {
      btn.disabled = false;
    }
  }

  document.getElementById('d-add-item')?.addEventListener('click', openAddItemModal);
  document.getElementById('iam-save')?.addEventListener('click', saveAddItem);

  // ---- Edit Item modal ---------------------------------------------------
  function openEditItemModal(itemId) {
    if (!itemEditModal) return;
    const it = drawerItems.find(x => x.id === itemId);
    if (!it) return;
    editingItemId = itemId;
    document.getElementById('iem-code-label').textContent = it.itemCode;
    document.getElementById('iem-description').value = it.description || '';
    document.getElementById('iem-vendor-code').value = it.vendorCode || '';
    document.getElementById('iem-vendor-name').value = it.vendorName || '';
    document.getElementById('iem-tag').value = it.tag || '';
    document.getElementById('iem-status').value = it.status || 'normal';
    document.getElementById('iem-remark').value = it.remark || '';
    itemEditModal.show();
  }

  async function saveEditItem() {
    if (!drawerPullIdForItems || !editingItemId) return;
    const description = document.getElementById('iem-description').value.trim();
    if (!description) return showToast('Description required', '');

    const body = {
      description,
      vendorCode: document.getElementById('iem-vendor-code').value.trim() || null,
      vendorName: document.getElementById('iem-vendor-name').value.trim() || null,
      tag: document.getElementById('iem-tag').value || null,
      status: document.getElementById('iem-status').value,
      remark: document.getElementById('iem-remark').value.trim() || null,
    };

    const btn = document.getElementById('iem-save');
    btn.disabled = true;
    try {
      const r = await fetch(
        '/api/pulls/' + encodeURIComponent(drawerPullIdForItems) +
        '/items/' + encodeURIComponent(editingItemId),
        {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
      if (r.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!r.ok) {
        let title = 'Save failed (' + r.status + ')';
        try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
        showToast('Could not save item', title);
        return;
      }
      itemEditModal.hide();
      showToast('Item updated', '');
      await refreshPullDetailDrawer(drawerPullIdForItems);
    } finally {
      btn.disabled = false;
    }
  }

  document.getElementById('iem-save')?.addEventListener('click', saveEditItem);

  // ---- Delete item -------------------------------------------------------
  async function deleteItem(itemId) {
    if (!drawerPullIdForItems) return;
    const it = drawerItems.find(x => x.id === itemId);
    if (!it) return;
    const ok = await confirmAction({
      title: 'Delete item ' + it.itemCode + '?',
      message: 'All hour windows on this item will cascade. Refused if any window has receipts.',
      icon: 'trash',
      confirmLabel: 'Delete item',
      danger: true,
    });
    if (!ok) return;
    const r = await fetch(
      '/api/pulls/' + encodeURIComponent(drawerPullIdForItems) +
      '/items/' + encodeURIComponent(itemId),
      { method: 'DELETE' });
    if (r.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!r.ok) {
      let title = 'Delete failed (' + r.status + ')';
      try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
      showToast('Could not delete', title);
      return;
    }
    showToast('Item deleted', it.itemCode);
    await refreshPullDetailDrawer(drawerPullIdForItems);
  }

  // ---- Windows modal -----------------------------------------------------
  function openWindowsModal(itemId) {
    if (!windowsModal) return;
    const it = drawerItems.find(x => x.id === itemId);
    if (!it) return;
    editingItemId = itemId;
    document.getElementById('wm-code-label').textContent = it.itemCode;
    renderWindowsTable(it.windows || []);
    document.getElementById('wm-new-qty').value = '';
    windowsModal.show();
  }

  function renderWindowsTable(windows) {
    const tbody = document.getElementById('wm-tbody');
    const taken = new Set((windows || []).map(w => w.hourOfDay));
    tbody.innerHTML = (windows || [])
      .slice()
      .sort((a, b) => a.hourOfDay - b.hourOfDay)
      .map(w => {
        const canDelete = w.receivedQty === 0;
        return '<tr data-hour="' + w.hourOfDay + '">' +
          '<td><code>' + String(w.hourOfDay).padStart(2, '0') + ':00</code></td>' +
          '<td><input type="number" class="form-control window-qty" min="1" value="' + w.expectedQty + '"></td>' +
          '<td><small class="text-muted">' + w.receivedQty + ' pcs</small></td>' +
          '<td class="actions-col">' +
            '<button class="btn btn-sm btn-outline-primary me-1" data-act="save"><i class="bi bi-check2"></i> Save</button>' +
            (canDelete
              ? '<button class="btn btn-sm btn-outline-danger" data-act="del"><i class="bi bi-trash"></i></button>'
              : '<button class="btn btn-sm btn-outline-secondary" disabled title="Has receipts"><i class="bi bi-lock"></i></button>') +
          '</td>' +
        '</tr>';
      }).join('');

    // Re-populate the "add new" hour select with only unused hours.
    const newHourSel = document.getElementById('wm-new-hour');
    newHourSel.innerHTML = Array.from({ length: 24 }, (_, h) => h)
      .filter(h => !taken.has(h))
      .map(h => '<option value="' + h + '">' + String(h).padStart(2, '0') + ':00</option>').join('');
  }

  document.getElementById('wm-tbody')?.addEventListener('click', async (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    const tr = btn.closest('tr[data-hour]');
    const hour = parseInt(tr.dataset.hour, 10);
    const act = btn.dataset.act;
    if (act === 'save') {
      const qty = parseInt(tr.querySelector('.window-qty').value, 10);
      if (Number.isNaN(qty) || qty <= 0) return showToast('Bad qty', 'Must be > 0');
      const r = await fetch(
        '/api/pulls/' + encodeURIComponent(drawerPullIdForItems) +
        '/items/' + encodeURIComponent(editingItemId) +
        '/windows/' + hour,
        {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ expectedQty: qty }),
        });
      if (!r.ok) {
        let title = 'PUT failed (' + r.status + ')';
        try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
        return showToast('Could not save window', title);
      }
      showToast('Window updated', String(hour).padStart(2,'0') + ':00');
      await refreshWindowsModal();
    } else if (act === 'del') {
      const r = await fetch(
        '/api/pulls/' + encodeURIComponent(drawerPullIdForItems) +
        '/items/' + encodeURIComponent(editingItemId) +
        '/windows/' + hour,
        { method: 'DELETE' });
      if (!r.ok) {
        let title = 'Delete failed (' + r.status + ')';
        try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
        return showToast('Could not delete window', title);
      }
      showToast('Window deleted', String(hour).padStart(2,'0') + ':00');
      await refreshWindowsModal();
    }
  });

  document.getElementById('wm-add')?.addEventListener('click', async () => {
    const sel = document.getElementById('wm-new-hour');
    const qty = parseInt(document.getElementById('wm-new-qty').value, 10);
    if (!sel.value) return showToast('No free hour', 'All 24 hours are already filled');
    if (Number.isNaN(qty) || qty <= 0) return showToast('Bad qty', 'Enter a positive number');
    const r = await fetch(
      '/api/pulls/' + encodeURIComponent(drawerPullIdForItems) +
      '/items/' + encodeURIComponent(editingItemId) + '/windows',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hourOfDay: parseInt(sel.value, 10), expectedQty: qty }),
      });
    if (!r.ok) {
      let title = 'Add failed (' + r.status + ')';
      try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
      return showToast('Could not add window', title);
    }
    showToast('Window added', String(sel.value).padStart(2,'0') + ':00');
    document.getElementById('wm-new-qty').value = '';
    await refreshWindowsModal();
  });

  // Re-fetch the full pull detail (header + summary + items), re-render the
  // drawer + items table, then re-render the windows modal table from the
  // freshly-loaded item. refreshPullDetailDrawer already populates drawerItems
  // and re-renders the items table, so we just pick up the open item from there.
  async function refreshWindowsModal() {
    if (!drawerPullIdForItems || !editingItemId) return;
    await refreshPullDetailDrawer(drawerPullIdForItems);
    const it = drawerItems.find(x => x.id === editingItemId);
    if (it) renderWindowsTable(it.windows || []);
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
  document.getElementById('lock-filter')?.addEventListener('change', render);
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

  // Restore date filter from URL (?dateRange=...) if present + valid; the
  // HTML default is already "last_2_days" so a bare /Dashboard URL drops
  // into the operational window without JS doing anything.
  (function restoreDateFilterFromUrl() {
    const sel = document.getElementById('date-filter');
    const want = new URLSearchParams(window.location.search).get('dateRange');
    if (!want || !sel) return;
    if (Array.from(sel.options).some(o => o.value === want)) {
      sel.value = want;
      document.getElementById('custom-date-row')?.classList.toggle('visible', want === 'custom');
    }
  })();

  populateWhFilter().then(loadPulls);
})();
