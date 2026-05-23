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

    let selectedPullId = null;
    let selectedPullNumber = null;

    // ----- Row selection ---------------------------------------------------
    rowsEl.addEventListener('click', (e) => {
        const row = e.target.closest('.pull-row[data-pull-id]');
        if (!row) return;
        selectRow(row);
    });

    async function selectRow(row) {
        selectedPullId = row.dataset.pullId;
        selectedPullNumber = row.dataset.pullNumber;
        rowsEl.querySelectorAll('.pull-row').forEach(r =>
            r.classList.toggle('selected', r === row));

        titleEl.textContent = `${selectedPullNumber} · loading…`;
        bodyEl.innerHTML = '<div class="preview-loading">Loading delivery orders…</div>';
        btnPdf.disabled = true;
        btnPrint.disabled = true;

        try {
            const resp = await fetch(`/api/reports/do/${encodeURIComponent(selectedPullId)}/preview`, {
                credentials: 'same-origin',
            });
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
            const doCount = bodyEl.querySelectorAll('.do-document').length;
            titleEl.textContent =
                `${selectedPullNumber} · ${doCount} delivery order${doCount === 1 ? '' : 's'}`;
            btnPdf.disabled = false;
            btnPrint.disabled = false;
        } catch (err) {
            bodyEl.innerHTML =
                `<div class="preview-error">Network error: ${escapeHtml(err.message || String(err))}</div>`;
            titleEl.textContent = `${selectedPullNumber} · error`;
        }
    }

    // ----- Export PDF -----------------------------------------------------
    // /api/reports/do/{id}/export.pdf always sets Content-Disposition:
    // attachment so navigating to it triggers a Save As dialog.
    btnPdf.addEventListener('click', () => {
        if (!selectedPullId || btnPdf.disabled) return;
        window.location.href = `/api/reports/do/${encodeURIComponent(selectedPullId)}/export.pdf`;
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
    const filterQ    = document.querySelector('.filter-q');
    const filterPull = document.querySelector('.filter-pull');
    const filterFrom = document.querySelector('.filter-from');
    const filterTo   = document.querySelector('.filter-to');
    const filterWh   = document.querySelector('.filter-wh');

    [filterQ, filterPull, filterFrom, filterTo, filterWh].forEach(el => {
        if (!el) return;
        el.addEventListener('input', applyFilters);
    });

    function applyFilters() {
        const q     = (filterQ.value    || '').trim().toLowerCase();
        const pn    = (filterPull.value || '').trim().toLowerCase();
        const from  = filterFrom.value || '';
        const to    = filterTo.value   || '';
        const wh    = filterWh.value   || '';
        let visible = 0;
        rowsEl.querySelectorAll('.pull-row[data-pull-id]').forEach(row => {
            const pull = (row.dataset.pullNumber || '').toLowerCase();
            const date = row.querySelector('.row-meta span:nth-child(1)')?.textContent || '';
            const code = row.querySelector('.row-meta span:nth-child(2)')?.textContent || '';
            const hayQ = pull + ' ' + code;
            let show = true;
            if (q  && !hayQ.includes(q)) show = false;
            if (pn && !pull.includes(pn)) show = false;
            if (from && date < from) show = false;
            if (to   && date > to)   show = false;
            if (wh   && row.dataset.warehouseId !== wh) show = false;
            row.style.display = show ? '' : 'none';
            if (show) visible++;
        });
        countEl.textContent = visible + (visible === 1 ? ' pull' : ' pulls');
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

    // ----- Helpers ---------------------------------------------------------
    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        }[c]));
    }
})();
