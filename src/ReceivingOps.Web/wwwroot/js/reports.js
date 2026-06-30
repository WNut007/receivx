// v2.x Phase 7.4 — Reports page (two-pane) wiring.
//
// Row click → fetch /api/reports/do/{id}/preview, inject HTML into the
// preview body, enable Export PDF + Print. Print opens a stand-alone
// window with just the .preview-body contents so the chrome/nav/list
// pane don't bleed into the printed paper.
//
// PDF endpoint stays at /Reports/Do/{id}/pdf?dl=1 until commit 4
// canonicalizes it under /api/reports.

(() => {
    'use strict';

    const rowsEl    = document.getElementById('pull-rows');
    const titleEl   = document.getElementById('preview-title');
    const bodyEl    = document.getElementById('preview-body');
    const btnPdf    = document.getElementById('btn-export-pdf');
    const btnPrint  = document.getElementById('btn-print');
    const countEl   = document.getElementById('result-count');

    const toggleEl  = document.getElementById('report-type-toggle');

    let selectedPullId = null;
    let selectedPullNumber = null;
    // 'note' (Delivery Note, OrderId grouping) | 'order' (DSV Delivery Order,
    // SubInventory × ToLocation grouping). PDF export is Note-only for now;
    // the Order tab keeps Print (which renders the HTML preview).
    let reportType = 'note';

    // ----- Row selection ---------------------------------------------------
    rowsEl.addEventListener('click', (e) => {
        // The batch-select checkbox lives inside the row but must not trigger
        // a preview load (it toggles selection only).
        if (e.target.closest('.pull-check')) return;
        const row = e.target.closest('.pull-row[data-pull-id]');
        if (!row) return;
        selectedPullId = row.dataset.pullId;
        selectedPullNumber = row.dataset.pullNumber;
        rowsEl.querySelectorAll('.pull-row').forEach(r =>
            r.classList.toggle('selected', r === row));
        loadPreview();
    });

    // ----- Report-type toggle ---------------------------------------------
    if (toggleEl) {
        toggleEl.addEventListener('click', (e) => {
            const tab = e.target.closest('.rt-tab[data-report-type]');
            if (!tab || tab.classList.contains('active')) return;
            reportType = tab.dataset.reportType;
            toggleEl.querySelectorAll('.rt-tab').forEach(t => {
                const on = t === tab;
                t.classList.toggle('active', on);
                t.setAttribute('aria-selected', on ? 'true' : 'false');
            });
            if (selectedPullId) loadPreview();
        });
    }

    const docNoun = () => (reportType === 'order' ? 'delivery order' : 'delivery note');

    async function loadPreview() {
        if (!selectedPullId) return;
        titleEl.textContent = `${selectedPullNumber} · loading…`;
        bodyEl.innerHTML = `<div class="preview-loading">Loading ${docNoun()}s…</div>`;
        btnPdf.disabled = true;
        btnPrint.disabled = true;

        try {
            const url = `/api/reports/do/${encodeURIComponent(selectedPullId)}/preview?type=${reportType}`;
            const resp = await fetch(url, { credentials: 'same-origin' });
            if (!resp.ok) {
                let msg = `Preview failed (HTTP ${resp.status})`;
                try {
                    const ct = resp.headers.get('content-type') || '';
                    if (ct.includes('application/json')) {
                        const j = await resp.json();
                        if (j && j.error) msg = j.error;
                    } else {
                        const t = await resp.text();
                        if (t) msg = t;
                    }
                } catch { /* keep default msg */ }
                bodyEl.innerHTML = `<div class="preview-error">${escapeHtml(msg)}</div>`;
                titleEl.textContent = `${selectedPullNumber} · error`;
                return;
            }
            const html = await resp.text();
            bodyEl.innerHTML = html;
            const doCount = bodyEl.querySelectorAll('article').length;
            titleEl.textContent =
                `${selectedPullNumber} · ${doCount} ${docNoun()}${doCount === 1 ? '' : 's'}`;
            // PDF export works for both report types (each loads its own .frx).
            btnPdf.disabled = false;
            btnPdf.title = '';
            btnPrint.disabled = false;
        } catch (err) {
            bodyEl.innerHTML =
                `<div class="preview-error">Network error: ${escapeHtml(err.message || String(err))}</div>`;
            titleEl.textContent = `${selectedPullNumber} · error`;
        }
    }

    // ----- Sign a party box (digital signature) ---------------------------
    // Delegated: the preview HTML is re-injected on every load, so bind once
    // on the stable container. A "Sign as {Party}" button only renders when
    // the server marked the box eligible. Phase 8b: the click opens the
    // signature-pad modal; the POST happens on the pad's confirm.
    bodyEl.addEventListener('click', (e) => {
        const btn = e.target.closest('.do-sign-btn[data-party]');
        if (!btn || !selectedPullId) return;
        openSignPad(btn.dataset.party, 'single');
    });

    // ----- Signature pad modal (single + batch sign) ----------------------
    // Phase 8b single sign + Phase 8c batch: both draw on the SAME pad. The
    // confirm dispatches by mode — single POSTs /sign for the open pull; batch
    // POSTs /sign-batch with the checked pulls (one drawing reused on each).
    const signPadModal   = document.getElementById('sign-pad-modal');
    const signPadHost     = document.getElementById('sign-pad-host');
    const signPadCanvas   = document.getElementById('sign-pad-canvas');
    const signPadConfirm  = document.getElementById('sign-pad-confirm');
    let signPad = null;
    let signPendingParty = null;
    let signPadMode = 'single';   // 'single' | 'batch'
    let signPadBatchIds = [];     // batch mode only: the pulls to sign

    if (signPadCanvas && window.SignaturePad) {
        signPad = window.SignaturePad.mount(signPadCanvas, {
            onChange: (hasInk) => {
                if (signPadHost) signPadHost.classList.toggle('signed', hasInk);
                if (signPadConfirm) signPadConfirm.disabled = !hasInk;
            },
        });
    }

    // mode 'single' signs the open pull (selectedPullId); mode 'batch' signs the
    // ids passed in (the checked rows). The drawing is captured once on confirm.
    function openSignPad(party, mode, ids) {
        if (!signPad) return;
        signPadMode = mode || 'single';
        signPendingParty = party;
        signPadBatchIds = ids || [];
        document.getElementById('sign-pad-party').textContent = party;
        const sub = document.getElementById('sign-pad-sub');
        if (signPadMode === 'batch') {
            const n = signPadBatchIds.length;
            sub.innerHTML =
                `Draw your signature once for <b>${n}</b> selected pull${n === 1 ? '' : 's'}. ` +
                `The same drawing, your name + timestamp is recorded on each ${escapeHtml(party)} box. ` +
                `Already-signed pulls are skipped. This cannot be undone.`;
        } else {
            sub.innerHTML =
                `Draw your signature for <b>${escapeHtml(selectedPullNumber)}</b>. ` +
                `This records your drawing, name + timestamp and cannot be undone.`;
        }
        signPadConfirm.disabled = true;
        signPadModal.hidden = false;
        // Canvas must be visible before sizing (mirror the close modal).
        requestAnimationFrame(() => { signPad.resize(); signPad.clear(); });
    }
    function closeSignPad() {
        if (signPadModal) signPadModal.hidden = true;
        signPendingParty = null;
        signPadBatchIds = [];
    }

    document.getElementById('sign-pad-clear')?.addEventListener('click', () => signPad && signPad.clear());
    document.getElementById('sign-pad-cancel')?.addEventListener('click', closeSignPad);
    signPadModal?.addEventListener('click', (e) => { if (e.target === signPadModal) closeSignPad(); });

    signPadConfirm?.addEventListener('click', async () => {
        if (!signPendingParty || !signPad || signPad.isEmpty()) return;
        const party = signPendingParty;
        const signatureSvg = signPad.toDataUrl();
        signPadConfirm.disabled = true;
        if (signPadMode === 'batch') await submitBatchSign(party, signPadBatchIds, signatureSvg);
        else                         await submitSingleSign(party, signatureSvg);
    });

    async function submitSingleSign(party, signatureSvg) {
        if (!selectedPullId) { closeSignPad(); return; }
        try {
            const resp = await fetch(
                `/api/reports/do/${encodeURIComponent(selectedPullId)}/sign`,
                {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ party, signatureSvg }),
                });
            if (!resp.ok) {
                let msg = `Sign failed (HTTP ${resp.status})`;
                try { const j = await resp.json(); if (j && (j.title || j.error)) msg = j.title || j.error; } catch { /* keep */ }
                alert(msg);
                signPadConfirm.disabled = false;
                return;
            }
            closeSignPad();
            // Update the list row (badge + chip) AND reload the preview immediately.
            markRowSigned(selectedPullId, party);
            applyFilters();
            refreshEligibility();
            loadPreview();
        } catch (err) {
            alert(`Network error: ${err.message || String(err)}`);
            signPadConfirm.disabled = false;
        }
    }

    // Phase 8c — one drawing, many pulls. Reuses the batch result line + the same
    // partial-success roll-up (signed / skipped / errors) the 7d handler used.
    async function submitBatchSign(party, ids, signatureSvg) {
        if (!ids.length) { closeSignPad(); return; }
        if (batchResult) batchResult.textContent = 'Signing…';
        try {
            const resp = await fetch('/api/reports/sign-batch', {
                method: 'POST',
                credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ pullIds: ids, party, signatureSvg }),
            });
            if (!resp.ok) {
                let msg = `Batch sign failed (HTTP ${resp.status})`;
                try { const j = await resp.json(); if (j && (j.title || j.error)) msg = j.title || j.error; } catch { /* keep */ }
                if (batchResult) batchResult.textContent = msg;
                closeSignPad();
                return;
            }
            const r = await resp.json();
            closeSignPad();
            const signedResults = (r.results || []).filter(x => x.outcome === 'signed');
            // Update each signed row in place (badge + chip) — no full reload.
            signedResults.forEach(x => markRowSigned(x.pullId, r.party || party));
            // Signed rows are no longer eligible — clear the selection + re-sync.
            rowsEl.querySelectorAll('.pull-check:checked').forEach(cb => cb.checked = false);
            applyFilters();
            refreshEligibility();
            // If the open preview was among the signed pulls, flip its boxes too.
            if (selectedPullId && signedResults.some(x =>
                String(x.pullId).toLowerCase() === String(selectedPullId).toLowerCase())) {
                loadPreview();
            }
            const parts = [`${r.signed} signed`];
            if (r.skipped) parts.push(`${r.skipped} skipped`);
            if (r.errors)  parts.push(`${r.errors} error${r.errors === 1 ? '' : 's'}`);
            if (batchResult) batchResult.textContent = parts.join(' · ');
        } catch (err) {
            if (batchResult) batchResult.textContent = `Network error: ${err.message || String(err)}`;
            closeSignPad();
        }
    }

    // ----- Export PDF -----------------------------------------------------
    // /api/reports/do/{id}/export.pdf always sets Content-Disposition:
    // attachment so navigating to it triggers a Save As dialog.
    btnPdf.addEventListener('click', () => {
        if (!selectedPullId || btnPdf.disabled) return;
        window.location.href = `/api/reports/do/${encodeURIComponent(selectedPullId)}/export.pdf?type=${reportType}`;
    });

    // ----- Print ----------------------------------------------------------
    // Open a stand-alone window with just the preview HTML + reports.css
    // (theme tokens, .do-document, .do-header, etc.). The print stylesheet
    // in reports.css strips toolbars + lists; the new window has none of
    // those anyway, so the print preview is the bare DO documents.
    btnPrint.addEventListener('click', () => {
        if (!selectedPullId || btnPrint.disabled) return;
        const html = bodyEl.innerHTML;
        const theme = document.documentElement.getAttribute('data-theme') || 'light';
        const w = window.open('', '_blank', 'width=820,height=900');
        if (!w) return; // popup blocked
        w.document.write(`<!DOCTYPE html>
<html lang="en" data-theme="${theme}">
<head>
<meta charset="UTF-8">
<title>${escapeHtml(selectedPullNumber)} · Delivery Order</title>
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500;600;700&family=Roboto+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/css/reports.css">
<style>
  body { background: #fff; padding: 24px; }
  body::before, body::after { display: none !important; }
  .do-document { box-shadow: none; border: 0; max-width: 100%; margin-bottom: 32px; }
  .do-document + .do-document { page-break-before: always; }
</style>
</head>
<body>${html}</body>
</html>`);
        w.document.close();
        // Give fonts + stylesheet a moment, then print.
        setTimeout(() => { w.focus(); w.print(); }, 250);
    });

    // ----- Filter bar (client-side filter over server-rendered rows) -------
    const filterQ         = document.querySelector('.filter-q');
    const filterPull      = document.querySelector('.filter-pull');
    const filterDateRange = document.getElementById('filter-date-range');
    const filterFrom      = document.querySelector('.filter-from');
    const filterTo        = document.querySelector('.filter-to');
    const filterWh        = document.querySelector('.filter-wh');
    const filterSign      = document.getElementById('filter-sign');
    const customDateRow   = document.getElementById('reports-custom-date-row');

    // Phase 7e — the current user's signing parties (lowercase: customer /
    // warehouse / production). batchParties excludes Warehouse (auto-signed at
    // close → never batch-signable).
    const signParties  = Array.isArray(window.__signParties) ? window.__signParties : [];
    const batchParties = signParties.filter(p => p === 'customer' || p === 'production');

    [filterQ, filterPull, filterFrom, filterTo, filterWh].forEach(el => {
        if (!el) return;
        el.addEventListener('input', applyFilters);
    });
    if (filterSign) filterSign.addEventListener('change', applyFilters);
    if (filterDateRange) {
        filterDateRange.addEventListener('change', () => {
            if (customDateRow) customDateRow.hidden = filterDateRange.value !== 'custom';
            applyFilters();
        });
    }

    // Same buckets as dashboard.js — kept local to avoid cross-page coupling.
    // Filters Reports rows by ClosedAt (DO is produced when the pull closes,
    // so the operator's "what got delivered yesterday?" question naturally
    // groups by close date, not pull date).
    function classifyDateGroup(iso) {
        if (!iso) return 'older';
        const today = new Date(); today.setHours(0, 0, 0, 0);
        const d = new Date(iso + 'T00:00:00');
        if (isNaN(d.getTime())) return 'older';
        const diffDays = Math.round((today - d) / 86400000);
        if (diffDays === 0)  return 'today';
        if (diffDays === 1)  return 'yesterday';
        if (diffDays <= 6)   return 'this_week';
        if (diffDays <= 13)  return 'last_week';
        return 'older';
    }

    function applyFilters() {
        const q     = (filterQ.value    || '').trim().toLowerCase();
        const pn    = (filterPull.value || '').trim().toLowerCase();
        const dr    = filterDateRange ? filterDateRange.value : 'all';
        const from  = filterFrom.value || '';
        const to    = filterTo.value   || '';
        const wh    = filterWh.value   || '';
        const sf    = filterSign ? filterSign.value : 'all';
        let visible = 0;
        rowsEl.querySelectorAll('.pull-row[data-pull-id]').forEach(row => {
            const pull     = (row.dataset.pullNumber || '').toLowerCase();
            const closedAt = row.dataset.closedAt || '';
            const code     = row.querySelector('.row-meta span:nth-child(2)')?.textContent || '';
            const hayQ     = pull + ' ' + code;
            let show = true;
            if (q  && !hayQ.includes(q))    show = false;
            if (pn && !pull.includes(pn))   show = false;
            if (wh && row.dataset.warehouseId !== wh) show = false;
            // Phase 7e — signature-status filter.
            if (sf !== 'all') {
                const sc = parseInt(row.dataset.signedCount || '0', 10);
                if (sf === 'complete' && sc < 3)  show = false;
                if (sf === 'awaiting' && sc >= 3) show = false;
                if (sf === 'unsigned_mine') {
                    // Any party this user can sign that isn't signed yet on this pull.
                    const mineUnsigned = signParties.some(
                        pt => row.dataset[pt + 'Signed'] === 'false');
                    if (!mineUnsigned) show = false;
                }
            }
            // Date range — same semantics as Dashboard, but the source field
            // is ClosedAt (a Reports row is by definition a closed pull).
            if (dr !== 'all') {
                if (dr === 'custom') {
                    if (from && closedAt < from) show = false;
                    if (to   && closedAt > to)   show = false;
                } else if (dr === 'last_2_days') {
                    // Calendar-day semantics: today OR yesterday. Matches the
                    // Dashboard pattern + "วันนี้กับเมื่อวาน" mental model.
                    const grp = classifyDateGroup(closedAt);
                    if (grp !== 'today' && grp !== 'yesterday') show = false;
                } else if (classifyDateGroup(closedAt) !== dr) {
                    show = false;
                }
            }
            row.style.display = show ? '' : 'none';
            if (!show) {
                const cb = row.querySelector('.pull-check');
                if (cb && cb.checked) cb.checked = false;   // hidden rows leave the selection
            }
            if (show) visible++;
        });
        countEl.textContent = visible + (visible === 1 ? ' pull' : ' pulls');
        syncBatchBar();
    }

    // ----- Warehouse filter options ----------------------------------------
    function populateWarehouseFilter() {
        const seen = new Map();
        rowsEl.querySelectorAll('.pull-row[data-pull-id]').forEach(row => {
            const id = row.dataset.warehouseId;
            const code = row.querySelector('.row-meta span:nth-child(2)')?.textContent;
            if (id && code && !seen.has(id)) seen.set(id, code);
        });
        for (const [id, code] of seen) {
            const opt = document.createElement('option');
            opt.value = id;
            opt.textContent = code;
            filterWh.appendChild(opt);
        }
    }
    populateWarehouseFilter();

    // Restore the date range filter from ?dateRange=... if the URL specifies
    // a recognized value; the HTML default is already "last_2_days" so a
    // bare /Reports load drops into the operational window with no JS.
    (function restoreDateFilterFromUrl() {
        if (!filterDateRange) return;
        const want = new URLSearchParams(window.location.search).get('dateRange');
        if (!want) return;
        if (Array.from(filterDateRange.options).some(o => o.value === want)) {
            filterDateRange.value = want;
            if (customDateRow) customDateRow.hidden = want !== 'custom';
        }
    })();

    // ----- Batch sign (Phase 7e) ------------------------------------------
    // A user with canSign=Customer and/or Production gets per-row checkboxes
    // (rendered server-side only when they can batch). Selecting pulls reveals
    // the batch bar; "Sign N as {Party}" POSTs /api/reports/sign-batch (7d).
    const batchBar    = document.getElementById('batch-bar');
    const batchCount  = document.getElementById('batch-count');
    const batchParty  = document.getElementById('batch-party');
    const batchSign   = document.getElementById('batch-sign-btn');
    const batchClear  = document.getElementById('batch-clear-btn');
    const batchResult = document.getElementById('batch-result');

    const cap = s => s ? s.charAt(0).toUpperCase() + s.slice(1) : s;

    if (batchParty && batchParties.length) {
        batchParties.forEach(p => {
            const o = document.createElement('option');
            o.value = cap(p); o.textContent = cap(p);
            batchParty.appendChild(o);
        });
    }

    // The party currently targeted by the batch (Title-case). Drives which rows
    // are eligible: a row is checkable only when that party is still unsigned.
    function currentParty() { return batchParty ? batchParty.value : (batchParties[0] ? cap(batchParties[0]) : ''); }

    // Disable + clear checkboxes whose current-party box is already signed, so
    // the selection can only ever target genuinely-unsigned boxes.
    function refreshEligibility() {
        const party = (currentParty() || '').toLowerCase();
        rowsEl.querySelectorAll('.pull-row[data-pull-id]').forEach(row => {
            const cb = row.querySelector('.pull-check');
            if (!cb) return;
            const signed = row.dataset[party + 'Signed'] === 'true';
            cb.disabled = signed;
            if (signed && cb.checked) cb.checked = false;
            row.classList.toggle('sig-ineligible', signed);
        });
    }

    function selectedIds() {
        return Array.from(rowsEl.querySelectorAll('.pull-check:checked'))
            .map(cb => cb.dataset.pullId);
    }

    // Hoisted (function declaration) so applyFilters can call it before this
    // block runs on first load.
    function syncBatchBar() {
        if (!batchBar) return;
        const n = selectedIds().length;
        batchBar.hidden = n === 0;
        if (batchCount) batchCount.textContent = `${n} selected`;
        if (batchSign)  batchSign.textContent  = `Sign ${n} as ${currentParty()}`;
    }

    // Flip a pull's list row to "party signed" in place — bumps the N/3 badge
    // (+ is-complete at 3) and lights the party chip — so the list reflects a
    // sign immediately, without a manual refresh or a full page reload.
    function markRowSigned(pullId, party) {
        const id = String(pullId).toLowerCase();
        const row = Array.from(rowsEl.querySelectorAll('.pull-row[data-pull-id]'))
            .find(r => (r.dataset.pullId || '').toLowerCase() === id);
        if (!row) return;
        row.dataset[party.toLowerCase() + 'Signed'] = 'true';
        const count = ['customerSigned', 'warehouseSigned', 'productionSigned']
            .filter(b => row.dataset[b] === 'true').length;
        row.dataset.signedCount = String(count);
        const badge = row.querySelector('.sig-badge');
        if (badge) { badge.textContent = `${count}/3`; badge.classList.toggle('is-complete', count >= 3); }
        const initial = party.charAt(0).toUpperCase();   // W / C / P
        row.querySelectorAll('.sig-chip').forEach(ch => {
            if (ch.textContent.trim().toUpperCase() === initial) ch.classList.add('on');
        });
    }

    if (rowsEl && batchParties.length) {
        rowsEl.addEventListener('change', (e) => {
            if (e.target.classList.contains('pull-check')) { batchResult.textContent = ''; syncBatchBar(); }
        });
    }
    if (batchParty) batchParty.addEventListener('change', () => { refreshEligibility(); syncBatchBar(); });
    if (batchClear) batchClear.addEventListener('click', () => {
        rowsEl.querySelectorAll('.pull-check:checked').forEach(cb => cb.checked = false);
        batchResult.textContent = '';
        syncBatchBar();
    });

    // Phase 8c — the batch action now opens the signature pad (draw once). The
    // POST + partial-success roll-up live in submitBatchSign (shared with the
    // pad's confirm dispatch). The old confirmAction text gate is replaced by
    // the pad's own has-ink gate.
    if (batchSign) batchSign.addEventListener('click', () => {
        const ids = selectedIds();
        const party = currentParty();
        if (!ids.length || !party) return;
        openSignPad(party, 'batch', ids);
    });

    refreshEligibility();

    // Run the filter once on load so the default "last_2_days" narrows the
    // list immediately (the HTML <option selected> doesn't itself filter).
    applyFilters();

    // ----- Helpers ---------------------------------------------------------
    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        }[c]));
    }
})();
