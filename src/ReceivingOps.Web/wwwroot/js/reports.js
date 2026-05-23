// v2.x Phase 7.4 — Reports page (two-pane layout) row selection + preview wiring.
//
// Commit 1 skeleton: row click → highlight, toolbar buttons stay disabled until
// the preview fetch lands. The preview fetch + Export PDF + Print handlers
// arrive in commit 2 (HTML preview endpoint); for now the click is a no-op
// past the visual selection so the chrome can be browser-verified standalone.

(() => {
    'use strict';

    const rowsEl    = document.getElementById('pull-rows');
    const titleEl   = document.getElementById('preview-title');
    const bodyEl    = document.getElementById('preview-body');
    const btnPdf    = document.getElementById('btn-export-pdf');
    const btnPrint  = document.getElementById('btn-print');
    const countEl   = document.getElementById('result-count');

    let selectedPullId = null;

    // ----- Row selection ---------------------------------------------------
    rowsEl.addEventListener('click', (e) => {
        const row = e.target.closest('.pull-row[data-pull-id]');
        if (!row) return;
        selectRow(row);
    });

    function selectRow(row) {
        selectedPullId = row.dataset.pullId;
        const pullNumber = row.dataset.pullNumber;
        rowsEl.querySelectorAll('.pull-row').forEach(r =>
            r.classList.toggle('selected', r === row));
        // Placeholder until the preview endpoint lands in commit 2 — keep
        // the chrome behavior visible (title + buttons enable) so the
        // layout can be eyeballed.
        titleEl.textContent = pullNumber + ' · preview pending';
        bodyEl.innerHTML = '<div class="preview-loading">Preview render coming in commit 2…</div>';
        btnPdf.disabled = false;
        btnPrint.disabled = false;
    }

    // ----- Filter bar (client-side filter over server-rendered rows) -------
    // All rows are rendered server-side; filters narrow visibility client-
    // side. Cheap, no extra round trip. Q matches pull number + warehouse
    // code; pull-number filter is a separate convenience field.
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
    // Populated from the warehouseId data attribute on rendered rows — no
    // extra API needed, the universe is exactly the warehouses that have
    // closed pulls.
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
})();
