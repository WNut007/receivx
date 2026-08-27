/* ===========================================================================
   Reports → Pull Sheets

   The second section of /Reports. Shares the page shell with Delivery Orders
   and nothing else: its own filter bar, its own endpoints, and — the part that
   matters — a query that does NOT restrict to closed pulls.

   Preview and export hit the same server-side query, so the numbers on screen
   and the numbers in the file cannot drift. The preview call is what decides
   whether the export button is enabled.
   =========================================================================== */
(function () {
    'use strict';

    const PREVIEW_URL = '/api/reports/pull-sheets/preview';
    const EXPORT_URL  = '/api/reports/pull-sheets/export.xlsx';

    // ---- Section switching -------------------------------------------------

    const switchEl = document.getElementById('reports-section-switch');
    const sections = {
        'delivery-orders': document.getElementById('section-delivery-orders'),
        'pull-sheets':     document.getElementById('section-pull-sheets'),
    };
    // Each section owns its breadcrumb + subtitle; the shell just swaps them.
    const CHROME = {
        'delivery-orders': {
            eyebrow: 'Audit · Delivery Orders',
            subtitle: 'Closed pulls with delivery activity. Click a row to preview the DO or export PDF.',
        },
        'pull-sheets': {
            eyebrow: 'Planning · Pull Sheets',
            subtitle: 'Scheduled receiving windows by date and period, open pulls included. Preview, then export to xlsx.',
        },
    };

    const eyebrowEl  = document.getElementById('page-eyebrow');
    const subtitleEl = document.getElementById('page-subtitle');

    function showSection(name) {
        if (!sections[name]) return;
        Object.entries(sections).forEach(([key, el]) => {
            if (el) el.hidden = key !== name;
        });
        switchEl.querySelectorAll('.section-tab').forEach(tab => {
            const on = tab.dataset.section === name;
            tab.classList.toggle('active', on);
            tab.setAttribute('aria-selected', on ? 'true' : 'false');
        });
        if (eyebrowEl)  eyebrowEl.textContent  = CHROME[name].eyebrow;
        if (subtitleEl) subtitleEl.textContent = CHROME[name].subtitle;

        // First visit to Pull Sheets runs a preview so the section is not an
        // empty shell the operator has to prod before it says anything.
        if (name === 'pull-sheets' && !hasPreviewed) refresh();
    }

    if (switchEl) {
        switchEl.addEventListener('click', (e) => {
            const tab = e.target.closest('.section-tab');
            if (tab) showSection(tab.dataset.section);
        });
    }

    // ---- Elements ----------------------------------------------------------

    const whEl      = document.getElementById('ps-warehouse');
    const dateEl    = document.getElementById('ps-date');
    const periodEl  = document.getElementById('ps-period');
    const statusEl  = document.getElementById('ps-status');
    const refreshEl = document.getElementById('ps-refresh');
    const exportEl  = document.getElementById('ps-export');
    const msgEl     = document.getElementById('ps-message');
    const resolvedEl = document.getElementById('ps-resolved');
    const tbodyEl   = document.getElementById('ps-tbody');
    const moreEl    = document.getElementById('ps-more');

    if (!dateEl || !periodEl) return;  // section not rendered for this user

    let hasPreviewed = false;
    let inFlight = null;

    // ---- Defaults ----------------------------------------------------------

    // Today, and the period containing the current hour — the same "land the
    // operator where they already are" rule the Receiving picker uses. The hour
    // sets come off each option's data-hours, which Razor rendered from
    // ReceivingPeriods, so this does not restate the period map.
    (function applyDefaults() {
        const now = new Date();
        dateEl.value = [
            now.getFullYear(),
            String(now.getMonth() + 1).padStart(2, '0'),
            String(now.getDate()).padStart(2, '0'),
        ].join('-');

        const hour = now.getHours();
        for (const opt of periodEl.options) {
            const hours = (opt.dataset.hours || '').split(',').map(Number);
            if (hours.includes(hour)) { periodEl.value = opt.value; break; }
        }
    })();

    // ---- Warehouse options -------------------------------------------------

    (async function loadWarehouses() {
        if (!whEl) return;
        try {
            const r = await fetch('/api/warehouses', { headers: { Accept: 'application/json' } });
            if (!r.ok) return;
            const body = await r.json();
            const list = Array.isArray(body) ? body : (body.items || []);
            list.forEach(w => {
                const opt = document.createElement('option');
                opt.value = w.id;
                opt.textContent = w.code + (w.name ? ' · ' + w.name : '');
                whEl.appendChild(opt);
            });
        } catch { /* filter still works without it — "All warehouses" is valid */ }
    })();

    // ---- Preview -----------------------------------------------------------

    function criteriaQuery() {
        const q = new URLSearchParams();
        if (whEl && whEl.value) q.set('warehouseId', whEl.value);
        q.set('date', dateEl.value);
        q.set('period', periodEl.value);
        if (statusEl && statusEl.value) q.set('status', statusEl.value);
        return q;
    }

    async function refresh() {
        if (!dateEl.value) { setMessage('Pick a date.', 'warn'); return; }

        hasPreviewed = true;
        setBusy(true);
        clearMessage();

        // Late responses from a superseded filter must not overwrite a newer
        // one — the operator can change period faster than the query returns.
        const token = {};
        inFlight = token;

        try {
            const r = await fetch(PREVIEW_URL + '?' + criteriaQuery().toString(),
                                  { headers: { Accept: 'application/json' } });
            if (inFlight !== token) return;

            const body = await r.json().catch(() => null);
            if (!r.ok) {
                setMessage((body && body.error) || ('Preview failed (' + r.status + ')'), 'error');
                renderEmpty('Nothing to show.');
                exportEl.disabled = true;
                return;
            }
            render(body);
        } catch (err) {
            if (inFlight !== token) return;
            setMessage('Preview failed: ' + (err.message || 'network error'), 'error');
            exportEl.disabled = true;
        } finally {
            if (inFlight === token) setBusy(false);
        }
    }

    function render(data) {
        setMetric('ps-m-pulls',    data.pullCount);
        setMetric('ps-m-items',    data.itemCount);
        setMetric('ps-m-expected', data.totalExpected);
        setMetric('ps-m-received', data.totalReceived);

        // Say out loud which hours and which dates the period resolved to. On a
        // Night export that is two calendar dates, and the operator should not
        // have to open the file to discover it.
        if (resolvedEl) {
            const bits = [];
            if (data.periodLabel) bits.push('<b>' + esc(data.periodLabel) + '</b>');
            if (data.periodHours) bits.push('hours ' + esc(data.periodHours));
            if (data.periodDateRange) bits.push('reads ' + esc(data.periodDateRange));
            bits.push(fmt(data.detailRowCount) + ' detail row' + (data.detailRowCount === 1 ? '' : 's'));
            resolvedEl.innerHTML = bits.join(' · ');
        }

        const rows = data.summaryPreview || [];
        if (rows.length === 0) {
            renderEmpty('No pull sheet activity for this warehouse, date and period.');
        } else {
            tbodyEl.innerHTML = rows.map(r => `
                <tr>
                    <td class="mono">${esc(r.pullNumber)}</td>
                    <td class="mono">${esc(r.itemCode)}</td>
                    <td>${esc(r.description)}</td>
                    <td>${esc(r.vendorName || '—')}</td>
                    <td>${esc(r.building || '—')}</td>
                    <td class="num">${fmt(r.expectedQty)}</td>
                    <td class="num">${fmt(r.receivedQty)}</td>
                    <td class="num">${fmt(r.outstanding)}</td>
                    <td class="num">${(r.progress * 100).toFixed(1)}%</td>
                    <td>${esc(r.itemStatus)}</td>
                </tr>`).join('');
        }

        const hidden = (data.summaryRowCount || 0) - rows.length;
        if (moreEl) {
            moreEl.hidden = hidden <= 0;
            moreEl.textContent = hidden > 0
                ? fmt(hidden) + ' more row' + (hidden === 1 ? '' : 's') + ' in the exported file'
                : '';
        }

        if (data.exceedsRowLimit) {
            setMessage(data.message || 'Too many rows — narrow the filter.', 'error');
            exportEl.disabled = true;
        } else {
            exportEl.disabled = (data.detailRowCount || 0) === 0;
            if ((data.detailRowCount || 0) === 0) setMessage('Nothing to export for this selection.', 'warn');
        }
    }

    function renderEmpty(text) {
        tbodyEl.innerHTML = '<tr><td colspan="10" class="ps-empty">' + esc(text) + '</td></tr>';
        if (moreEl) moreEl.hidden = true;
    }

    // ---- Export ------------------------------------------------------------

    // Straight navigation: the endpoint returns the file with a
    // Content-Disposition filename, so the browser saves it under the server's
    // name and no blob plumbing is needed. A 400 would render as JSON in a new
    // tab, so the guard is checked here first via the preview state — the
    // button is only enabled when the preview said the export would succeed.
    if (exportEl) {
        exportEl.addEventListener('click', () => {
            if (exportEl.disabled) return;
            window.location.href = EXPORT_URL + '?' + criteriaQuery().toString();
        });
    }

    // ---- Wiring ------------------------------------------------------------

    if (refreshEl) refreshEl.addEventListener('click', refresh);
    [whEl, dateEl, periodEl, statusEl].forEach(el => {
        if (el) el.addEventListener('change', refresh);
    });

    // ---- Helpers -----------------------------------------------------------

    function setBusy(busy) {
        if (refreshEl) refreshEl.disabled = busy;
        if (busy && exportEl) exportEl.disabled = true;
    }

    function setMetric(id, value) {
        const el = document.getElementById(id);
        if (el) el.textContent = fmt(value);
    }

    function setMessage(text, kind) {
        if (!msgEl) return;
        msgEl.hidden = false;
        msgEl.textContent = text;
        msgEl.className = 'ps-message is-' + (kind || 'info');
    }

    function clearMessage() {
        if (!msgEl) return;
        msgEl.hidden = true;
        msgEl.textContent = '';
    }

    function fmt(n) {
        return (typeof n === 'number' ? n : 0).toLocaleString();
    }

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }
})();
