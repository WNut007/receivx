/* ===== JS:main (from receiving-mockup-v2-fullreceived.html) ===== */
  // ============ THEME SYSTEM ============
  // Shared with Pull Controller — both use the same localStorage key so theme
  // choice persists across the two pages.
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
  (function initTheme() {
    let saved = 'light';
    try { saved = localStorage.getItem(THEME_KEY) || 'light'; } catch (e) {}
    applyTheme(saved);
  })();

  // ============ DATA ============
  // Stage B: pullData is populated from GET /api/pulls/by-number/{pullNumber}.
  // Shape (kept compatible with the original mockup so the render code below is
  // untouched): pullData[pullNumber][warehouseCode] = items[].
  //
  // Each item carries an extra `pullItemId` (GUID) for POST /api/receipts.
  // schedule is keyed by hour 0-23 with { r: received, e: expected }.
  const pullData = {};

  // Server-side identifiers needed by POST /api/receipts and friends.
  let currentPull = null;        // pullNumber (PL-XXXX) — drives client filters
  let currentPullId = null;      // pull GUID — used by /api/receipts/pull/{guid}
  let currentWarehouse = null;   // warehouse code from the loaded pull
  let currentWhName = null;
  let serverPullStatus = null;   // pending|in_progress|fully_received|closed
  let currentPullLocked = false; // §3.5 — Pulls.LockPoByPull mirrored from PullDetail
  // Pulls.LockHourCap mirrored from PullDetail.
  //
  // §2f (rev 11) — this no longer gates anything on the receive path: over-receipt is
  // permitted on every pull with the final-receipt tick. Kept because the dashboard
  // still displays the flag (Strict/Loose pill, drawer) and it remains immutable after
  // create, so the value is still meaningful — it just no longer decides a receive.
  let currentPullHourCapLocked = false;

  // db/047 — did the server's preview refuse this quantity? The allocation preview
  // used to write btn.disabled directly, which meant two functions owned the Confirm
  // button: the preview's success path re-enabled it ~200ms after typing and silently
  // undid the variance gate, so an unticked over-receipt became clickable. The preview
  // now records its verdict here and refreshVarianceUi is the single owner of the gate.
  let _previewBlocked = false;
  let items = [];

  function loadPullWarehouse(pullId, whCode) {
    currentPull = pullId;
    items = (pullData[pullId] && pullData[pullId][whCode]) || [];
  }

  function loadWarehouseItems(code) {
    items = (pullData[currentPull] && pullData[currentPull][code]) || [];
  }

  // ---- helpers to read/write a cell by absolute hour ----
  function getCell(item, hour) {
    const slot = item.schedule[hour];
    if (!slot) return { r: 0, e: 0, s: 'empty' };
    // 'over' is its own state so the visual treatment can flag the overage
    // distinctly from 'complete' (per §7.1 v2, over-receive is allowed when
    // the PO has capacity — but it shouldn't look identical to exactly-done).
    // db/047 §2d — 'closed' wins over 'pending'. A short-closed window renders
    // 400 / 1,000, which is character-for-character identical to a partial still
    // waiting on a delivery. Without its own state the grid cannot tell a finished
    // line from an unfinished one, which is the exact confusion this change exists
    // to remove — a reopen button on the modal would just move the problem.
    //
    // A window that is closed AND exactly complete still reads 'complete': it
    // finished normally through the full-receipt path, and there is no variance to
    // signal. Over stays 'over' for the same reason — the overage is the story.
    const s = (slot.e === 0) ? 'empty'
            : (slot.r >  slot.e) ? 'over'
            : (slot.r === slot.e) ? 'complete'
            : slot.c ? 'closed'
            : 'pending';
    return { r: slot.r, e: slot.e, s, closed: !!slot.c };
  }
  function setReceived(item, hour, newR) {
    if (!item.schedule[hour]) return;
    item.schedule[hour].r = newR;
  }

  // db/047 — THE outstanding rule for this file. A window stops being
  // outstanding when it is filled OR when it was deliberately closed short;
  // that is the whole point of IsClosed, and the server has said so in all
  // five of its §2c queries since db/047 shipped.
  //
  // This exists because the client had four independent copies of
  // `slot.r < slot.e` — the close-pull gate, the period header, the row
  // filter and the export — and only the cell renderer knew about `slot.c`.
  // A short-closed line therefore rendered CLOSED while the header beside it
  // still counted it as work and the CLOSE PULL SHEET button stayed disabled
  // (pull 0000028388, item 2R53-810288-253, window 19:00, 790/792).
  //
  // Anything in this file that asks "is there work left here?" goes through
  // these two helpers. Adding a fifth transcription of the arithmetic is how
  // the bug comes back.
  function isSettled(slot) {
    if (!slot || slot.e <= 0) return true;      // nothing scheduled is nothing owed
    return !!slot.c || slot.r >= slot.e;
  }

  // Units still genuinely expected. Zero for a closed window whatever the
  // arithmetic says — a short close writes the shortfall off, it does not
  // leave it owed.
  function slotOutstanding(slot) {
    if (isSettled(slot)) return 0;
    return Math.max(0, (slot.e | 0) - (slot.r | 0));
  }

  // The settled difference between what arrived and what was planned, signed
  // the same way the server signs Receipts.VarianceQty: NEGATIVE short,
  // POSITIVE over. Only settled windows have one — an open partial's gap is
  // outstanding work, not a decision anybody made.
  //
  // This exists so the strip's figures still reconcile once a line is written
  // off. Without it the operator sees Expected 1,584 · Received 1,582 ·
  // Outstanding 0 and has no way to tell whether the missing 2 were written
  // off deliberately or dropped by a bug — and three numbers that do not add
  // up, with nothing on screen explaining why, get read as a bug every time.
  //
  //     Expected = Received - Variance + Outstanding
  //
  // holds for every window: short-closed 792/790 → 792 = 790 - (-2) + 0;
  // over-received 100/150 → 100 = 150 - 50 + 0; open partial 500/100 →
  // 500 = 100 - 0 + 400.
  function slotVariance(slot) {
    if (!slot || slot.e <= 0) return 0;
    if (!isSettled(slot)) return 0;
    return (slot.r | 0) - (slot.e | 0);
  }

  // Visible 4 hours = current period start + 0..3, wrapped at 24
  function currentPeriodHours() {
    const start = parseInt(document.getElementById('period-select').value);
    return [0,1,2,3].map(i => (start + i) % 24);
  }

  // ---- classify an item by the CURRENTLY VISIBLE PERIOD (4 hours) ----
  // Filter shows items based on what the user is looking at, not the whole sheet.
  function itemClass(item) {
    if (item.status === 'canceled') return 'canceled';
    const hours = currentPeriodHours();
    let hasExpected = false;
    let hasOutstanding = false;
    for (const h of hours) {
      const slot = item.schedule[h];
      if (!slot || slot.e <= 0) continue;
      hasExpected = true;
      // A short-closed line is finished work. Leaving it in the Outstanding
      // bucket is the worklist-never-empties failure db/047 exists to end.
      if (!isSettled(slot)) hasOutstanding = true;
    }
    if (!hasExpected) return 'received'; // nothing scheduled in this period
    return hasOutstanding ? 'outstanding' : 'received';
  }

  function currentFilter() {
    const el = document.getElementById('filter-select');
    return el ? el.value : 'all';
  }

  function currentSearch() {
    const el = document.getElementById('search-input');
    return el ? el.value.trim().toLowerCase() : '';
  }

  function itemPassesFilter(item) {
    // Status filter
    const f = currentFilter();
    if (f !== 'all' && itemClass(item) !== f) return false;

    // Free-text search across item code, description, vendor code, vendor name,
    // remark, and SPECIAL (which the Remark column now displays — a value the
    // operator can read but not search for would just look broken).
    const q = currentSearch();
    if (q.length === 0) return true;
    const haystack = [
      item.code, item.desc, item.vCode, item.vName, item.remark, item.special
    ].join(' ').toLowerCase();
    return haystack.includes(q);
  }

  let pullClosed = false;

  // The Remark column stacks Remark over SPECIAL, mirroring the Vendor cell.
  //
  // `item.remark` already carries the EM_DASH placeholder from the mapping
  // above, so it has to count as absent here — otherwise a row with only a
  // SPECIAL would render a stray "—" line above it.
  const EM_DASH = '—';
  const REMARK_SEP = ' · ';
  function remarkParts(item) {
    const clean = v => {
      const s = String(v ?? '').trim();
      return (s === '' || s === EM_DASH) ? '' : s;
    };
    return { remark: clean(item.remark), special: clean(item.special) };
  }
  // Flattened form for the tooltip, which has to carry both lines untruncated
  // in one string. " · " is the separator this page already uses to join short
  // facts (stats strip, tx-drawer's lot·pallet line).
  function remarkText(item) {
    const { remark, special } = remarkParts(item);
    const parts = [remark, special].filter(Boolean);
    return parts.length ? parts.join(REMARK_SEP) : EM_DASH;
  }

  // ============ RENDER ============
  function render() {
    const tbody = document.getElementById('rows');
    tbody.innerHTML = '';
    let shown = 0;
    items.forEach((item, ri) => {
      if (!itemPassesFilter(item)) return;
      shown++;
      const tr = document.createElement('tr');
      if (item.tag === 'pcba') tr.classList.add('pcba');
      if (item.tag === 'swap') tr.classList.add('swap');
      if (item.status === 'canceled') tr.classList.add('row-canceled');
      if (item.status === 'new') tr.classList.add('row-new');

      const tagHtml = item.tag === 'pcba' ? '<span class="tag pcba">PCBA</span>'
                    : item.tag === 'swap' ? '<span class="tag swap">SWAP</span>' : '';

      const statusLabel = item.status === 'canceled' ? 'Canceled'
                       : item.status === 'new' ? 'New' : 'Normal';

      // Both lines are clamped in CSS, so carry the full text in a tooltip.
      const remarkFull = remarkText(item);
      // Vendor name is line-clamped too (2 lines desktop, 1 line compact),
      // so the Vendor cell carries the same tooltip treatment as Remark.
      const vendorFull = [item.vCode, item.vName].filter(Boolean).join(' · ');
      const rp = remarkParts(item);
      // Render each line only when it has a value — an empty <div> would add
      // height to every row missing that field. Neither present → placeholder.
      const remarkHtml = (!rp.remark && !rp.special)
        ? `<div class="remark-text">${EM_DASH}</div>`
        : (rp.remark  ? `<div class="remark-text">${escapeHtml(rp.remark)}</div>` : '')
        + (rp.special ? `<div class="remark-special">${escapeHtml(rp.special)}</div>` : '');

      // freeze/c-* must mirror the <th> classes in Index.cshtml — the body
      // cells pin to the same offsets as their headers.
      // .status-inline is the compact-mode (≤840px) home for the status badge:
      // hidden on desktop, shown when CSS collapses the c-status column. Both
      // copies carry .status-badge + data-row, so the single re-bind below
      // wires the status menu to whichever one is visible.
      tr.innerHTML = `
        <td class="status-cell freeze c-status">
          <button class="status-badge ${item.status}" data-row="${ri}">${statusLabel}</button>
        </td>
        <td class="info-cell freeze c-item">
          <div class="item-code">${item.code}${tagHtml}</div>
          <div class="item-desc">${item.desc}</div>
          <div class="status-inline">
            <button class="status-badge ${item.status}" data-row="${ri}">${statusLabel}</button>
          </div>
        </td>
        <td class="vendor-cell freeze c-vendor" title="${escAttr(vendorFull)}">
          <div class="vendor-code">${item.vCode}</div>
          <div class="vendor-name">${item.vName}</div>
        </td>
        <td class="remark-cell freeze c-remark" title="${escAttr(remarkFull)}">${remarkHtml}</td>
      `;

      item.cells = currentPeriodHours().map(h => getCell(item, h));
      item.cells.forEach((c, ci) => {
        const td = document.createElement('td');
        td.className = 'hour-cell';
        const btn = document.createElement('button');
        btn.className = 'hour-btn ' + c.s;
        btn.dataset.row = ri;
        btn.dataset.col = ci;

        // Keep the RAW percentage so over-receive reads as e.g. "130%" — the
        // status text never gets clamped. The progress-bar fill is the only
        // value that caps at 100% (a bar can't physically be > 100% wide).
        const pct = c.e > 0 ? Math.round((c.r / c.e) * 100) : 0;
        const barPct = Math.min(100, pct);

        if (c.s === 'empty') {
          btn.innerHTML = `<div class="hour-nums"><span class="label">add</span></div>`;
        } else {
          // 'over' = up-arrow + raw pct (e.g. "↑ 130%"); 'complete' = checkmark.
          // db/047 §2d — a closed line says so, in words. "56%" on a closed window
          // reads as work outstanding; "CLOSED" does not.
          const statusText = c.s === 'over'     ? `↑ ${pct}%`
                           : c.s === 'complete' ? `✓ ${pct}%`
                           : c.s === 'closed'   ? `CLOSED`
                           : `${pct}%`;
          // Numerals get an extra "+N over" tail when over-received so the
          // cell tells one consistent story (number + status both flag overage).
          const overTail = c.s === 'over'
            ? `<span class="over-tail">+${(c.r - c.e).toLocaleString()}</span>`
            : '';
          btn.innerHTML = `
            <div class="hour-nums">
              <span class="recv">${c.r.toLocaleString()}</span>
              <span class="sep">/</span>
              <span class="exp">${c.e.toLocaleString()}</span>
              ${overTail}
            </div>
            <div class="hour-meter"><span style="width:${barPct}%"></span></div>
            <div class="hour-status">${statusText}</div>
          `;
        }
        if (item.status !== 'canceled') {
          btn.addEventListener('click', () => openModal(ri, ci));
        }
        td.appendChild(btn);
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });

    // Empty-state row when nothing matches the filter
    if (shown === 0) {
      const tr = document.createElement('tr');
      const q = currentSearch();
      const f = currentFilter();
      let msg;
      if (items.length === 0) {
        msg = `No items for ${currentPull} in this warehouse`;
      } else if (q && f !== 'all') {
        msg = `No "${f}" items match "${q}"`;
      } else if (q) {
        msg = `No items match "${q}"`;
      } else {
        msg = `No items match the "${f}" filter`;
      }
      tr.innerHTML = `<td colspan="8" style="padding:48px 24px;text-align:center;color:var(--text-muted);font-family:var(--font-mono);font-size:11px;letter-spacing:0.1em;text-transform:uppercase;">${msg}</td>`;
      tbody.appendChild(tr);
    }

    // re-bind status badge clicks
    document.querySelectorAll('.status-badge').forEach(b => {
      b.addEventListener('click', (e) => openStatusMenu(e, parseInt(b.dataset.row)));
    });

    updateStats();
    updateCloseButton();
  }

  function updateStats() {
    let exp = 0, rec = 0, pendingWindows = 0, active = 0, canceled = 0, newCount = 0;
    let outstanding = 0, variance = 0, varianceLines = 0;
    const hours = currentPeriodHours();
    items.forEach(i => {
      if (i.status === 'canceled') { canceled++; return; }
      active++;
      if (i.status === 'new') newCount++;
      hours.forEach(h => {
        const c = getCell(i, h);
        if (c.s !== 'empty') {
          exp += c.e;
          rec += c.r;
          // EXPECTED and RECEIVED stay raw totals — they answer "how much was
          // planned / how much arrived", and a short close changes neither.
          // OUTSTANDING is a different question ("how much is still owed"),
          // so it is summed per window through the IsClosed-aware rule rather
          // than derived as exp - rec. Those two figures no longer reconcile
          // by subtraction once a line has been written off, and that is
          // correct: the difference is the written-off shortfall.
          outstanding += slotOutstanding(i.schedule[h]);
          const v = slotVariance(i.schedule[h]);
          if (v !== 0) { variance += v; varianceLines++; }
          if (c.s === 'pending') pendingWindows++;
        }
      });
    });
    const pct = exp > 0 ? Math.round((rec / exp) * 100) : 0;

    document.getElementById('stat-items').innerHTML = `${active} <small>SKUs</small>`;
    document.getElementById('stat-items-sub').textContent = `${canceled} canceled · ${newCount} new`;
    document.getElementById('stat-exp').innerHTML = `${exp.toLocaleString()} <small>units</small>`;
    document.getElementById('stat-rec').innerHTML = `${rec.toLocaleString()} <small>units</small>`;
    document.getElementById('stat-rec-sub').textContent = `${pct}% of expected`;
    document.getElementById('stat-out').innerHTML = `${outstanding.toLocaleString()} <small>units</small>`;
    document.getElementById('stat-out-sub').textContent = `${pendingWindows} windows pending`;

    // Variance — the written-off (or over-delivered) difference on lines that
    // are already settled. Deliberately styled like any other figure on the
    // strip: short and over deliveries happen on nearly every pull here, so
    // this is a normal outcome being reported, not a problem being flagged.
    // Signed to match Receipts.VarianceQty — negative short, positive over —
    // so the number on screen and the number in the audit trail read alike.
    const varEl = document.getElementById('stat-var');
    const varSubEl = document.getElementById('stat-var-sub');
    if (varEl && varSubEl) {
      const sign = variance > 0 ? '+' : '';   // negatives carry their own '-'
      varEl.innerHTML = `${sign}${variance.toLocaleString()} <small>units</small>`;
      varSubEl.textContent =
        varianceLines === 0
          ? 'no lines closed off-plan'
          : variance < 0
            ? `${varianceLines} line${varianceLines === 1 ? '' : 's'} closed short`
            : variance > 0
              ? `${varianceLines} line${varianceLines === 1 ? '' : 's'} over-delivered`
              // Non-zero line count summing to zero: shorts and overs cancelled
              // out. Saying "0 units" alone would hide that anything happened.
              : `${varianceLines} lines off-plan · net zero`;
    }

    document.getElementById('prog-fill').style.width = pct + '%';
    document.getElementById('prog-label').textContent = pct + '%';
  }

  // Client-side mirror of CloseService's §7.4 gate (CloseService.cs:67-74),
  // which counts windows WHERE IsClosed = 0 AND ExpectedQty > ReceivedQty.
  // Keeping the two in agreement is the point: the server is the authority,
  // and a button that refuses to ask it is indistinguishable from a refusal.
  function isFullyReceived() {
    // Scan EVERY hour in EVERY non-canceled row's schedule (whole pull sheet, not just visible period)
    let hasAnyExpected = false;
    for (const i of items) {
      if (i.status === 'canceled') continue;
      for (const slot of Object.values(i.schedule)) {
        if (slot.e <= 0) continue;
        hasAnyExpected = true;
        if (!isSettled(slot)) return false;
      }
    }
    return hasAnyExpected;
  }

  /* Read the current user's role from auth.user. Falls back to operator. */
  function currentRole() {
    try {
      const raw = localStorage.getItem('auth.user');
      if (raw) {
        const u = JSON.parse(raw);
        return (u.roleKey || u.role || 'operator').toLowerCase();
      }
    } catch (e) {}
    return 'operator';
  }
  function canReopenPull() {
    const role = currentRole();
    return role === 'supervisor' || role === 'admin';
  }

  function updateCloseButton() {
    const closeBtn = document.getElementById('btn-close-pull');
    const reopenBtn = document.getElementById('btn-reopen-pull');

    if (pullClosed) {
      // Sheet is locked. Show reopen for supervisors; hide close.
      closeBtn.disabled = true;
      closeBtn.classList.remove('ready');
      document.getElementById('btn-close-pull-label').textContent = 'Pull Sheet Closed';

      if (canReopenPull()) {
        // Supervisor sees a Reopen button instead of the inert "closed" pill
        closeBtn.style.display = 'none';
        reopenBtn.style.display = '';
      } else {
        // Non-supervisor only sees the locked indicator
        closeBtn.style.display = '';
        reopenBtn.style.display = 'none';
      }
      return;
    }

    // Sheet is open
    reopenBtn.style.display = 'none';
    closeBtn.style.display = '';

    if (isFullyReceived()) {
      closeBtn.disabled = false;
      closeBtn.classList.add('ready');
      document.getElementById('btn-close-pull-label').textContent = 'Close Pull Sheet';
    } else {
      closeBtn.disabled = true;
      closeBtn.classList.remove('ready');
      document.getElementById('btn-close-pull-label').textContent = 'Close Pull Sheet';
    }
  }

  // ============ STATUS MENU ============
  const statusMenu = document.getElementById('status-menu');
  let statusMenuRow = null;

  function openStatusMenu(e, rowIdx) {
    if (pullClosed) return;
    e.stopPropagation();
    statusMenuRow = rowIdx;
    const rect = e.currentTarget.getBoundingClientRect();
    statusMenu.style.left = rect.left + 'px';
    statusMenu.style.top = (rect.bottom + 4) + 'px';
    statusMenu.classList.add('open');
  }

  document.querySelectorAll('.status-menu-item').forEach(it => {
    it.addEventListener('click', () => {
      if (statusMenuRow !== null) {
        items[statusMenuRow].status = it.dataset.status;
        statusMenu.classList.remove('open');
        statusMenuRow = null;
        render();
      }
    });
  });

  document.addEventListener('click', (e) => {
    if (!statusMenu.contains(e.target) && !e.target.classList.contains('status-badge')) {
      statusMenu.classList.remove('open');
    }
  });

  // ============ RECEIVE MODAL ============
  const modal = document.getElementById('modal');
  let activeRow = 0, activeCol = 0, activeMax = 0;

  function openModal(ri, ci) {
    // When pull is closed, still allow opening as VIEW-ONLY so the user can
    // inspect transactions. Form fields and confirm are disabled below.
    if (items[ri].status === 'canceled') return;

    activeRow = ri; activeCol = ci;
    const item = items[ri];
    const hours = currentPeriodHours();
    const hour = hours[ci];
    const cell = getCell(item, hour);
    const hourStr = String(hour).padStart(2, '0') + ':00';

    // remember which hour we're editing so confirmReceipt can write back even if period changes
    window._activeHour = hour;

    document.getElementById('m-time').textContent = hourStr;
    document.getElementById('m-title').textContent = item.code;
    document.getElementById('m-desc').textContent = item.desc;
    document.getElementById('m-vendor').textContent = `${item.vName} (${item.vCode})`;

    const expected = cell.e || 0;
    const prev = cell.r || 0;
    const outstanding = Math.max(0, expected - prev);
    activeMax = outstanding;

    document.getElementById('m-expected').textContent = expected.toLocaleString();
    document.getElementById('m-prev').textContent = prev.toLocaleString();
    document.getElementById('m-out').textContent = outstanding.toLocaleString();
    // Defensive: cap-hint-max can be missing if a downstream handler rewrote
    // its parent's innerHTML. The qty-input handler is the main culprit but
    // others may follow — null-guard so a destroyed element doesn't block
    // the whole openModal flow.
    const capMaxEl = document.getElementById('cap-hint-max');
    if (capMaxEl) capMaxEl.textContent = outstanding.toLocaleString();

    const input = document.getElementById('m-input');
    // db/047 §7 — no `max` attribute. The operator may enter any quantity; over-receipt
    // is governed by the accept-variance checkbox and the server, not by the input
    // silently refusing to hold the number. `min="0"` stays (in the markup).
    input.removeAttribute('max');
    input.value = outstanding;   // sensible starting figure, not a ceiling
    input.classList.remove('is-error');
    document.getElementById('cap-hint').classList.remove('error');

    // db/047 §7 — never pre-ticked, in any state. Reset the box and the note before
    // deriving the UI, so a tick left over from the previous slot cannot leak across.
    const vbox = document.getElementById('m-variance');
    if (vbox) vbox.checked = false;
    const vnote = document.getElementById('m-note');
    if (vnote) { vnote.value = ''; vnote.classList.remove('is-error'); }

    renderCapLock(outstanding);             // db/047 §2f
    renderClosedState(currentSlotMeta());   // db/047 §2d
    refreshVarianceUi();

    // ---- Read-only gate when pull is closed ----
    applyModalReadOnlyMode();

    // ---- Load transactions for this (item, hour) ----
    // Render immediately so the modal paints fast; if the journal cache is
    // empty or stale (which is the state right after confirmReceipt clears it
    // with `txCacheLoaded = false`), kick off a fetch and re-render once it
    // lands. Without this, opening the modal after a receive would show
    // "No transactions yet" even though the receipt is in the DB — the cache
    // was only being refreshed by the drawer's lazy load.
    renderModalTransactions(item.code, hour);
    txEnsureLoaded().then(() => {
      if (modal.classList.contains('open') && window._activeHour === hour) {
        renderModalTransactions(item.code, hour);
      }
    });

    // ---- Fire initial FIFO preview for the pre-filled qty ----
    hideAllocPanel();
    setTimeout(refreshAllocationPreview, 0);

    modal.classList.add('open');
    if (!pullClosed) setTimeout(() => input.select(), 100);
  }

  /* When the pull is closed, the Receive Goods modal becomes view-only:
     hide the input form, show the read-only banner, disable Confirm. */
  function applyModalReadOnlyMode() {
    const banner = document.getElementById('m-readonly-banner');
    const confirmBtn = document.getElementById('m-confirm');
    const formInputs = document.querySelectorAll('#modal .field input, #modal .field textarea, #modal .field select, #modal .qty-input, #modal .quick-btn');
    if (pullClosed) {
      banner.style.display = 'flex';
      confirmBtn.style.display = 'none';
      formInputs.forEach(el => el.setAttribute('disabled', 'disabled'));
      // Update the supervisor hint based on the current user's role
      const hint = document.getElementById('m-readonly-reopen-hint');
      const role = currentRole();
      hint.textContent = (role === 'supervisor' || role === 'admin')
        ? 'You can reopen this sheet from the toolbar.'
        : 'Only supervisors can reopen this sheet.';
    } else {
      banner.style.display = 'none';
      confirmBtn.style.display = '';
      formInputs.forEach(el => el.removeAttribute('disabled'));
    }
  }

  /* Read transactions store, filter for this (pull, item, hour), render rows. */
  function renderModalTransactions(itemCode, hour) {
    const pullId = (typeof currentPull !== 'undefined' && currentPull) ? currentPull : '';
    const allTx = (typeof txLoad === 'function') ? txLoad() : [];
    const list = allTx
      .filter(r => r.pullId === pullId && r.itemCode === itemCode && r.hour === hour)
      .sort((a, b) => new Date(b.receivedAt) - new Date(a.receivedAt));

    // Update count + drawer link
    const countEl = document.getElementById('m-tx-count');
    countEl.textContent = list.length;
    countEl.classList.toggle('has-tx', list.length > 0);
    const fullLink = document.getElementById('m-tx-full');
    fullLink.onclick = (e) => {
      e.preventDefault();
      closeModal();
      // Hand off context so the drawer pre-filters to this exact (item, hour) slot
      if (typeof openTxDrawer === 'function') openTxDrawer({ hour, itemCode });
    };

    const wrap = document.getElementById('m-tx-list');
    if (list.length === 0) {
      wrap.innerHTML = `<div class="m-tx-empty">No transactions yet for ${itemCode} at ${String(hour).padStart(2,'0')}:00</div>`;
      return;
    }

    // Show only the 2 most recent — the count badge above already shows the
    // total, and "View all in drawer →" handles the see-more case. Keeps the
    // modal compact so the receive form stays on screen on shorter laptops.
    const TOP_N = 2;
    const visible = list.slice(0, TOP_N);
    const overflow = list.length - visible.length;

    wrap.innerHTML = visible.map(r => {
      const isReversal = r.qty < 0;
      const isVoided = !!r.reversedBy;
      const cls = (isReversal ? 'reversal' : '') + (isVoided ? ' voided' : '');
      const pillCls = isReversal ? 'cancel' : (isVoided ? 'voided' : 'receive');
      const pillLabel = isReversal ? 'Cancel' : (isVoided ? 'Voided' : 'Receive');
      const qtyDisplay = isReversal
        ? `<span class="m-tx-qty neg">−${Math.abs(r.qty).toLocaleString()}</span>`
        : `<span class="m-tx-qty">${r.qty.toLocaleString()}</span>`;
      const canCancel = !isReversal && !isVoided && !pullClosed;
      const cancelBtnHtml = canCancel
        ? `<button class="m-tx-cancel-btn" data-tx-cancel="${escAttr(r.id)}" title="Cancel this receipt">
             <svg width="9" height="9" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M3 12a9 9 0 1 0 9-9"/><path d="M3 4v6h6"/></svg>
             Cancel
           </button>`
        : '';
      // §5b — compact single-token {PoNumber}·L## with vendor tooltip; 🔒 prefix when pull-locked
      const poToken = r.poNumber
        ? `<b>${escAttr(r.poNumber)}</b>${r.poLineNumber ? '·L' + escAttr(String(r.poLineNumber).padStart(2,'0')) : ''}`
        : '';
      const poBadge = r.poNumber
        ? `<div class="m-tx-po" title="${escAttr(r.vendorName || '')}">${currentPullLocked ? '<span class="po-lock">🔒</span>' : ''}${poToken}</div>`
        : '';
      return `
        <div class="m-tx-row ${cls}">
          <div class="m-tx-when">
            ${formatTxTime(r.receivedAt)}
            <small>${escAttr(r.id.slice(0, 12))}</small>
          </div>
          <div class="m-tx-meta">
            <b>${escAttr(r.lotBatch || '—')}</b> · ${escAttr(r.palletId || '—')}
            ${poBadge}
            <span class="m-tx-actor">By ${escAttr(r.receivedBy)}</span>
          </div>
          <div>
            <span class="m-tx-pill ${pillCls}">${pillLabel}</span>
            ${qtyDisplay}
          </div>
          <div class="m-tx-action">${cancelBtnHtml}</div>
        </div>
      `;
    }).join('');

    // Tail hint when there are more than the rendered top N. Click opens
    // the drawer pre-filtered to this (item, hour) — same handoff as the
    // "View all in drawer →" link in the header.
    if (overflow > 0) {
      wrap.innerHTML += `<a href="#" class="m-tx-more" data-tx-more>+ ${overflow} more — view in drawer</a>`;
      const moreEl = wrap.querySelector('[data-tx-more]');
      if (moreEl) {
        moreEl.addEventListener('click', (e) => {
          e.preventDefault();
          closeModal();
          if (typeof openTxDrawer === 'function') openTxDrawer({ hour, itemCode });
        });
      }
    }
  }

  /* Small helpers — defined here to avoid relying on drawer-only globals */
  function escAttr(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }
  function formatTxTime(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    if (isNaN(d)) return iso;
    return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  }

  function closeModal() {
    hideAllocPanel();
    modal.classList.remove('open');
  }

  /* ============================================================================
     v2 §7.2 + §3.5 FIFO allocation preview.
     - PO is the hard cap (§7.1 v2); the per-hour input is no longer force-clamped.
     - GET /api/receipts/preview returns either:
         200 { allocations[], totalAllocatable, shortage:0, scope }
              → render scope badge + per-line "QTY from PO-NUMBER L##" rows
         409 ProblemDetails { title, status:409 }
              → render the server's title in the warn slot, disable Confirm
              title is one of: "No PO linked to this pull. …"
                             | "Insufficient PO capacity. Need X, have Y pcs."
                             | "Pull is closed"
         400/403/404 → silently hide the panel (qty<=0 / scope / not found)
     ============================================================================ */
  let _allocDebounce = null;
  let _allocRequestSeq = 0;

  function hideAllocPanel() {
    const list = document.getElementById('m-alloc-list');
    const warn = document.getElementById('m-alloc-warning');
    if (list) { list.classList.remove('show'); list.innerHTML = ''; }
    if (warn) { warn.classList.remove('show'); warn.innerHTML = ''; }
    _previewBlocked = false;
    refreshVarianceUi();   // single owner of the Confirm gate
  }

  function scopeBadgeHtml(scope) {
    // §5.1 — three states. The overflow case must be checked BEFORE 'pull-locked',
    // because it is still a locked pull and would otherwise fall through to the
    // warehouse-wide badge and misreport what just happened.
    if (scope === 'pull-locked + variance overflow') {
      return '<span class="alloc-scope overflow" title="Accepted variance: allocation spilled past this pull’s PO into other open POs for the same vendor">⚠ Pull-locked + overflow</span>';
    }
    if (scope === 'pull-locked') {
      return '<span class="alloc-scope pull-locked" title="FIFO is restricted to POs linked to this pull (§3.5)">🔒 Pull-locked</span>';
    }
    return '<span class="alloc-scope warehouse-wide" title="FIFO walks every open PO in this warehouse">🌐 Warehouse-wide</span>';
  }

  function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[c]));
  }

  async function refreshAllocationPreview() {
    const item = items[activeRow];
    const pullItemId = item?.pullItemId;
    const list = document.getElementById('m-alloc-list');
    const warn = document.getElementById('m-alloc-warning');
    const btn  = document.getElementById('m-confirm');
    if (!pullItemId || !list || !warn || !btn) return;

    const qty = parseInt(document.getElementById('m-input').value, 10) || 0;
    if (qty <= 0) { hideAllocPanel(); return; }

    const seq = ++_allocRequestSeq;
    try {
      // v2.1 Hour Cap — pass &hour= so the server can surface "Insufficient hour
      // capacity" 409 in the preview before walking PO lines. The active hour
      // comes from openModal (stored on window._activeHour); omit if absent
      // (no harm — Receive's commit-time check is the authoritative gate).
      const hour = (typeof window._activeHour === 'number') ? window._activeHour : null;
      // db/047 §2c — the preview must be asked the SAME question confirm will be asked,
      // flag included. Without it the preview would evaluate an over-quantity as
      // unticked and refuse a receive the operator has already acknowledged.
      const variance = !document.getElementById('m-variance-block')?.hidden
                       && !!document.getElementById('m-variance')?.checked;
      const url = `/api/receipts/preview?pullItemId=${encodeURIComponent(pullItemId)}&qty=${qty}`
                + (hour !== null ? `&hour=${hour}` : '')
                + `&varianceAccepted=${variance}`;
      const r = await fetch(url);
      if (seq !== _allocRequestSeq) return;   // stale response — newer typing replaced it

      if (r.status === 409) {
        // Insufficient PO capacity | No PO linked | Pull is closed — server's title is wire contract.
        let title = 'Cannot allocate this quantity';
        try { const j = await r.json(); if (j?.title) title = j.title; } catch {}
        list.classList.remove('show');
        list.innerHTML = '';
        warn.innerHTML = `${scopeBadgeHtml(item?.scopeHint || 'warehouse-wide')}<span>${escapeHtml(title)}</span>`;
        warn.classList.add('show');
        _previewBlocked = true;
        refreshVarianceUi();
        return;
      }
      if (!r.ok) {
        // 400 (qty<=0 race) / 403 (warehouse scope) / 404 (pullItem) — hide silently.
        hideAllocPanel();
        return;
      }

      const p = await r.json();   // { allocations, totalAllocatable, shortage:0, scope }
      warn.classList.remove('show');
      warn.innerHTML = '';

      // Cache the scope so a subsequent 409 (e.g. drained PO) can still show the right badge.
      if (item) item.scopeHint = p.scope || 'warehouse-wide';

      // §6.2 — a slice drawn from a PO that is not linked to this pull is marked inline,
      // so the operator sees they are drawing on another PO BEFORE confirming. The server
      // decides isPullLinked from the plan it built; the badge never infers it from qty.
      const lines = (p.allocations || []).map(a => {
        const overflow = a.isPullLinked === false;
        const tag = overflow
          ? ' <span class="alloc-overflow-tag" title="Not linked to this pull — drawn from another open PO for the same vendor">other PO</span>'
          : '';
        return `<span class="alloc-line${overflow ? ' is-overflow' : ''}">${a.qty.toLocaleString()} from <b>${escapeHtml(a.poNumber)}</b> · L${a.poLineNumber}${tag}</span>`;
      }).join('');
      const header = (p.allocations || []).length > 1
        ? `<span class="alloc-line"><b>Will allocate ${qty.toLocaleString()} pcs across ${p.allocations.length} POs:</b></span>`
        : `<span class="alloc-line"><b>Will allocate:</b></span>`;
      list.innerHTML = `${scopeBadgeHtml(p.scope)}${header}${lines}`;
      list.classList.add('show');
      _previewBlocked = false;
      refreshVarianceUi();
    } catch (e) {
      // Network/transport — hide preview rather than block the user.
      hideAllocPanel();
    }
  }

  // ==========================================================================
  // db/047 §7 — accept-variance UI.
  //
  // One function owns the whole derived state: checkbox visibility, the live
  // variance readout, the note's required styling and the Confirm gate. Every
  // input path calls it, so the four can never disagree with each other — which
  // is the failure this change exists to remove, one layer up from the wire.
  //
  // The client mirrors the server rules from §2c/§2f exactly. It is a
  // convenience, never the enforcement: the same request refused here is
  // refused by ReceiveAsync, with the same code.
  // ==========================================================================

  // db/047 §2f — the lock marker, written once on open.
  //
  // Stated as context, not discovered through a rejection. On a locked pull it names
  // the ceiling so the operator knows the limit before typing; on an unlocked pull it
  // says quietly that over IS possible, which is the fact they otherwise have to
  // establish by trial. Neutral in both cases: nothing here is wrong yet.
  function renderCapLock(outstanding) {
    const box  = document.getElementById('m-cap-lock');
    const text = document.getElementById('m-cap-lock-text');
    if (!box || !text) return;

    // §2f (rev 11) — the copy no longer varies by LockHourCap, because the outcome no
    // longer does. "HOUR CAP LOCKED · CANNOT RECEIVE OVER 1,000" described the old rule
    // and became false the moment the tick was made the escape on every pull; a marker
    // that states a limit the system does not enforce is the same defect as the clamp
    // hint that said over was allowed when it was not.
    //
    // The hour figure stays as context — it is still what the plan says to expect, and
    // it is the number the variance is measured against.
    box.classList.remove('is-locked');
    text.textContent =
      `Planned for this hour: ${(outstanding | 0).toLocaleString()} · over is possible with the final-receipt box`;
    box.hidden = false;
  }

  // The (item, hour) slot the modal is currently open on.
  function currentSlotMeta() {
    const item = items[activeRow] || {};
    const hour = window._activeHour;
    const slot = (item.schedule || {})[hour] || {};
    return {
      item,
      hour,
      multiWindow:  (item.winCount || 1) > 1,   // §2c guard — variance not offered
      closed:       !!slot.c,
      closedAt:     slot.ca || null,
      closedReason: slot.cr || null,
      reasonCode:   slot.rc || null,   // db/049
      reasonLabel:  slot.rl || null,
    };
  }

  // ==========================================================================
  // db/047 §2d — closed-state modal.
  //
  // Clicking a closed window opens THIS modal in a closed state rather than a
  // separate surface or a dead quantity box. Everything to do with entering a
  // receipt is hidden; what replaces it is the record of the close — who, when,
  // the reason in full, and the final figures — plus a single Reopen line button.
  // ==========================================================================
  function renderClosedState(meta) {
    const closed  = !!meta.closed;
    const banner  = document.getElementById('m-closed-banner');
    const confirm = document.getElementById('m-reopen-confirm');

    // Everything that belongs to entering a quantity.
    const receiveOnly = [
      document.getElementById('m-receive-block'),
      document.getElementById('m-cap-lock'),   // db/047 §2f — a ceiling is moot once closed
      document.getElementById('cap-hint'),
      document.getElementById('m-variance-block'),
      document.querySelector('.quick-fill'),
      document.querySelector('.fields-grid'),
      document.getElementById('m-alloc-list'),
      document.getElementById('m-alloc-warning'),
    ];
    for (const el of receiveOnly) if (el) el.hidden = closed;

    // The quick-fill buttons are disabled as well as hidden: hiding alone would
    // still leave them clickable via the keyboard if the modal is ever restyled.
    document.querySelectorAll('.quick-fill button').forEach(b => { b.disabled = closed; });

    const confirmBtn = document.getElementById('m-confirm');
    if (confirmBtn) confirmBtn.hidden = closed;

    if (banner)  banner.hidden  = !closed;
    if (confirm) confirm.hidden = true;          // always collapsed on (re)open

    if (!closed) return;

    // ---- populate the banner ----
    const item = meta.item || {};
    const slot = (item.schedule || {})[meta.hour] || {};
    const expected = slot.e | 0, received = slot.r | 0;
    const variance = received - expected;        // negative = short, positive = over

    const when = meta.closedAt ? new Date(meta.closedAt) : null;
    const whenTxt = when && !isNaN(when)
      ? when.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
      : 'date unknown';
    const who = document.getElementById('m-closed-who');
    if (who) who.textContent = `Closed ${whenTxt}`;

    const figures = document.getElementById('m-closed-figures');
    if (figures) {
      const label = variance < 0 ? 'short' : variance > 0 ? 'over' : 'exact';
      figures.innerHTML = `
        <span><b>${expected.toLocaleString()}</b> expected</span>
        <span><b>${received.toLocaleString()}</b> received</span>
        <span class="slotclose-variance ${variance < 0 ? 'short' : variance > 0 ? 'over' : ''}">
          <b>${variance > 0 ? '+' : ''}${variance.toLocaleString()}</b> ${label}
        </span>`;
    }

    const reason = document.getElementById('m-closed-reason');
    if (reason) {
      // db/049 — the structured reason leads; the free text follows only if there is any.
      //
      // Three cases, and the third is why this is not a one-liner:
      //   code + note → "ส่งเกิน — vendor shipped a full pallet"
      //   code only   → "ส่งเกิน"
      //   NEITHER     → "(no reason recorded)". That is a window closed BEFORE reason
      //                 codes existed. It must not be dressed up as อื่นๆ/OTHER, which
      //                 would attribute a decision to an operator who never made one.
      //
      // The label is always the server's; a raw code is never shown. If a code somehow
      // arrives without a label (unknown to this build) the code is suppressed rather
      // than printed, and the note alone carries the display.
      const label = meta.reasonLabel || null;
      const note  = meta.closedReason || null;
      const parts = [label, note].filter(Boolean);
      reason.textContent = parts.length ? parts.join(' — ') : '(no reason recorded)';
      reason.classList.toggle('is-empty', parts.length === 0);
    }
  }

  function refreshVarianceUi() {
    const input = document.getElementById('m-input');
    const box   = document.getElementById('m-variance');
    const block = document.getElementById('m-variance-block');
    const hint  = document.getElementById('cap-hint');
    const text  = document.getElementById('cap-hint-text');
    const btn   = document.getElementById('m-confirm');
    const noteEl    = document.getElementById('m-note');
    const noteLabel = document.getElementById('m-note-label');
    const noteMsg   = document.getElementById('m-note-required-msg');
    if (!input || !box || !block || !btn) return;

    const qty = parseInt(input.value) || 0;
    const outstanding = activeMax | 0;
    const meta = currentSlotMeta();

    const over  = qty > outstanding;
    const exact = qty === outstanding;
    const under = qty < outstanding;

    // §2f (rev 11) — LockHourCap no longer affects whether the box is offered. The
    // tick is the escape on every pull, so withholding it on a locked pull would now
    // hide the only route to a legitimate over-receipt.
    //
    // Hidden when the quantity exactly matches outstanding (§7): there is no variance
    // to accept, and the server ignores the flag in that case anyway.
    const canOffer = !exact && !meta.multiWindow;

    if (!canOffer && box.checked) box.checked = false;   // never leave a stale tick
    block.hidden = !canOffer;
    block.classList.toggle('is-required', canOffer && over);

    const ticked  = canOffer && box.checked;
    const noteVal = (noteEl?.value || '').trim();

    // ---- db/049 reason dropdown -------------------------------------------------
    // Offered exactly when a variance is actually being accepted. Options are filtered
    // to the direction, because offering "ส่งเกิน" on a short close is noise that
    // invites a wrong click — the server refuses it anyway.
    const reasonBlock = document.getElementById('m-reason-block');
    const reasonEl    = document.getElementById('m-reason');
    const reasonMsg   = document.getElementById('m-reason-required-msg');
    const direction   = over ? 'over' : 'short';   // qty === outstanding never reaches here

    if (reasonBlock) reasonBlock.hidden = !ticked;
    if (ticked) renderReasonOptions(direction);
    else if (reasonEl) reasonEl.value = '';        // never carry a stale pick into the next open

    const reasonVal  = ticked ? (reasonEl?.value || '') : '';
    const isOther    = reasonVal === 'OTHER';
    // Mirrors the server's floor exactly (VarianceReasonCodes.MinNoteLength). Trimmed, so
    // "   " fails and so does "." — the input this whole change exists to stop.
    const noteOk     = noteVal.length >= 3;
    const noteNeeded = isOther && !noteOk;

    if (reasonEl)  reasonEl.classList.toggle('is-error', ticked && !reasonVal);
    if (reasonMsg) reasonMsg.hidden = !(ticked && !reasonVal);

    // ---- live variance readout -------------------------------------------------
    // The <b id="cap-hint-max"> wrapper must survive every rewrite: openModal and the
    // cancel-refresh path both grab it by id, and losing it makes the next openModal
    // throw "Cannot set properties of null".
    const pcs = n => `<b id="cap-hint-max">${Math.abs(n).toLocaleString()}</b>`;
    let cls = 'neutral', msg;
    if (meta.closed) {
      cls = 'error';
      msg = `LINE CLOSED · ${pcs(outstanding)} PCS WERE WRITTEN OFF`;
    } else if (over) {
      cls = 'warn';   // amber
      msg = `OVER BY ${pcs(qty - outstanding)} PCS · REQUIRES ACCEPT VARIANCE`;
    } else if (exact) {
      cls = 'ok';     // green
      msg = `COMPLETES THE LINE · ${pcs(qty)} PCS`;
    } else if (under && ticked) {
      cls = 'error';  // red — only once the operator says so
      msg = `SHORT CLOSE · ${pcs(outstanding - qty)} PCS WRITTEN OFF`;
    } else if (qty === 0) {
      cls = 'neutral';
      msg = `NOTHING RECEIVED · TICK TO CLOSE THE LINE SHORT BY ${pcs(outstanding)} PCS`;
    } else {
      // §7 — an under-receipt is NOT an error state until the operator ticks the box.
      cls = 'neutral';
      msg = `PARTIAL · ${pcs(outstanding - qty)} PCS WILL REMAIN OUTSTANDING`;
    }
    if (text) text.innerHTML = msg;
    if (hint) {
      hint.classList.remove('ok', 'warn', 'error');
      if (cls !== 'neutral') hint.classList.add(cls);
    }

    // ---- note: THREE states, rendered distinctly (db/049) -----------------------
    //
    // The old code rendered two states ('Note · Required' / 'Note (optional)') keyed on
    // the tick alone. With the note required only for OTHER there are three conditions,
    // and collapsing three into two is how the "." habit forms: a field that says
    // "Required" when it is not teaches the operator to satisfy it without reading it.
    //
    //   no variance            → "Note (optional)", neutral placeholder
    //   variance, real code    → "Note (optional)"  + a placeholder that INVITES detail
    //   variance, OTHER        → "Note · Required"  + a placeholder that DEMANDS it
    if (noteLabel) noteLabel.textContent = isOther ? 'Note · Required' : 'Note (optional)';
    if (noteEl) {
      noteEl.placeholder =
          isOther ? 'Required — describe what happened (min 3 characters)'
        : ticked  ? 'Optional — anything useful about this delivery'
        :           'Any discrepancy, damage, or instruction…';
      noteEl.classList.toggle('is-error', noteNeeded);
    }
    if (noteMsg) noteMsg.hidden = !noteNeeded;

    // ---- Confirm gate (§7) -----------------------------------------------------
    btn.disabled =
         meta.closed                       // already closed — nothing to add
      || _previewBlocked                   // the server's preview refused this quantity
      || (over && !ticked)                 // over needs the tick
      || (ticked && !reasonVal)            // db/049 — a variance needs a reason CODE
      || noteNeeded                        // db/049 — and OTHER needs a real note with it
      || (qty === 0 && !ticked)            // zero records nothing unless it closes
      || qty < 0;
  }

  // db/049 — the dropdown's options, fetched once and cached. The labels live only on the
  // server (VarianceReasonCodes.cs); this file holds none, so a label change never needs a
  // JS edit. Fetched lazily on first use rather than at page load: most receives are
  // ordinary partials that never open this control.
  let _reasonCache = null;
  let _reasonDirection = null;

  async function loadReasons() {
    if (_reasonCache) return _reasonCache;
    try {
      const res = await fetch('/api/receipts/variance-reasons', { credentials: 'same-origin' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      _reasonCache = await res.json();
    } catch (err) {
      // Leave the cache empty so a later attempt retries. The Confirm gate keeps the
      // button disabled while no reason is selected, so a failed fetch cannot let an
      // unreasoned variance through — it blocks the receive rather than silently
      // allowing one, which is the correct direction to fail in.
      console.error('[receiving] could not load variance reasons', err);
      _reasonCache = null;
    }
    return _reasonCache;
  }

  async function renderReasonOptions(direction) {
    const sel = document.getElementById('m-reason');
    if (!sel) return;
    const reasons = await loadReasons();
    if (!reasons) return;

    // Only rebuild when the direction actually changed — the operator types continuously
    // and rebuilding on every keystroke would discard a selection mid-edit.
    if (_reasonDirection === direction && sel.options.length > 1) return;
    _reasonDirection = direction;

    const keep = sel.value;
    const valid = reasons.filter(r => direction === 'over' ? r.validOver : r.validShort);

    sel.innerHTML = '';
    const ph = document.createElement('option');
    ph.value = ''; ph.disabled = true; ph.selected = true;
    ph.textContent = '— select a reason —';
    sel.appendChild(ph);

    for (const r of valid) {
      const o = document.createElement('option');
      o.value = r.code;              // the code is the value; logic never reads the label
      o.textContent = r.label;       // server-provided; never constructed here
      sel.appendChild(o);
    }

    // Preserve a still-valid selection across a direction flip (over → short can happen
    // mid-typing); drop it silently if the new direction does not allow it.
    if (keep && valid.some(r => r.code === keep)) sel.value = keep;
  }

  document.getElementById('m-input').addEventListener('input', (e) => {
    if ((parseInt(e.target.value) || 0) < 0) { e.target.value = 0; }
    refreshVarianceUi();

    // Debounced FIFO preview (~200ms)
    clearTimeout(_allocDebounce);
    _allocDebounce = setTimeout(refreshAllocationPreview, 200);
  });

  document.getElementById('m-variance').addEventListener('change', () => {
    refreshVarianceUi();
    clearTimeout(_allocDebounce);
    _allocDebounce = setTimeout(refreshAllocationPreview, 200);
  });

  document.getElementById('m-note').addEventListener('input', refreshVarianceUi);

  // db/049 — picking a reason changes whether the note is required (OTHER) and clears the
  // Confirm gate, so the same repaint has to run.
  document.getElementById('m-reason')?.addEventListener('change', refreshVarianceUi);

  // ---- db/047 §2d — reopen ------------------------------------------------
  document.getElementById('m-reopen-btn').addEventListener('click', () => {
    const panel  = document.getElementById('m-reopen-confirm');
    const reason = document.getElementById('m-reopen-reason');
    const meta   = currentSlotMeta();
    const slot   = (meta.item.schedule || {})[meta.hour] || {};
    const outstanding = Math.max(0, (slot.e | 0) - (slot.r | 0));
    const sub = document.getElementById('m-reopen-sub');
    if (sub) sub.textContent =
      `The line returns to the pending queue with ${outstanding.toLocaleString()} pcs outstanding.`;
    if (reason) { reason.value = ''; }
    document.getElementById('m-reopen-go').disabled = true;
    if (panel) panel.hidden = false;
    reason?.focus();
  });

  document.getElementById('m-reopen-cancel').addEventListener('click', () => {
    document.getElementById('m-reopen-confirm').hidden = true;
  });

  // Reason is required client-side too; the server refuses independently with
  // 400 REOPEN_REASON_REQUIRED, so this is a convenience, not the enforcement.
  document.getElementById('m-reopen-reason').addEventListener('input', (e) => {
    document.getElementById('m-reopen-go').disabled = (e.target.value || '').trim().length === 0;
  });

  document.getElementById('m-reopen-go').addEventListener('click', async () => {
    const btn    = document.getElementById('m-reopen-go');
    const reason = (document.getElementById('m-reopen-reason').value || '').trim();
    const meta   = currentSlotMeta();
    if (!reason || !meta.item?.pullItemId) return;

    btn.disabled = true;

    // The try wraps ONLY the request. It used to wrap the DOM updates below too,
    // which meant a client-side slip (a mistyped render function) was caught here
    // and reported to the operator as "Network error" on a request the server had
    // already committed — the screen contradicting the system, one more time.
    let resp;
    try {
      resp = await fetch('/api/receipts/reopen', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pullItemId: meta.item.pullItemId, hourOfDay: meta.hour, reason }),
      });
    } catch (err) {
      showToast('Cannot reopen line', 'Network error — try again', 'error');
      btn.disabled = false;
      return;
    }

    if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!resp.ok) {
      let title = `Reopen rejected (${resp.status})`;
      try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
      showToast('Cannot reopen line', title, 'error');
      btn.disabled = false;
      return;
    }

    // Update local state in place and return the modal to its receive state —
    // §2d requires no page reload.
    const slot = (meta.item.schedule || {})[meta.hour];
    if (slot) { slot.c = false; slot.ca = null; slot.cr = null; }
    document.getElementById('m-reopen-confirm').hidden = true;
    renderClosedState(currentSlotMeta());
    activeMax = Math.max(0, (slot?.e | 0) - (slot?.r | 0));
    const inp = document.getElementById('m-input');
    if (inp) { inp.removeAttribute('max'); inp.value = activeMax; }
    const capMax = document.getElementById('cap-hint-max');
    if (capMax) capMax.textContent = activeMax.toLocaleString();
    refreshVarianceUi();
    render();                 // repaint the grid so the CLOSED pill clears
    showToast('Line reopened', `${activeMax.toLocaleString()} pcs outstanding again`, 'success');
  });

  document.getElementById('m-close').addEventListener('click', closeModal);
  document.getElementById('m-cancel').addEventListener('click', closeModal);
  modal.addEventListener('click', (e) => { if (e.target === modal) closeModal(); });

  document.querySelectorAll('.quick-fill button').forEach(b => {
    b.addEventListener('click', () => {
      const action = b.dataset.fill;
      const input = document.getElementById('m-input');
      if (action === 'all') input.value = activeMax;
      else if (action === 'half') input.value = Math.floor(activeMax / 2);
      else if (action === '0') input.value = 0;

      // db/047 §2e — setting .value in script does NOT fire an `input` event, so the
      // debounced preview and the variance readout never recomputed. The panel kept
      // advertising the previous quantity (observed: input reading 0 while the panel
      // promised "Will allocate: 1,000") and the hint snapped back to stale copy.
      // Same defect class as the clamp: the screen states one thing, the system uses
      // another. Dispatch a real event so every listener recomputes.
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
  });

  document.getElementById('m-confirm').addEventListener('click', () => { confirmReceipt(); });

  // Stage B: POST /api/receipts and reflect the server's new ReceivedQty into the
  // local schedule. Optional fields (lot, pallet, bin, qc, note) — collect from the
  // modal if present so existing markup keeps wiring; default qcStatus = 'pending'.
  async function confirmReceipt() {
    // db/047 §2c — NEVER silently rewrite an entered quantity.
    //
    // This used to be `Math.min(inputVal, activeMax)`. Typing 1,500 against 1,000
    // outstanding POSTed 1,000: no alert, no error, and the modal had already
    // promised "Will allocate: 1,500" one screen earlier. The operator believed
    // they had recorded 1,500 and the line showed 100% complete. That is silent
    // data loss, not a limit — and the server would have accepted 1,500 anyway.
    //
    // The quantity the operator typed is the quantity that goes on the wire. It is
    // either recorded at that figure or refused with a visible error; nothing in
    // between.
    const qty = parseInt(document.getElementById('m-input').value) || 0;
    if (qty <= 0) {
      showToast('Enter a quantity', 'Must be greater than zero', 'error');
      return;
    }
    const item = items[activeRow];
    const hour = window._activeHour;
    if (!item?.pullItemId) {
      showToast('Cannot save receipt', 'Item is missing its server id — reload the page', 'error');
      return;
    }
    const fieldVal = (id) => { const el = document.getElementById(id); return el ? (el.value || '').trim() : ''; };
    const body = {
      pullItemId:  item.pullItemId,
      hourOfDay:   hour,
      qty,
      lotBatch:    fieldVal('m-lot') || null,
      palletId:    fieldVal('m-pallet') || null,
      binLocation: fieldVal('m-bin') || null,
      qcStatus:    fieldVal('m-qc') || 'pending',
      note:        fieldVal('m-note') || null,
      // db/047 — only send true when the box is actually offered AND ticked. The
      // server re-derives everything from the quantity anyway, but sending a flag the
      // operator could not see would be a lie in the other direction.
      varianceAccepted: !document.getElementById('m-variance-block')?.hidden
                        && !!document.getElementById('m-variance')?.checked,
      // db/049 — send the code only when its control was actually on screen, for the same
      // reason as the flag above. Null on an exact-quantity receive, where the server
      // ignores it because that is not a variance.
      varianceReasonCode: (!document.getElementById('m-reason-block')?.hidden
                           && document.getElementById('m-reason')?.value) || null,
    };

    const btn = document.getElementById('m-confirm');
    btn.disabled = true;
    try {
      const resp = await fetch('/api/receipts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!resp.ok) {
        // ASP.NET Problem returns { title, status, ... }; surface title as toast.
        let title = `Receipt rejected (${resp.status})`;
        try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
        showToast('Cannot save receipt', title, 'error');
        return;
      }
      const result = await resp.json();   // v2: { allocations[], totalQty, newReceivedQty, fullyReceived }
      const slot = item.schedule[hour];
      if (slot) {
        slot.r = result.newReceivedQty;
        // db/047 §6 — the response carries the window's post-transaction
        // IsClosed precisely so the client can update without a refetch. It
        // was being dropped, so a just-short-closed window kept `c = false`
        // until the next page load: the cell rendered as an ordinary partial
        // and the header counted it as pending, disagreeing with a database
        // that had already closed it. The reopen path at ~line 1200 has
        // always written the symmetric `slot.c = false`; only this direction
        // was missing.
        //
        // Guarded on `!== undefined` so an older server build that predates
        // the field cannot silently flip a closed window back to open.
        if (result.isClosed !== undefined) slot.c = !!result.isClosed;
        if (slot.c) {
          // Close metadata the closed-state modal reads. ClosedAt is not on
          // the receive response — stamp it locally so the modal has
          // something to show; the next load replaces it with the server's.
          slot.ca = slot.ca || new Date().toISOString();
          slot.cr = body.note || slot.cr || null;
          slot.rc = body.varianceReasonCode || slot.rc || null;
          slot.rl = null;   // label is server-owned; blank until the next load
        }
      }
      // Drop the cached journal — drawer will refetch lazily on open, picks up the
      // N new receipt rows (one per FIFO allocation slice) with PO context.
      txCache.length = 0;
      txCacheLoaded = false;

      render();
      requestAnimationFrame(() => {
        const updated = document.querySelector(`.hour-btn[data-row="${activeRow}"][data-col="${activeCol}"]`);
        if (updated) updated.classList.add('just-updated');
      });
      // §9.3 v2 — surface FIFO split count in the toast subtitle.
      const splitCount = (result.allocations || []).length;
      const totalQty = result.totalQty ?? qty;
      const subtitle = splitCount > 1
        ? `${item.code} · +${totalQty.toLocaleString()} pcs · split across ${splitCount} POs`
        : `${item.code} · +${totalQty.toLocaleString()} pcs`;
      showToast('Receipt confirmed', subtitle, 'default');
      closeModal();
    } catch (e) {
      console.error('confirmReceipt failed', e);
      showToast('Network error', 'Could not reach server', 'error');
    } finally {
      btn.disabled = false;
    }
  }

  // ============ CLOSE PULL MODAL ============
  const closeModalEl = document.getElementById('close-modal');
  const sigHost = document.getElementById('sig-host');
  // Phase 8b — the canvas drawing is now the shared SignaturePad component.
  const sigPad = window.SignaturePad.mount(document.getElementById('sig-canvas'), {
    onChange: (hasInk) => {
      sigHost.classList.toggle('signed', hasInk);
      document.getElementById('cm-confirm').disabled = !hasInk;
    },
  });
  function clearSignature() { sigPad.clear(); }
  document.getElementById('sig-clear').addEventListener('click', clearSignature);

  function openCloseModal() {
    if (pullClosed) return;
    if (!isFullyReceived()) return;

    // Populate summary — based on the WHOLE pull sheet (all hours of all schedules)
    let exp = 0, rec = 0, active = 0, canceled = 0, newCount = 0;
    items.forEach(i => {
      if (i.status === 'canceled') { canceled++; return; }
      active++;
      if (i.status === 'new') newCount++;
      Object.values(i.schedule).forEach(slot => {
        if (slot.e > 0) { exp += slot.e; rec += slot.r; }
      });
    });

    const pullId = currentPull || '';
    document.getElementById('cm-pullid').textContent = pullId;
    document.getElementById('cm-decl-id').textContent = pullId;
    document.getElementById('cm-received').textContent = rec.toLocaleString();
    document.getElementById('cm-items').textContent = active + ' SKUs';
    document.getElementById('cm-items-sub').textContent = `${canceled} canceled · ${newCount} new`;

    const now = new Date();
    const dateStr = now.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) +
      ', ' + now.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) + ' ICT';
    document.getElementById('cm-date').textContent = dateStr;

    closeModalEl.classList.add('open');
    requestAnimationFrame(() => { sigPad.resize(); sigPad.clear(); });
  }

  function closeCloseModal() { closeModalEl.classList.remove('open'); }

  document.getElementById('btn-close-pull').addEventListener('click', openCloseModal);
  document.getElementById('cm-close').addEventListener('click', closeCloseModal);
  document.getElementById('cm-cancel').addEventListener('click', closeCloseModal);
  closeModalEl.addEventListener('click', (e) => { if (e.target === closeModalEl) closeCloseModal(); });

  // Stage B: §7.4 close — POST signature to server, then reflect closed state.
  document.getElementById('cm-confirm').addEventListener('click', async () => {
    if (sigPad.isEmpty()) return;
    if (!currentPullId) {
      showToast('Cannot close', 'Pull not loaded yet', 'error');
      return;
    }
    const btn = document.getElementById('cm-confirm');
    btn.disabled = true;
    try {
      // Canvas exports PNG; the server column NVARCHAR(MAX) stores the data URL verbatim.
      const sig = sigPad.toDataUrl();
      const resp = await fetch(`/api/pulls/${encodeURIComponent(currentPullId)}/close`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ signatureSvg: sig }),
      });
      if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!resp.ok) {
        let title = `Close rejected (${resp.status})`;
        try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
        showToast('Cannot close', title, 'error');
        return;
      }
      pullClosed = true;
      serverPullStatus = 'closed';
      document.body.classList.add('pull-closed');
      document.getElementById('closed-banner').classList.add('show');
      updateCloseButton();
      closeCloseModal();
      showToast('Pull sheet closed & locked', 'Signature recorded · records archived', 'success-big');
    } catch (e) {
      console.error('close failed', e);
      showToast('Network error', 'Could not reach server', 'error');
    } finally {
      btn.disabled = false;
    }
  });

  // ============ REOPEN HANDLER (supervisor / admin only) — §7.5 ============
  document.getElementById('btn-reopen-pull').addEventListener('click', async () => {
    if (!pullClosed) return;
    if (!canReopenPull()) {
      showToast('Reopen not allowed', 'Supervisors only', 'error');
      return;
    }
    if (!currentPullId) return;
    const reason = prompt(
      `Reopen pull sheet ${currentPull}?\n\n` +
      `This will unlock the sheet for further editing. The previous close signature stays in the audit log, ` +
      `and a "reopen" event will be recorded with your name and timestamp.\n\n` +
      `Reason (required):`
    );
    if (reason === null) return;                          // user cancelled
    if (!reason || !reason.trim()) {
      showToast('Reopen needs a reason', 'Empty reason was rejected', 'error');
      return;
    }
    try {
      const resp = await fetch(`/api/pulls/${encodeURIComponent(currentPullId)}/reopen`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ reason: reason.trim() }),
      });
      if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
      if (!resp.ok) {
        let title = `Reopen rejected (${resp.status})`;
        try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
        showToast('Cannot reopen', title, 'error');
        return;
      }
      pullClosed = false;
      serverPullStatus = 'in_progress';
      document.body.classList.remove('pull-closed');
      document.getElementById('closed-banner').classList.remove('show');
      updateCloseButton();
      showToast('Pull sheet reopened', 'Sheet is now editable again');
    } catch (e) {
      console.error('reopen failed', e);
      showToast('Network error', 'Could not reach server', 'error');
    }
  });

  // ============ TOAST ============
  function showToast(msg, sub, kind) {
    const toast = document.getElementById('toast');
    toast.className = 'toast' + (kind === 'success-big' ? ' success-big' : kind === 'error' ? ' error' : '');
    document.getElementById('toast-msg').textContent = msg;
    document.getElementById('toast-sub').textContent = sub;
    document.getElementById('toast-icon').textContent = kind === 'error' ? '!' : '✓';
    toast.classList.add('show');
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => toast.classList.remove('show'), 2800);
  }

  // ============ KEYBOARD ============
  document.addEventListener('keydown', (e) => {
    if (modal.classList.contains('open')) {
      if (e.key === 'Escape') closeModal();
      // db/047 §7 — the keyboard path obeys the same gate as the button. It must not
      // be a way round the checkbox or the required note.
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        const btn = document.getElementById('m-confirm');
        if (btn && btn.disabled) return;
        confirmReceipt();
      }
    }
    if (closeModalEl.classList.contains('open')) {
      if (e.key === 'Escape') closeCloseModal();
    }
  });

  document.getElementById('period-select').addEventListener('change', () => {
    const sel = document.getElementById('period-select');
    const start = parseInt(sel.value);
    document.querySelectorAll('thead th.hour-col').forEach((th, i) => {
      const h = (start + i) % 24;
      th.querySelector('.hour-num').textContent = String(h).padStart(2,'0') + '.00';
    });
    // Update footer indicator
    document.getElementById('footer-period').textContent = sel.options[sel.selectedIndex].text;
    render();
    updatePeriodNowAffordances();
  });

  // ============ PERIOD STEPPER (prev / next / NOW badge / Jump to now) ============
  // Walks the period-select options as a cyclic list. "Now" = the period whose
  // 4-hour window contains the current wall-clock hour. Auto-select on load so
  // the receiver lands on the right period without having to choose.
  function periodStartContainingNow() {
    const h = new Date().getHours();
    const opts = Array.from(document.getElementById('period-select').options)
      .map(o => parseInt(o.value, 10));
    // Each option's window is [start, start+4) wrapped at 24. Find the first
    // option whose window contains h.
    for (const s of opts) {
      const end = (s + 4) % 24;
      const inWindow = end > s ? (h >= s && h < end) : (h >= s || h < end);
      if (inWindow) return s;
    }
    return opts[0];  // shouldn't happen — the 6 periods tile 24h
  }

  function updatePeriodNowAffordances() {
    const sel = document.getElementById('period-select');
    if (!sel) return;
    const now = periodStartContainingNow();
    const cur = parseInt(sel.value, 10);
    const isOnNow = cur === now;
    document.getElementById('period-now-badge')?.classList.toggle('show', isOnNow);
    document.getElementById('period-jump-now')?.classList.toggle('show', !isOnNow);
  }

  function stepPeriod(delta) {
    const sel = document.getElementById('period-select');
    const opts = Array.from(sel.options);
    const cur = opts.findIndex(o => o.value === sel.value);
    const next = (cur + delta + opts.length) % opts.length;
    sel.value = opts[next].value;
    sel.dispatchEvent(new Event('change'));
  }

  function jumpPeriodToNow() {
    const sel = document.getElementById('period-select');
    const now = periodStartContainingNow();
    const target = String(now).padStart(2, '0');
    if (sel.value === target) return;
    sel.value = target;
    sel.dispatchEvent(new Event('change'));
  }

  document.getElementById('period-prev')?.addEventListener('click', () => stepPeriod(-1));
  document.getElementById('period-next')?.addEventListener('click', () => stepPeriod(+1));
  document.getElementById('period-jump-now')?.addEventListener('click', (e) => {
    e.preventDefault();
    jumpPeriodToNow();
  });

  // Auto-select the current period on load (overrides the hardcoded `selected`
  // in the Razor markup). Fires the existing change handler so the grid header
  // + footer + body all update together. Safe to call before items load —
  // render() handles the empty state.
  jumpPeriodToNow();
  updatePeriodNowAffordances();

  // ============ EXPORT TO EXCEL ============
  function buildExportRows() {
    const pullId = currentPull || '';
    const whSel = document.getElementById('warehouse-select');
    const warehouse = whSel.options[whSel.selectedIndex].text;
    const now = new Date();
    const exportedAt = now.toLocaleString('en-GB');

    // ---- Sheet 1: Detail (one row per item × scheduled hour) ----
    const detail = [];
    items.forEach(item => {
      const hours = Object.keys(item.schedule).map(Number).sort((a,b)=>a-b);
      hours.forEach(h => {
        const slot = item.schedule[h];
        if (slot.e <= 0) return;
        const outstanding = slotOutstanding(slot);
        const pct = slot.e > 0 ? (slot.r / slot.e) : 0;
        // 'Closed short' is its own status for the same reason the grid has a
        // CLOSED cell state: exporting a written-off line as 'Partial' tells
        // whoever reads the spreadsheet that a delivery is still coming.
        const cellStatus = (item.status === 'canceled') ? 'Canceled'
                         : (slot.r >= slot.e) ? 'Complete'
                         : slot.c ? 'Closed short'
                         : (slot.r > 0) ? 'Partial' : 'Pending';
        detail.push({
          'Pull #': pullId,
          'Warehouse': warehouse,
          'Item Code': item.code,
          'Description': item.desc,
          'Type': item.tag ? item.tag.toUpperCase() : '',
          'Row Status': item.status.charAt(0).toUpperCase() + item.status.slice(1),
          'Vendor Code': item.vCode,
          'Vendor Name': item.vName,
          'Remark': item.remark,
          'Hour': String(h).padStart(2,'0') + ':00',
          'Expected': slot.e,
          'Received': slot.r,
          'Outstanding': outstanding,
          'Progress %': Math.round(pct * 100),
          'Cell Status': cellStatus,
        });
      });
    });

    // ---- Sheet 2: Summary (one row per item with totals across all hours) ----
    const summary = items.map(item => {
      let exp = 0, rec = 0, windows = 0, outstanding = 0, settled = 0;
      Object.values(item.schedule).forEach(s => {
        if (s.e > 0) {
          exp += s.e; rec += s.r; windows++;
          outstanding += slotOutstanding(s);
          if (isSettled(s)) settled++;
        }
      });
      const pct = exp > 0 ? Math.round((rec/exp)*100) : 0;
      // 'Fully received' is reserved for actually receiving everything. An
      // item whose windows are all settled but not all filled is 'Closed
      // short' — settled, not delivered in full.
      const itemStatus = (item.status === 'canceled') ? 'Canceled'
                       : (exp === 0) ? 'No schedule'
                       : (rec >= exp) ? 'Fully received'
                       : (settled === windows) ? 'Closed short'
                       : (rec > 0) ? 'Outstanding' : 'Pending';
      return {
        'Pull #': pullId,
        'Item Code': item.code,
        'Description': item.desc,
        'Type': item.tag ? item.tag.toUpperCase() : '',
        'Row Status': item.status.charAt(0).toUpperCase() + item.status.slice(1),
        'Vendor': item.vName,
        'Total Expected': exp,
        'Total Received': rec,
        'Total Outstanding': outstanding,
        'Progress %': pct,
        'Windows': windows,
        'Item Status': itemStatus,
      };
    });

    // ---- Sheet 3: Header / metadata ----
    const meta = [
      { Field: 'Pull #',         Value: pullId },
      { Field: 'Warehouse',      Value: warehouse },
      { Field: 'Exported By',    Value: 'S. Wattana' },
      { Field: 'Exported At',    Value: exportedAt },
      { Field: 'Pull Status',    Value: pullClosed ? 'CLOSED · LOCKED' : 'OPEN' },
      { Field: 'Active Items',   Value: items.filter(i => i.status !== 'canceled').length },
      { Field: 'Canceled Items', Value: items.filter(i => i.status === 'canceled').length },
      { Field: 'New Items',      Value: items.filter(i => i.status === 'new').length },
    ];

    return { detail, summary, meta, pullId };
  }

  function exportToExcel() {
    try {
      if (typeof XLSX === 'undefined') {
        showToast('Export failed', 'Excel library not loaded — please retry', 'error');
        return;
      }
      const { detail, summary, meta, pullId } = buildExportRows();

      const wb = XLSX.utils.book_new();

      // Header sheet
      const wsMeta = XLSX.utils.json_to_sheet(meta);
      wsMeta['!cols'] = [{ wch: 18 }, { wch: 40 }];
      XLSX.utils.book_append_sheet(wb, wsMeta, 'Header');

      // Summary sheet
      const wsSum = XLSX.utils.json_to_sheet(summary);
      wsSum['!cols'] = [
        {wch:10},{wch:18},{wch:30},{wch:8},{wch:11},
        {wch:22},{wch:14},{wch:14},{wch:16},{wch:11},{wch:9},{wch:18}
      ];
      XLSX.utils.book_append_sheet(wb, wsSum, 'Summary');

      // Detail sheet — primary working data
      const wsDet = XLSX.utils.json_to_sheet(detail);
      wsDet['!cols'] = [
        {wch:10},{wch:22},{wch:18},{wch:30},{wch:6},{wch:10},
        {wch:11},{wch:22},{wch:22},{wch:7},{wch:11},{wch:11},
        {wch:13},{wch:11},{wch:13}
      ];
      // Freeze header row
      wsDet['!freeze'] = { ySplit: 1 };
      XLSX.utils.book_append_sheet(wb, wsDet, 'Detail');

      const dateStamp = new Date().toISOString().slice(0,10);
      const filename = `${pullId}_${dateStamp}.xlsx`;
      XLSX.writeFile(wb, filename);

      showToast('Export complete', `${filename} · ${detail.length} rows`, 'success-big');
    } catch (err) {
      console.error(err);
      showToast('Export failed', err.message || 'Unknown error', 'error');
    }
  }

  document.getElementById('btn-export').addEventListener('click', exportToExcel);

  // Filter dropdown — re-render to apply
  document.getElementById('filter-select').addEventListener('change', () => render());

  // Stage B: a pull belongs to exactly one warehouse server-side, so the warehouse
  // dropdown is presentational only — we sync its label fields after a load.
  function applyWarehouse() {
    const code = currentWarehouse;
    const fullText = code + (currentWhName ? ' · ' + currentWhName : '');
    document.getElementById('topbar-wh').textContent = code || '—';
    document.getElementById('topbar-pull').textContent = currentPull || '—';
    document.getElementById('cm-warehouse').textContent = fullText;
    document.getElementById('cm-decl-wh').textContent = fullText;
    render();
  }
  // The warehouse dropdown is locked to the loaded pull's warehouse — wire change
  // to revert any user attempt to switch (until cross-warehouse pulls are supported).
  document.getElementById('warehouse-select').addEventListener('change', (e) => {
    if (e.target.value !== currentWarehouse) {
      e.target.value = currentWarehouse;
      showToast('Locked to pull warehouse', `${currentPull} is in ${currentWarehouse}`, 'default');
    }
  });

  // ============ STARTUP — read ?pull= and fetch PullDetail ============
  function readPullParamOrRedirect() {
    const params = new URLSearchParams(window.location.search);
    const pull = (params.get('pull') || '').trim();
    if (!pull) {
      window.location.href = '/Dashboard';
      return null;
    }
    return pull;
  }

  // Map server PullDetail → mockup-compatible pullData[pull][wh] = items[].
  function ingestPullDetail(pd) {
    currentPull        = pd.pullNumber;
    currentPullId      = pd.id;
    currentWarehouse   = pd.warehouseCode;
    currentWhName      = pd.warehouseName;
    serverPullStatus   = pd.status;
    // §3.5 — drives the lock-icon prefix on PO tokens in drawer + modal-embedded
    // tx rows. Defaults false so older PullDetail responses stay backwards-compat.
    currentPullLocked  = !!pd.lockPoByPull;
    currentPullHourCapLocked = !!pd.lockHourCap;   // db/047 §2f

    const mapped = (pd.items || [])
      .sort((a,b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
      .map(i => {
        const schedule = {};
        for (const w of (i.windows || [])) {
          schedule[w.hourOfDay] = {
            r: w.receivedQty | 0,
            e: w.expectedQty | 0,
            // db/047 — close state. `c` drives the CLOSED pill in the grid and the
            // closed-state modal; without it a short-closed 400/1,000 is visually
            // identical to a partial still awaiting delivery.
            c:  !!w.isClosed,
            ca: w.closedAt || null,
            cr: w.closedReason || null,
            // db/049 — label comes from the server so this file holds no copy of the map.
            // Both stay null on windows closed before reason codes existed; the closed
            // modal renders that as "not recorded", never as OTHER.
            rc: w.varianceReasonCode || null,
            rl: w.varianceReasonLabel || null,
          };
        }
        return {
          pullItemId: i.id,             // GUID — used by POST /api/receipts
          // db/047 §2c — the accept-variance guard is server-enforced as
          // MULTI_WINDOW_NOT_SUPPORTED; the UI hides the checkbox for the same reason.
          // Derived from the payload rather than asked for separately.
          winCount:  (i.windows || []).length,
          code:       i.itemCode,
          desc:       i.description,
          tag:        i.tag,
          status:     i.status,
          vCode:      i.vendorCode  || '',
          vName:      i.vendorName  || '',
          remark:     i.remark      || '—',
          special:    i.specialControl || '',   // Phase 9.1 field; shown appended to Remark
          schedule,
        };
      });

    pullData[currentPull] = { label: currentPull, [currentWarehouse]: mapped };
    items = mapped;
  }

  // Page is context-locked — Pull # is a read-only text label fed from the
  // loaded PullDetail. Warehouse stays a <select> for legacy markup parity but
  // is presentational only (change handler reverts above).
  function ensureDropdownOptions(pullNumber, whCode, whName) {
    const pullLabel = document.getElementById('pull-label');
    if (pullLabel) pullLabel.textContent = pullNumber;

    const whSel = document.getElementById('warehouse-select');
    if (whSel && ![...whSel.options].some(o => o.value === whCode)) {
      const opt = document.createElement('option');
      opt.value = whCode;
      opt.textContent = whCode + (whName ? ' · ' + whName : '');
      whSel.appendChild(opt);
    }
    if (whSel) whSel.value = whCode;
  }

  async function startup() {
    const pullNumber = readPullParamOrRedirect();
    if (!pullNumber) return;

    let resp;
    try {
      resp = await fetch('/api/pulls/by-number/' + encodeURIComponent(pullNumber));
    } catch (e) {
      console.error('Pull fetch failed', e);
      showToast('Network error', 'Could not load pull', 'error');
      return;
    }
    if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
    if (resp.status === 404) { showToast('Pull not found', pullNumber, 'error'); return; }
    if (resp.status === 403) { showToast('Access denied', 'You cannot view this warehouse', 'error'); return; }
    if (!resp.ok) {
      showToast('Failed to load pull', `HTTP ${resp.status}`, 'error');
      return;
    }
    const pd = await resp.json();
    ingestPullDetail(pd);
    ensureDropdownOptions(currentPull, currentWarehouse, currentWhName);

    // Reflect closed status into the existing UI gates (banner + button + read-only).
    if (serverPullStatus === 'closed') {
      pullClosed = true;
      document.body.classList.add('pull-closed');
      const banner = document.getElementById('closed-banner');
      if (banner) banner.classList.add('show');
      if (typeof updateCloseButton === 'function') updateCloseButton();
    }

    applyWarehouse();    // first render
  }
  startup();

  // Search box — live filter by item code, description, vendor code, vendor name
  document.getElementById('search-input').addEventListener('input', () => render());

/* ===== JS:journal (from receiving-mockup-v2-fullreceived.html) ===== */
/* =============================================================================
 * RECEIPT JOURNAL — Stage B: backed by GET /api/receipts/pull/{guid}.
 * The cache is read by the drawer + Receive Goods modal's embedded list. The
 * client never writes; mutations go through POST /api/receipts/* which trigger
 * a cache invalidation (see confirmReceipt + tx-cancel-confirm).
 * =========================================================================== */
const txCache = [];               // module-level array; mutated in place
let   txCacheLoaded = false;      // false → next txEnsureLoaded() fetches

async function txEnsureLoaded() {
  if (txCacheLoaded || !currentPullId) return;
  try {
    const r = await fetch('/api/receipts/pull/' + encodeURIComponent(currentPullId));
    if (r.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!r.ok) { console.error('Failed to load receipt journal:', r.status); return; }
    const rows = await r.json();
    txCache.length = 0;
    // Map server ReceiptJournalRow → mockup-compatible client shape (snake/camel matched).
    for (const s of rows) {
      txCache.push({
        id:          s.id,
        pullId:      s.pullNumber,      // client filters by pull number; server returns it
        warehouse:   s.warehouseCode,
        pullItemId:  s.pullItemId,
        itemCode:    s.itemCode,
        itemDesc:    s.itemDescription,
        // §4.8 v2 — PO context surfaces on every journal row
        poNumber:    s.poNumber,
        poLineNumber: s.poLineNumber,
        vendorName:  s.vendorName,
        hour:        s.hourOfDay,
        qty:         s.qtyReceived,
        lotBatch:    s.lotBatch,
        palletId:    s.palletId,
        binLocation: s.binLocation,
        qcStatus:    s.qcStatus,
        note:        s.note,
        receivedBy:  s.receivedByName,
        receivedAt:  s.receivedAt,
        reverses:    s.reversesReceiptId,
        reversedBy:  s.reversedById,
        reason:      s.cancelReason,
        kind:        s.kind,            // 'receive'|'voided'|'reversal'
      });
    }
    txCacheLoaded = true;
  } catch (e) {
    console.error('txEnsureLoaded fetch error', e);
  }
}

// Synchronous read used by renderTxDrawer / renderModalTransactions.
// Returns the snapshot in cache; if empty/unloaded the caller renders empty state
// and txEnsureLoaded() is triggered separately on drawer open.
function txLoad() { return txCache; }
function txSave(_arr) { /* server is authoritative; no client persistence */ }
function txCurrentActor() {
  // Audit row carries actor server-side; this is just for any client display fallback.
  return 'You';
}

function txEsc(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function txFmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
}
function txFmtFull(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}

/* =============================================================================
 * DRAWER OPEN/CLOSE
 * =========================================================================== */
/* openTxDrawer(ctx?) — when called without args, lists all receipts for the current pull.
   When called with { hour, itemCode } from the Receive Goods modal, pre-fills the search
   box so only that slot's transactions are visible (the modal hands off context). */
function openTxDrawer(ctx) {
  const pull = (typeof currentPull !== 'undefined' && currentPull) ? currentPull : (document.getElementById('topbar-pull')?.textContent || 'PL-2847');
  const wh   = (typeof currentWarehouse !== 'undefined' && currentWarehouse) ? currentWarehouse : (document.getElementById('topbar-wh')?.textContent || 'WH-01');
  document.getElementById('tx-drawer-pull').textContent = pull;
  document.getElementById('tx-drawer-meta').textContent = wh + (typeof currentWhName !== 'undefined' && currentWhName ? ' · ' + currentWhName : '');

  // Pre-filter when context is provided. Search box accepts item code; we filter
  // by hour after the fact in renderTxDrawer (see below).
  const searchEl = document.getElementById('tx-search');
  if (ctx && ctx.itemCode) {
    searchEl.value = ctx.itemCode;
  } else {
    searchEl.value = '';
  }
  // Stash the hour filter on the drawer element so renderTxDrawer can apply it
  document.getElementById('txDrawer').dataset.hourFilter = (ctx && Number.isInteger(ctx.hour)) ? String(ctx.hour) : '';

  // Build a deep link for the standalone Transactions page — include hour when present.
  // Use the absolute MVC route /Transactions, not the mockup-relative
  // transactions.html (which resolves to /Receiving/transactions.html → 404).
  const params = new URLSearchParams({ pull, warehouse: wh });
  if (ctx && Number.isInteger(ctx.hour))    params.set('hour', String(ctx.hour));
  if (ctx && ctx.itemCode)                  params.set('item', ctx.itemCode);
  document.getElementById('tx-open-full').href = '/Transactions?' + params.toString();

  const backdrop = document.getElementById('txDrawer-backdrop');
  const drawer = document.getElementById('txDrawer');
  backdrop.style.display = 'block';
  drawer.style.display = 'flex';
  // Force reflow before triggering animation
  void backdrop.offsetWidth;
  backdrop.style.opacity = '1';
  drawer.style.transform = 'translateX(0)';

  renderTxDrawer();
}

function closeTxDrawer() {
  const backdrop = document.getElementById('txDrawer-backdrop');
  const drawer = document.getElementById('txDrawer');
  backdrop.style.opacity = '0';
  drawer.style.transform = 'translateX(100%)';
  setTimeout(() => {
    backdrop.style.display = 'none';
  }, 250);
}

document.getElementById('btn-transactions').addEventListener('click', async () => {
  await txEnsureLoaded();
  openTxDrawer();
});
document.getElementById('tx-drawer-close').addEventListener('click', closeTxDrawer);
document.getElementById('txDrawer-backdrop').addEventListener('click', closeTxDrawer);
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && document.getElementById('txDrawer-backdrop').style.opacity === '1') closeTxDrawer();
});

/* =============================================================================
 * DRAWER RENDER
 * =========================================================================== */
function renderTxDrawer() {
  const pull = document.getElementById('tx-drawer-pull').textContent;
  const filter = document.getElementById('tx-filter').value;
  const q = document.getElementById('tx-search').value.trim().toLowerCase();
  const hourFilterStr = document.getElementById('txDrawer').dataset.hourFilter || '';
  const hourFilter = hourFilterStr === '' ? null : parseInt(hourFilterStr, 10);
  const all = txLoad();
  let list = all.filter(r => r.pullId === pull);

  // Hour filter (set when drawer is opened from a Receive Goods modal cell)
  if (hourFilter !== null && !isNaN(hourFilter)) {
    list = list.filter(r => r.hour === hourFilter);
  }

  // Apply secondary filter
  if (filter === 'receive') list = list.filter(r => r.qty > 0 && !r.reversedBy);
  else if (filter === 'cancel') list = list.filter(r => r.qty < 0);
  else if (filter === 'voided') list = list.filter(r => r.reversedBy);

  if (q) {
    list = list.filter(r => `${r.itemCode} ${r.itemDesc} ${r.lotBatch} ${r.palletId} ${r.receivedBy} ${r.note || ''}`.toLowerCase().includes(q));
  }

  // Update drawer subtitle to reflect the active hour filter
  const metaEl = document.getElementById('tx-drawer-meta');
  const wh = (typeof currentWarehouse !== 'undefined' && currentWarehouse) ? currentWarehouse : (document.getElementById('topbar-wh')?.textContent || 'WH-01');
  const baseMeta = wh + (typeof currentWhName !== 'undefined' && currentWhName ? ' · ' + currentWhName : '');
  metaEl.textContent = baseMeta;

  // Show/hide the hour-filter chip
  const hourBar = document.getElementById('tx-hour-filter-bar');
  const hourLabel = document.getElementById('tx-hour-filter-label');
  if (hourFilter !== null && !isNaN(hourFilter)) {
    hourBar.style.display = 'flex';
    const itemCtx = q ? ` · ${q.toUpperCase()}` : '';
    hourLabel.innerHTML = `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg> ${String(hourFilter).padStart(2,'0')}:00${itemCtx}`;
  } else {
    hourBar.style.display = 'none';
  }

  // Sort: newest first
  list.sort((a, b) => new Date(b.receivedAt) - new Date(a.receivedAt));

  // Stats
  const positive = list.filter(r => r.qty > 0).length;
  const negative = list.filter(r => r.qty < 0).length;
  const net = list.reduce((s, r) => s + r.qty, 0);
  document.getElementById('tx-s-receipts').textContent = positive;
  document.getElementById('tx-s-reversals').textContent = negative;
  document.getElementById('tx-s-net').textContent = net.toLocaleString();

  const wrap = document.getElementById('tx-drawer-list');
  if (list.length === 0) {
    wrap.innerHTML = `<div class="tx-empty">
      <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/></svg>
      No transactions yet for this pull
    </div>`;
    return;
  }

  wrap.innerHTML = list.map(r => {
    const isReversal = r.qty < 0;
    const isVoided = !!r.reversedBy;
    const cls = (isReversal ? 'reversal' : '') + (isVoided ? ' voided' : '');
    const pillCls = isReversal ? 'cancel' : (isVoided ? 'voided' : 'receive');
    const pillLabel = isReversal ? 'Cancel' : (isVoided ? 'Voided' : 'Receive');
    const qtyDisplay = isReversal ? `−${Math.abs(r.qty).toLocaleString()}` : r.qty.toLocaleString();
    const reverseLink = r.reverses
      ? `<span class="tx-reverses-of">↺ Reverses ${txEsc(r.reverses)}</span>`
      : (r.reversedBy ? `<span class="tx-reverses-of">↩ Voided by ${txEsc(r.reversedBy)}</span>` : '');
    const canCancel = !isReversal && !isVoided;
    return `
      <div class="tx-item ${cls}" data-id="${txEsc(r.id)}">
        <div class="tx-row-top">
          <span class="tx-pill ${pillCls}">${pillLabel}</span>
          <span class="tx-time">${txFmtTime(r.receivedAt)} · ${txEsc(String(r.hour).padStart(2,'0'))}:00</span>
        </div>
        <div class="tx-row-main">
          <div class="tx-item-info">
            <div class="tx-item-code">${txEsc(r.itemCode)}</div>
            <div class="tx-item-meta">${txEsc(r.lotBatch || '—')} · ${txEsc(r.palletId || '—')} · ${txEsc(r.binLocation || '—')}</div>
            ${r.poNumber ? `<div class="tx-po" title="${txEsc(r.vendorName || '')}">${(typeof currentPullLocked !== 'undefined' && currentPullLocked) ? '<span class="po-lock">🔒</span>' : ''}<b>${txEsc(r.poNumber)}</b>${r.poLineNumber ? '·L' + txEsc(String(r.poLineNumber).padStart(2,'0')) : ''}</div>` : ''}
            ${reverseLink}
          </div>
          <div class="tx-qty ${isReversal ? 'neg' : ''}">${qtyDisplay}<small>pcs</small></div>
        </div>
        ${r.note ? `<div class="tx-note">${txEsc(r.note)}</div>` : ''}
        <div class="tx-row-foot">
          <span class="tx-actor">By <b>${txEsc(r.receivedBy)}</b></span>
          <div class="tx-actions">
            ${canCancel ? `<button class="tx-btn-cancel" data-tx-cancel="${txEsc(r.id)}">
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M3 12a9 9 0 1 0 9-9"/><path d="M3 4v6h6"/></svg>
              Cancel
            </button>` : ''}
          </div>
        </div>
      </div>
    `;
  }).join('');
}

document.getElementById('tx-search').addEventListener('input', renderTxDrawer);
document.getElementById('tx-filter').addEventListener('change', renderTxDrawer);
document.getElementById('tx-hour-filter-clear').addEventListener('click', () => {
  document.getElementById('txDrawer').dataset.hourFilter = '';
  document.getElementById('tx-search').value = '';
  renderTxDrawer();
});

/* =============================================================================
 * CANCEL FLOW (drawer-level)
 * =========================================================================== */
let txCancelTarget = null;

function openTxCancelModal(receiptId) {
  const all = txLoad();
  const r = all.find(x => x.id === receiptId);
  if (!r) return;
  txCancelTarget = r;
  document.getElementById('tx-c-id').textContent = r.id;
  document.getElementById('tx-c-when').textContent = txFmtFull(r.receivedAt);
  document.getElementById('tx-c-item').textContent = r.itemCode;
  document.getElementById('tx-c-qty').textContent = '−' + r.qty.toLocaleString() + ' pcs';
  document.getElementById('tx-c-note').value = '';
  document.querySelectorAll('input[name="tx-reason"]').forEach(rb => rb.checked = false);

  const backdrop = document.getElementById('tx-cancel-backdrop');
  backdrop.style.display = 'flex';
  void backdrop.offsetWidth;
  backdrop.style.opacity = '1';
}

function closeTxCancelModal() {
  const backdrop = document.getElementById('tx-cancel-backdrop');
  backdrop.style.opacity = '0';
  setTimeout(() => { backdrop.style.display = 'none'; }, 200);
  txCancelTarget = null;
}

document.getElementById('tx-cancel-close').addEventListener('click', closeTxCancelModal);
document.getElementById('tx-cancel-keep').addEventListener('click', closeTxCancelModal);
document.getElementById('tx-cancel-backdrop').addEventListener('click', (e) => {
  if (e.target === document.getElementById('tx-cancel-backdrop')) closeTxCancelModal();
});

document.getElementById('tx-cancel-confirm').addEventListener('click', async () => {
  if (!txCancelTarget) return;
  const reasonRadio = document.querySelector('input[name="tx-reason"]:checked');
  if (!reasonRadio) {
    if (typeof showToast === 'function') showToast('Pick a reason first');
    return;
  }
  const reason = reasonRadio.value;
  const note = document.getElementById('tx-c-note').value.trim();
  const orig = txCancelTarget;

  const confirmBtn = document.getElementById('tx-cancel-confirm');
  confirmBtn.disabled = true;
  try {
    const resp = await fetch(`/api/receipts/${encodeURIComponent(orig.id)}/cancel`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ reason, note: note || null }),
    });
    if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
    if (!resp.ok) {
      let title = `Cancel rejected (${resp.status})`;
      try { const j = await resp.json(); if (j?.title) title = j.title; } catch {}
      if (typeof showToast === 'function') showToast('Cancel failed', title, 'error');
      return;
    }
    const result = await resp.json();   // { reversalReceiptId, newReceivedQty }

    // Sync the hour-grid cell from the authoritative server value.
    if (currentPull && pullData[currentPull] && currentWarehouse && pullData[currentPull][currentWarehouse]) {
      const list = pullData[currentPull][currentWarehouse];
      const targetItem = list.find(it => it.pullItemId === orig.pullItemId)
                       || list.find(it => it.code === orig.itemCode);
      if (targetItem?.schedule?.[orig.hour]) {
        targetItem.schedule[orig.hour].r = result.newReceivedQty;
      }
    }

    // Drop the journal cache — next drawer/modal render fetches fresh.
    txCache.length = 0;
    txCacheLoaded = false;
    await txEnsureLoaded();

    closeTxCancelModal();
    if (typeof render === 'function') render();
    renderTxDrawer();

    // Refresh the in-modal transactions list if the Receive Goods modal is open.
    try {
      const receiveModal = document.getElementById('modal');
      if (receiveModal && receiveModal.classList.contains('open') && typeof renderModalTransactions === 'function') {
        const itemCode = document.getElementById('m-title').textContent;
        const hour = window._activeHour;
        if (itemCode && hour !== undefined) {
          renderModalTransactions(itemCode, hour);
          const item = items[activeRow];
          if (item) {
            const cell = getCell(item, hour);
            const expected = cell.e || 0;
            const prev = cell.r || 0;
            const outstanding = Math.max(0, expected - prev);
            const out = document.getElementById('m-out');
            const prevEl = document.getElementById('m-prev');
            const capMax = document.getElementById('cap-hint-max');
            if (out) out.textContent = outstanding.toLocaleString();
            if (prevEl) prevEl.textContent = prev.toLocaleString();
            if (capMax) capMax.textContent = outstanding.toLocaleString();
            const input = document.getElementById('m-input');
            if (input && !pullClosed) {
              input.removeAttribute('max');   // db/047 §7 — see openModal
              input.value = outstanding;
            }
            if (typeof activeMax !== 'undefined') window.activeMax = outstanding;
          }
        }
      }
    } catch (e) { console.warn('Could not refresh modal:', e); }

    if (typeof showToast === 'function') {
      showToast('Reversal created', `−${Math.abs(orig.qty).toLocaleString()} pcs`);
    }
  } catch (e) {
    console.error('tx-cancel-confirm failed', e);
    if (typeof showToast === 'function') showToast('Network error', 'Could not reach server', 'error');
  } finally {
    confirmBtn.disabled = false;
  }
});

// Row-level cancel button (delegated)
document.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-tx-cancel]');
  if (btn) openTxCancelModal(btn.getAttribute('data-tx-cancel'));
});

/* Stage B note: seed-on-first-run removed; journal comes from /api/receipts/pull/{guid}. */

