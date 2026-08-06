/* ========================================================================
 * Phase 10.6 — /Admin/ErpSync page (sync history + manual trigger)
 *
 * Data sources:
 *   GET /api/admin/erp-sync/log?page=&pageSize=   paginated history
 *   GET /api/admin/erp-sync/state                 { isRunning } for auto-refresh
 *   POST /api/admin/erp-sync/trigger              fire-and-forget manual sync
 *   GET /api/admin/erp-sync/jobs/{jobId}          poll job state for the
 *                                                 trigger modal's status UI
 *
 * Auto-refresh rule: when /state.isRunning is true, refetch the list every
 * 5s. Once isRunning flips false, do one final refresh (to pick up the
 * just-completed row's terminal status) and stop the polling.
 * ====================================================================== */
(function () {
    'use strict';

    const PAGE_SIZE = 50;
    let currentPage = 1;
    let paginationCtrl = null;
    let stateTimer = null;
    let warehousesCache = null;

    function esc(s) {
        return String(s ?? '').replace(/[&<>"']/g, c =>
            ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    }

    function fmtDate(s) {
        if (!s) return '—';
        try { return new Date(s).toLocaleString(); } catch { return s; }
    }

    function fmtElapsed(ms) {
        if (ms == null) return '—';
        if (ms < 1000) return ms + ' ms';
        if (ms < 60000) return (ms / 1000).toFixed(1) + ' s';
        const m = Math.floor(ms / 60000), s = Math.round((ms % 60000) / 1000);
        return `${m}m ${s}s`;
    }

    function statusBadge(status) {
        const cls = status === 'succeeded' ? 'success'
                  : status === 'failed'    ? 'danger'
                  : 'info';                                      // 'running' or anything else
        return `<span class="badge bg-${cls}">${esc(status)}</span>`;
    }

    function triggerBadge(t) {
        const cls = t === 'manual' ? 'primary' : 'secondary';
        return `<span class="badge bg-${cls}">${esc(t)}</span>`;
    }

    function renderRows(items) {
        const tbody = document.getElementById('rows');
        const empty = document.getElementById('empty');
        if (!items || items.length === 0) {
            tbody.innerHTML = '';
            empty.hidden = false;
            return;
        }
        empty.hidden = true;
        tbody.innerHTML = items.map(r => {
            const detail = r.errorMessage
                ? `<span class="text-danger" title="${esc(r.errorMessage)}"><i class="bi bi-exclamation-triangle"></i> ${esc(r.errorMessage.substring(0, 60))}${r.errorMessage.length > 60 ? '…' : ''}</span>`
                : `<code class="text-muted" style="font-size: 11px;">${esc(r.runId)}</code>`;
            return `<tr>
                <td><small>${esc(fmtDate(r.startedAt))}</small></td>
                <td>${triggerBadge(r.triggeredBy)}</td>
                <td>${statusBadge(r.status)}</td>
                <td><small>${esc(r.actorName)}</small></td>
                <td class="num">${r.created ?? '—'}</td>
                <td class="num">${r.updated ?? '—'}</td>
                <td class="num">${r.skippedClosed ?? '—'}</td>
                <td class="num ${(r.errors ?? 0) > 0 ? 'text-danger fw-bold' : ''}">${r.errors ?? '—'}</td>
                <td class="num"><small>${fmtElapsed(r.elapsedMs)}</small></td>
                <td>${detail}</td>
            </tr>`;
        }).join('');
    }

    async function loadList(page) {
        currentPage = page || 1;
        try {
            const r = await fetch(`/api/admin/erp-sync/log?page=${currentPage}&pageSize=${PAGE_SIZE}`);
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const data = await r.json();
            renderRows(data.items);
            document.getElementById('list-count').textContent =
                `${data.total} record${data.total === 1 ? '' : 's'}`;

            // Mount or update pagination
            const host = document.getElementById('pagination-host');
            if (!paginationCtrl) {
                paginationCtrl = window.mountPagination(host, {
                    page: data.page,
                    pageSize: data.pageSize,
                    total: data.total,
                    onChange: (newPage) => loadList(newPage),
                });
            } else {
                paginationCtrl.update({
                    page: data.page,
                    pageSize: data.pageSize,
                    total: data.total,
                });
            }
        } catch (err) {
            console.error('Load failed:', err);
        }
    }

    // Auto-refresh while a sync is in flight. /state is cheap (single
    // Interlocked read at the controller) so polling at 5s is fine.
    async function checkState() {
        try {
            const r = await fetch('/api/admin/erp-sync/state');
            if (!r.ok) return;
            const { isRunning } = await r.json();
            const banner = document.getElementById('state-banner');
            if (isRunning) {
                banner.hidden = false;
                document.getElementById('state-banner-msg').textContent =
                    'A sync is in flight — auto-refreshing every 5 s.';
                // Re-fetch list each cycle so a running row's elapsed-counter
                // updates and the row's status flips on completion.
                await loadList(currentPage);
            } else {
                if (!banner.hidden) {
                    // Just transitioned to idle — one final refresh so the
                    // terminal status (succeeded/failed) shows up promptly.
                    banner.hidden = true;
                    await loadList(currentPage);
                }
            }
        } catch (err) {
            console.error('State probe failed:', err);
        }
    }

    function startStatePoll() {
        if (stateTimer) clearInterval(stateTimer);
        stateTimer = setInterval(checkState, 5000);
    }

    // ============ SYNC NOW MODAL ============
    async function ensureWarehouses() {
        if (warehousesCache) return warehousesCache;
        try {
            const r = await fetch('/api/warehouses?status=active');
            warehousesCache = r.ok ? await r.json() : [];
        } catch { warehousesCache = []; }
        return warehousesCache;
    }

    function populateWarehouseSelect(sel) {
        sel.innerHTML = warehousesCache
            .map(w => `<option value="${esc(w.id)}">${esc(w.code)} · ${esc(w.name)}</option>`)
            .join('');
    }

    function initSyncModal() {
        const modalEl = document.getElementById('syncModal');
        const modal = new bootstrap.Modal(modalEl);
        // Phase 13.9.2 — warehouse + backfill selectors removed; the worker
        // path (RunNowAsync) reads them from per-source config instead.
        const sourceSel = document.getElementById('sync-source');
        const sourceLabel = document.getElementById('sync-source-label');
        const trigBtn = document.getElementById('sync-trigger');
        const cancelBtn = document.getElementById('sync-cancel');
        const statusEl = document.getElementById('sync-status');
        let pollTimer = null;

        function setStatus(html, cls) {
            statusEl.className = 'mt-3 alert alert-' + (cls || 'info') + ' py-2 mb-0';
            statusEl.innerHTML = html;
            statusEl.hidden = false;
        }
        function clearStatus() { statusEl.hidden = true; statusEl.innerHTML = ''; }
        function setBusy(busy) {
            trigBtn.disabled = busy;
            cancelBtn.disabled = busy;
            sourceSel.disabled = busy;
            trigBtn.innerHTML = busy
                ? '<span class="spinner-border spinner-border-sm me-1"></span> Syncing…'
                : 'Start sync';
        }

        document.getElementById('btn-sync-now').addEventListener('click', async () => {
            clearStatus();
            setBusy(false);
            // Populate the SOURCE dropdown each open so a /Config + restart
            // change is reflected next modal show.
            await window.ErpSourceDropdown.populate({ selectEl: sourceSel, labelEl: sourceLabel });
            modal.show();
        });

        async function pollJob(jobId) {
            const TERMINAL = new Set(['Succeeded', 'Failed', 'Deleted']);
            try {
                const r = await fetch('/api/admin/erp-sync/jobs/' + encodeURIComponent(jobId));
                if (!r.ok) {
                    setStatus('Lost track of job (' + r.status + ').', 'warning');
                    setBusy(false);
                    return;
                }
                const data = await r.json();
                const state = data.state || '(unknown)';
                if (!TERMINAL.has(state)) {
                    setStatus('Status: <b>' + esc(state) + '</b>…', 'info');
                    pollTimer = setTimeout(() => pollJob(jobId), 2000);
                    return;
                }
                setBusy(false);
                if (state === 'Succeeded') {
                    modal.hide();
                    await loadList(currentPage);  // pick up the new row
                } else {
                    setStatus('Sync ended in state <b>' + esc(state) + '</b>' +
                        (data.reason ? ' — ' + esc(data.reason) : ''),
                        state === 'Failed' ? 'danger' : 'warning');
                }
            } catch (err) {
                setStatus('Polling error: ' + esc(err.message || err), 'danger');
                setBusy(false);
            }
        }

        trigBtn.addEventListener('click', async () => {
            // Phase 13.9.3 — payload is sourceName only. Empty value = "All
            // enabled" sentinel (server reads null/"" as "no source filter").
            // Warehouse + backfill come from per-source config server-side.
            const sourceName = sourceSel.value || null;
            clearStatus();
            setBusy(true);
            try {
                const r = await fetch('/api/admin/erp-sync/trigger', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sourceName }),
                });
                if (r.status === 202) {
                    const data = await r.json();
                    setStatus('Enqueued (job <code>' + esc(data.jobId) + '</code>). Polling…', 'info');
                    pollJob(data.jobId);
                } else if (r.status === 409) {
                    setBusy(false);
                    setStatus('Another sync is already in progress.', 'warning');
                } else {
                    setBusy(false);
                    const body = await r.text();
                    setStatus('Trigger failed (' + r.status + '): ' + esc(body || '(no body)'), 'danger');
                }
            } catch (err) {
                setBusy(false);
                setStatus('Trigger error: ' + esc(err.message || err), 'danger');
            }
        });

        modalEl.addEventListener('hidden.bs.modal', () => {
            if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
            clearStatus();
            setBusy(false);
        });
    }

    document.getElementById('btn-refresh').addEventListener('click', () => loadList(currentPage));
    initSyncModal();
    loadList(1);
    startStatePoll();
})();
