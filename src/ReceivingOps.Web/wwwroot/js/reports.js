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
        btnPdf.disabled = true;  btnPdf.title = '';
        btnPrint.disabled = true; btnPrint.title = '';

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
            // Empty Delivery Note (no line marked as a WDT transfer): the
            // partial renders [data-dn-empty] instead of any <article>. Gate the
            // actions with `disabled` + a reason title — never hide the toolbar
            // or the tab toggle, so the operator can still switch to Delivery
            // Order. The 409 the export endpoint returns carries the same reason.
            const emptyReason = bodyEl.querySelector('[data-dn-empty]')
                ? 'There is no vendor records for this pull.'
                : '';
            // PDF export works for both report types (each loads its own .frx).
            btnPdf.disabled = !!emptyReason;
            btnPdf.title = emptyReason;
            btnPrint.disabled = !!emptyReason;
            btnPrint.title = emptyReason;
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
            // Paint the row immediately so the badge moves before the network
            // settles, then refetch — under "Unsigned for my role" this pull has
            // just left the result set, and only the server knows that.
            markRowSigned(selectedPullId, party);
            refreshEligibility();
            loadPreview();
            refreshList();
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
            // Update each signed row in place (badge + chip) for instant feedback.
            signedResults.forEach(x => markRowSigned(x.pullId, r.party || party));
            // Signed pulls are no longer eligible — drop them from the carried
            // selection (they may be off-page, so clear the Map, not just the
            // visible checkboxes) and re-sync.
            signedResults.forEach(x => selected.delete(String(x.pullId).toLowerCase()));
            rowsEl.querySelectorAll('.pull-check:checked').forEach(cb => {
                if (!selected.has(String(cb.dataset.pullId).toLowerCase())) cb.checked = false;
            });
            refreshEligibility();
            syncBatchBar();
            refreshList();
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

    // ----- Filter bar (server-side: every filter goes into the SQL query) ---
    //
    // This bar used to filter the ~50 rows already in the DOM while the pager
    // counted the whole table. Searching a pull number that sat on page 12
    // therefore found nothing, and the header counter ("N pulls") disagreed
    // with the pager ("X closed pulls") by construction. Everything below now
    // round-trips to GET /api/reports/closed-pulls, which applies the filters
    // in SQL and returns the page slice and the matching total together.
    const filterQ         = document.querySelector('.filter-q');
    const filterPull      = document.querySelector('.filter-pull');
    const filterDateRange = document.getElementById('filter-date-range');
    const filterFrom      = document.querySelector('.filter-from');
    const filterTo        = document.querySelector('.filter-to');
    const filterWh        = document.querySelector('.filter-wh');
    const filterSign      = document.getElementById('filter-sign');
    const customDateRow   = document.getElementById('reports-custom-date-row');
    const pagerEl         = document.getElementById('reports-pagination');

    // Phase 7e — the current user's signing parties (lowercase: customer /
    // warehouse / production). batchParties excludes Warehouse (auto-signed at
    // close → never batch-signable).
    const signParties  = Array.isArray(window.__signParties) ? window.__signParties : [];
    const batchParties = signParties.filter(p => p === 'customer' || p === 'production');

    const PAGE_SIZE = 50;
    const DEBOUNCE_MS = 300;

    let currentPage  = 1;
    let currentTotal = 0;
    let listAbort    = null;   // aborts the in-flight list request
    let listSeq      = 0;      // monotonic guard — only the newest response renders
    let paginationCtrl = null;
    let debounceTimer = null;

    // Selection survives page navigation: a supervisor gathers pulls across
    // several pages and signs once. It is cleared on any FILTER change, because
    // the population the operator was choosing from no longer exists — silently
    // signing a pull that scrolled out of the result set is the failure mode
    // worth designing against. Keyed by lowercase pull id; the value carries
    // enough signature state to judge eligibility for rows that are off-page.
    const selected = new Map();

    // ----- Date range → an absolute UTC window -----------------------------
    // The browser resolves the bucket against the OPERATOR's calendar and sends
    // instants; the server compares them against ClosedAt (stored as
    // SYSUTCDATETIME). Doing it this way fixes the old off-by-one, where a pull
    // closed before 07:00 Bangkok time carried the previous day's UTC date and
    // bucketed a day early.
    //
    // Bucket boundaries deliberately match the ones dashboard.js groups by, so
    // "This week" still means days 2..6 back — it excludes today and yesterday,
    // which have their own buckets. Half-open [from, to) throughout, so no two
    // buckets can both claim a pull closed exactly at midnight.
    const DAY_MS = 86400000;

    function resolveDateWindow() {
        const v = filterDateRange ? filterDateRange.value : 'all';
        // "All dates" sends NO bounds at all — the server then appends no date
        // predicate. That is the whole point; don't "helpfully" substitute a
        // wide range here.
        if (v === 'all') return {};

        const midnight = new Date();
        midnight.setHours(0, 0, 0, 0);
        const at = (days) => new Date(midnight.getTime() + days * DAY_MS).toISOString();

        switch (v) {
            case 'today':       return { closedFrom: at(0),   closedTo: at(1) };
            case 'yesterday':   return { closedFrom: at(-1),  closedTo: at(0) };
            case 'last_2_days': return { closedFrom: at(-1),  closedTo: at(1) };
            case 'this_week':   return { closedFrom: at(-6),  closedTo: at(-1) };
            case 'last_week':   return { closedFrom: at(-13), closedTo: at(-6) };
            case 'custom': {
                const out = {};
                if (filterFrom && filterFrom.value) {
                    const d = new Date(filterFrom.value + 'T00:00:00');
                    if (!isNaN(d)) out.closedFrom = d.toISOString();
                }
                if (filterTo && filterTo.value) {
                    // The picker's "To" is inclusive to the operator, so the
                    // exclusive bound is the following midnight.
                    const d = new Date(filterTo.value + 'T00:00:00');
                    if (!isNaN(d)) out.closedTo = new Date(d.getTime() + DAY_MS).toISOString();
                }
                return out;
            }
            default: return {};
        }
    }

    /** True when anything other than the page number is narrowing the list. */
    function hasActiveFilter() {
        return !!((filterQ && filterQ.value.trim()) ||
                  (filterPull && filterPull.value.trim()) ||
                  (filterWh && filterWh.value) ||
                  (filterSign && filterSign.value && filterSign.value !== 'all') ||
                  (filterDateRange && filterDateRange.value !== 'all'));
    }

    function buildQuery() {
        const params = new URLSearchParams();
        const q  = (filterQ    && filterQ.value.trim())    || '';
        const pn = (filterPull && filterPull.value.trim()) || '';
        if (q)  params.set('q', q);
        if (pn) params.set('pullNumber', pn);
        if (filterWh   && filterWh.value)   params.set('warehouseId', filterWh.value);
        if (filterSign && filterSign.value) params.set('sign', filterSign.value);
        const win = resolveDateWindow();
        if (win.closedFrom) params.set('closedFrom', win.closedFrom);
        if (win.closedTo)   params.set('closedTo',   win.closedTo);
        params.set('page', String(currentPage));
        params.set('pageSize', String(PAGE_SIZE));
        return params.toString();
    }

    // ----- Fetch + render ---------------------------------------------------
    async function refreshList() {
        // Cancel whatever is in flight. Without this, a fast "0000031539" typed
        // over a slow "0" leaves two requests racing and the stale one can land
        // last. The sequence number is the second belt: abort() is not
        // guaranteed to beat a response already being parsed.
        if (listAbort) listAbort.abort();
        listAbort = new AbortController();
        const seq = ++listSeq;

        rowsEl.setAttribute('aria-busy', 'true');
        rowsEl.classList.add('is-loading');

        let payload;
        try {
            const resp = await fetch('/api/reports/closed-pulls?' + buildQuery(), {
                credentials: 'same-origin',
                signal: listAbort.signal,
            });
            if (seq !== listSeq) return;          // superseded while awaiting
            if (!resp.ok) {
                renderError(`Could not load closed pulls (HTTP ${resp.status}).`);
                return;
            }
            payload = await resp.json();
        } catch (err) {
            if (err && err.name === 'AbortError') return;   // expected on supersede
            if (seq !== listSeq) return;
            renderError(`Network error: ${err.message || String(err)}`);
            return;
        }
        if (seq !== listSeq) return;

        currentTotal = payload.total | 0;
        renderRows(payload.items || []);
        renderCount(currentTotal);
        renderPager();
        refreshEligibility();
        syncBatchBar();
    }

    function renderError(message) {
        rowsEl.removeAttribute('aria-busy');
        rowsEl.classList.remove('is-loading');
        rowsEl.innerHTML = `<li class="list-empty">${escapeHtml(message)}</li>`;
        if (countEl) countEl.textContent = '—';
    }

    // One row. Mirrors the markup Razor used to emit, attribute for attribute,
    // so reports.css and the sign/eligibility code keep working unchanged.
    function rowHtml(p) {
        const id = String(p.id);
        const closedDate = p.closedAt ? String(p.closedAt).slice(0, 10) : '';
        const pullDate   = p.pullDate ? String(p.pullDate).slice(0, 10) : '';
        const checkbox = batchParties.length
            ? `<input type="checkbox" class="pull-check" data-pull-id="${escapeHtml(id)}"` +
              ` aria-label="Select ${escapeHtml(p.pullNumber)} for batch signing">`
            : '';
        const lock = p.lockPoByPull
            ? '<span class="pull-lock-badge" title="PO allocation locked to this pull">PO LOCK</span>'
            : '';
        const ref = p.referenceNumber
            ? `<span title="Reference: ${escapeHtml(p.referenceNumber)}"><i class="bi bi-paperclip"></i></span>`
            : '';
        const chip = (on, label, initial) =>
            `<span class="sig-chip ${on ? 'on' : ''}" title="${label} ${on ? 'signed' : 'unsigned'}">${initial}</span>`;

        return `<li class="pull-row${String(selectedPullId || '').toLowerCase() === id.toLowerCase() ? ' selected' : ''}"
                data-pull-id="${escapeHtml(id)}"
                data-pull-number="${escapeHtml(p.pullNumber)}"
                data-warehouse-id="${escapeHtml(p.warehouseId)}"
                data-closed-at="${escapeHtml(closedDate)}"
                data-signed-count="${p.signedCount | 0}"
                data-customer-signed="${p.customerSigned ? 'true' : 'false'}"
                data-warehouse-signed="${p.warehouseSigned ? 'true' : 'false'}"
                data-production-signed="${p.productionSigned ? 'true' : 'false'}">
                <div class="row-top">
                    ${checkbox}
                    <span class="pull-number">${escapeHtml(p.pullNumber)}</span>
                    <span class="sig-badge ${p.isComplete ? 'is-complete' : ''}"
                          title="${p.signedCount | 0} of 3 parties signed">${p.signedCount | 0}/3</span>
                    ${lock}
                </div>
                <div class="row-meta">
                    <span title="Pull date">${escapeHtml(pullDate)}</span>
                    <span>${escapeHtml(p.warehouseCode)}</span>
                </div>
                <div class="row-stats">
                    <span>Items <b>${p.itemCount | 0}</b></span>
                    <span>Qty <b>${Number(p.totalReceived || 0).toLocaleString()}</b></span>
                    ${ref}
                    <span class="sig-chips" aria-label="Signature status">
                        ${chip(p.warehouseSigned,  'Warehouse',  'W')}
                        ${chip(p.customerSigned,   'Customer',   'C')}
                        ${chip(p.productionSigned, 'Production', 'P')}
                    </span>
                </div>
            </li>`;
    }

    function renderRows(items) {
        rowsEl.removeAttribute('aria-busy');
        rowsEl.classList.remove('is-loading');
        if (!items.length) {
            rowsEl.innerHTML = `<li class="list-empty">${
                hasActiveFilter()
                    ? 'No closed pulls match these filters.'
                    : 'No closed pulls with delivery activity yet. Close a pull (Receive → Close) with at least one non-cancelled receipt and it will appear here.'
            }</li>`;
            return;
        }
        rowsEl.innerHTML = items.map(rowHtml).join('');
        // Restore the checkboxes for rows that are part of a selection carried
        // over from another page.
        rowsEl.querySelectorAll('.pull-check[data-pull-id]').forEach(cb => {
            cb.checked = selected.has(String(cb.dataset.pullId).toLowerCase());
        });
    }

    // The header counter and the pager now read the same server total, so they
    // cannot disagree. It used to count visible DOM rows.
    function renderCount(total) {
        if (!countEl) return;
        countEl.textContent = total.toLocaleString() + (total === 1 ? ' pull' : ' pulls');
    }

    function renderPager() {
        if (!pagerEl || typeof window.mountPagination !== 'function') return;
        if (!paginationCtrl) {
            paginationCtrl = window.mountPagination(pagerEl, {
                page: currentPage,
                pageSize: PAGE_SIZE,
                total: currentTotal,
                label: 'closed pulls',
                onChange: (newPage) => { currentPage = newPage; refreshList(); },
            });
        } else {
            paginationCtrl.update({ page: currentPage, total: currentTotal, pageSize: PAGE_SIZE });
        }
    }

    // ----- Filter events ----------------------------------------------------
    // Any filter change resets to page 1 (page 7 of the old result set means
    // nothing in the new one) and drops the selection.
    function onFilterChanged() {
        currentPage = 1;
        if (selected.size) {
            selected.clear();
            if (batchResult) batchResult.textContent = '';
        }
        refreshList();
    }

    function onFilterChangedDebounced() {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(onFilterChanged, DEBOUNCE_MS);
    }

    [filterQ, filterPull].forEach(el => {
        if (el) el.addEventListener('input', onFilterChangedDebounced);
    });
    [filterFrom, filterTo].forEach(el => {
        if (el) el.addEventListener('change', onFilterChanged);
    });
    if (filterWh)   filterWh.addEventListener('change', onFilterChanged);
    if (filterSign) filterSign.addEventListener('change', onFilterChanged);
    if (filterDateRange) {
        filterDateRange.addEventListener('change', () => {
            if (customDateRow) customDateRow.hidden = filterDateRange.value !== 'custom';
            // Switching INTO "Custom range…" with both pickers empty would send
            // no bounds, i.e. silently behave as "All dates". Wait for a date.
            if (filterDateRange.value === 'custom' &&
                !(filterFrom && filterFrom.value) && !(filterTo && filterTo.value)) return;
            onFilterChanged();
        });
    }

    // ----- Warehouse filter options ----------------------------------------
    // From /api/warehouses, not from the rows on screen: options built from the
    // current page could only ever offer the warehouses that page happened to
    // contain. The select is admin-only (the server pins everyone else to their
    // session warehouse), so for other roles it is removed rather than left as
    // a control that does nothing.
    async function populateWarehouseFilter() {
        if (!filterWh) return;
        if (!window.__reportsIsAdmin) {
            const wrap = filterWh.closest('label') || filterWh;
            wrap.remove();
            return;
        }
        try {
            const resp = await fetch('/api/warehouses?status=active', { credentials: 'same-origin' });
            if (!resp.ok) return;
            const rows = await resp.json();
            const frag = document.createDocumentFragment();
            (rows || []).forEach(w => {
                const opt = document.createElement('option');
                opt.value = w.id;
                opt.textContent = w.code;
                opt.title = w.name || '';
                frag.appendChild(opt);
            });
            filterWh.appendChild(frag);
        } catch { /* leave "All warehouses" as the only option */ }
    }

    // Restore the date range filter from ?dateRange=... if the URL specifies
    // a recognized value; the HTML default is already "last_2_days" so a
    // bare /Reports load drops into the operational window.
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
    // (rendered only when they can batch). Selecting pulls enables the batch
    // bar; "Sign N as {Party}" POSTs /api/reports/sign-batch (7d) with pull ids
    // only — never row payloads, so the server re-reads every pull it touches.
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

    /** Is this party still unsigned on the given selection entry / row state? */
    function partyUnsigned(state, party) {
        return state[String(party).toLowerCase() + 'Signed'] !== true;
    }

    // Disable + clear checkboxes whose current-party box is already signed, so
    // the selection can only ever target genuinely-unsigned boxes. Also prunes
    // carried-over selections that the newly-chosen party has already signed —
    // those rows may be off-page, which is why the Map holds their state.
    function refreshEligibility() {
        const party = (currentParty() || '').toLowerCase();
        if (!party) return;
        for (const [id, state] of selected) {
            if (!partyUnsigned(state, party)) selected.delete(id);
        }
        rowsEl.querySelectorAll('.pull-row[data-pull-id]').forEach(row => {
            const cb = row.querySelector('.pull-check');
            if (!cb) return;
            const signed = row.dataset[party + 'Signed'] === 'true';
            cb.disabled = signed;
            if (signed && cb.checked) cb.checked = false;
            row.classList.toggle('sig-ineligible', signed);
        });
    }

    function selectedIds() { return Array.from(selected.keys()); }

    /** How many selected pulls are NOT rendered on the current page. */
    function offPageSelectedCount() {
        let onPage = 0;
        rowsEl.querySelectorAll('.pull-row[data-pull-id]').forEach(row => {
            if (selected.has(String(row.dataset.pullId).toLowerCase())) onPage++;
        });
        return selected.size - onPage;
    }

    // Hoisted (function declaration) so refreshList can call it before this
    // block runs on first load.
    function syncBatchBar() {
        if (!batchBar) return;
        const n = selected.size;
        // Keep the bar — and its role combobox — reachable whenever batch signing
        // is available, even with nothing selected (e.g. right after a batch sign
        // auto-clears the selection). Otherwise a pull already signed for the
        // current party has its checkbox disabled AND the combobox hidden, so the
        // operator can't switch role to sign its remaining open slots. Only the
        // action controls are gated by the selection count.
        const party = currentParty();
        batchBar.hidden = false;
        if (batchCount) {
            if (n === 0) {
                batchCount.textContent = `Select pulls to sign as ${party}`;
                batchCount.classList.remove('has-selection');
            } else {
                // Selection spans pages, so say so: the Sign button is about to
                // act on rows the operator cannot currently see.
                const off = offPageSelectedCount();
                batchCount.textContent = off > 0
                    ? `${n} selected (${off} on other pages)`
                    : `${n} selected`;
                batchCount.classList.add('has-selection');
            }
        }
        if (batchSign) {
            batchSign.textContent = n === 0 ? `Sign as ${party}` : `Sign ${n} as ${party}`;
            batchSign.disabled = n === 0;
        }
        if (batchClear) batchClear.disabled = n === 0;
    }

    // Flip a pull's list row to "party signed" in place — bumps the N/3 badge
    // (+ is-complete at 3) and lights the party chip — so the list reflects a
    // sign immediately, before the refetch lands.
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
            const cb = e.target.closest('.pull-check[data-pull-id]');
            if (!cb) return;
            const row = cb.closest('.pull-row[data-pull-id]');
            const id = String(cb.dataset.pullId).toLowerCase();
            if (cb.checked && row) {
                selected.set(id, {
                    pullNumber:       row.dataset.pullNumber,
                    customerSigned:   row.dataset.customerSigned === 'true',
                    warehouseSigned:  row.dataset.warehouseSigned === 'true',
                    productionSigned: row.dataset.productionSigned === 'true',
                });
            } else {
                selected.delete(id);
            }
            batchResult.textContent = '';
            syncBatchBar();
        });
    }
    if (batchParty) batchParty.addEventListener('change', () => { refreshEligibility(); syncBatchBar(); });
    if (batchClear) batchClear.addEventListener('click', () => {
        selected.clear();
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

    // ----- Startup ----------------------------------------------------------
    populateWarehouseFilter();
    refreshList();

    // ----- Helpers ---------------------------------------------------------
    function escapeHtml(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        }[c]));
    }
})();
