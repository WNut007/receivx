/* Phase 8.5 — My Exports page. Lists export jobs from
 * /api/exports/jobs, refreshes every 5 s while any row is still
 * queued or running, falls quiet once the dataset settles. Reuses the
 * shared mountPagination() control.
 *
 * Phase 8.4 ext — split into Pending / Downloaded tabs. Pending is
 * the actionable backlog (queued | running | failed |
 * succeeded-undownloaded); Downloaded is the archive of jobs the
 * operator already grabbed. Click Download → POST mark-downloaded →
 * row drifts to Downloaded on the next refresh + badges update. */
(() => {
    'use strict';

    const REFRESH_MS = 5000;
    const TAB_COUNTS_REFRESH_MS = 10000;
    let currentPage = 1;
    let currentTotal = 0;
    let currentRows = [];
    let currentTab = 'pending';
    let seeAll = false;
    let isAdmin = false;
    let refreshTimer = null;
    let tabCountsTimer = null;
    let paginationCtrl = null;

    const tbody = document.getElementById('exports-tbody');
    const refreshBanner = document.getElementById('auto-refresh-banner');
    const seeAllToggle = document.getElementById('see-all');
    const adminColumns = document.querySelectorAll('[data-admin-only]');
    const listCount = document.getElementById('list-count');
    const sectionTitle = document.getElementById('section-title');
    const tabButtons = document.querySelectorAll('.exports-tab');
    const pendingCountEl = document.getElementById('tab-count-pending');
    const downloadedCountEl = document.getElementById('tab-count-downloaded');

    // ---------- Helpers ----------
    function escHtml(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g,
            c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    }
    function fmtTime(iso) {
        if (!iso) return '—';
        const d = new Date(iso);
        if (isNaN(d.getTime())) return iso;
        return d.toLocaleString('en-GB', {
            day: '2-digit', month: 'short',
            hour: '2-digit', minute: '2-digit',
        });
    }
    function fmtRelative(iso) {
        if (!iso) return '';
        const d = new Date(iso);
        if (isNaN(d.getTime())) return '';
        const diffMs = Date.now() - d.getTime();
        const min = Math.round(diffMs / 60000);
        if (min < 1) return 'just now';
        if (min < 60) return `${min} min ago`;
        const hr = Math.round(min / 60);
        if (hr < 24) return `${hr}h ago`;
        const days = Math.round(hr / 24);
        return `${days}d ago`;
    }
    function jobTypeLabel(t) {
        switch (t) {
            case 'transactions': return 'Transactions';
            case 'pos':          return 'POs';
            case 'audit-log':    return 'Audit Log';
            default:             return t || '—';
        }
    }

    // ---------- Render ----------
    function renderRows() {
        if (currentRows.length === 0) {
            const emptyText = currentTab === 'downloaded'
                ? `<i class="bi bi-inbox"></i> No downloaded exports yet. Files you grab from the Pending tab will land here.`
                : `<i class="bi bi-cloud-slash"></i> No pending exports. Run an Export from /Transactions, /Pos, or /Masters → Audit Log.`;
            tbody.innerHTML = `<tr><td colspan="8" class="empty-row">${emptyText}</td></tr>`;
        } else {
            tbody.innerHTML = currentRows.map(r => {
                const status = r.effectiveStatus || r.status;
                // Requester column is always visible — useful self-confirmation
                // on the per-user view + identifies who ran what in admin see-all.
                const requesterCell = `<td class="requester-cell"><b>${escHtml(r.requesterName || '—')}</b><br>${escHtml(r.requesterEmail || '')}</td>`;
                const fileOrError =
                    status === 'failed'
                        ? `<span class="error-text" title="${escHtml(r.errorMessage || '')}">${escHtml(r.errorMessage || 'Unknown error')}</span>`
                        : r.fileName
                            ? `<span class="file-cell">${escHtml(r.fileName)}</span>`
                            : '<span class="file-cell">—</span>';
                let action;
                if (status === 'succeeded' && r.downloadUrl) {
                    // The "downloaded" data attribute lets us POST mark-downloaded
                    // on click without preventing the actual file download. We
                    // don't add the hook in the Downloaded tab — re-grabbing an
                    // archived file shouldn't re-trigger the (already-set) flag.
                    const markAttr = currentTab === 'downloaded' ? '' : ` data-mark-id="${escHtml(r.id)}"`;
                    action = `<a class="btn btn-primary export-download-link" href="${escHtml(r.downloadUrl)}"${markAttr} title="Download (link expires in 24h)">
                        <i class="bi bi-download"></i> Download</a>`;
                } else if (status === 'expired') {
                    action = `<span class="btn-disabled" title="File swept off disk past lifetime">Expired</span>`;
                } else if (status === 'failed') {
                    action = `<span class="btn-disabled" title="Hangfire retries exhausted">Failed</span>`;
                } else {
                    action = `<span class="btn-disabled" title="Job still in progress">In progress</span>`;
                }
                return `<tr>
                    <td><span class="when-cell">${fmtTime(r.enqueuedAt)}<span class="relative">${fmtRelative(r.enqueuedAt)}</span></span></td>
                    <td><span class="type-pill">${jobTypeLabel(r.jobType)}</span></td>
                    <td><span class="status-badge status-${status}">${status}</span></td>
                    ${requesterCell}
                    <td class="num">${r.rowsExported != null ? r.rowsExported.toLocaleString() : '—'}</td>
                    <td>${fileOrError}</td>
                    <td><span class="when-cell">${r.completedAt ? fmtTime(r.completedAt) : '—'}</span></td>
                    <td class="action-cell">${action}</td>
                </tr>`;
            }).join('');
        }
        listCount.textContent = currentTotal === 1 ? '1 record' : `${currentTotal.toLocaleString()} records`;

        // Auto-refresh banner ON when any row in flight (only meaningful
        // in Pending — Downloaded never has queued/running rows).
        const inFlight = currentTab === 'pending'
            && currentRows.some(r => r.status === 'queued' || r.status === 'running');
        refreshBanner.hidden = !inFlight;
        scheduleRefresh(inFlight);

        wireDownloadClicks();
    }

    function wireDownloadClicks() {
        // Each Download link in Pending fires mark-downloaded as a
        // fire-and-forget side effect; the browser still starts the
        // actual download from the href. After a short delay (browser
        // had time to grab the file) we re-fetch list + counts so the
        // row visibly moves to the Downloaded tab.
        tbody.querySelectorAll('.export-download-link[data-mark-id]').forEach(a => {
            a.addEventListener('click', async () => {
                const id = a.dataset.markId;
                if (!id) return;
                try {
                    await fetch(`/api/exports/${encodeURIComponent(id)}/mark-downloaded`, {
                        method: 'POST',
                        credentials: 'same-origin',
                    });
                } catch { /* silent — file still downloads */ }
                // Delay so the browser starts the download before we
                // redraw the table out from under it.
                setTimeout(() => {
                    loadList();
                    refreshTabCounts();
                }, 800);
            }, { once: true });
        });
    }

    function scheduleRefresh(inFlight) {
        if (refreshTimer) { clearTimeout(refreshTimer); refreshTimer = null; }
        if (inFlight) {
            refreshTimer = setTimeout(loadList, REFRESH_MS);
        }
    }

    // ---------- Fetch ----------
    async function loadList() {
        try {
            const params = new URLSearchParams();
            params.set('page', currentPage);
            params.set('pageSize', 50);
            params.set('tab', currentTab);
            if (seeAll) params.set('all', 'true');
            const resp = await fetch('/api/exports/jobs?' + params.toString(), { credentials: 'same-origin' });
            if (resp.status === 401) { window.location.href = '/Account/Login'; return; }
            if (!resp.ok) {
                tbody.innerHTML = `<tr><td colspan="8" class="empty-row">
                    <i class="bi bi-exclamation-triangle"></i> Load failed (${resp.status})
                </td></tr>`;
                return;
            }
            const page = await resp.json();
            currentRows = page.items || [];
            currentTotal = page.total | 0;
            currentPage = page.page || 1;
            renderRows();
            paginationCtrl?.update({ page: currentPage, total: currentTotal, pageSize: 50 });
        } catch (err) {
            console.error('exports loadList failed', err);
        }
    }

    async function refreshTabCounts() {
        try {
            const params = new URLSearchParams();
            if (seeAll) params.set('all', 'true');
            const qs = params.toString();
            const resp = await fetch('/api/exports/tab-counts' + (qs ? '?' + qs : ''), { credentials: 'same-origin' });
            if (!resp.ok) return;
            const counts = await resp.json();
            updateCountPill(pendingCountEl, counts.pending);
            updateCountPill(downloadedCountEl, counts.downloaded);
        } catch { /* silent */ }
    }

    function updateCountPill(el, n) {
        if (!el) return;
        if (n > 0) {
            el.textContent = n > 999 ? '999+' : String(n);
            el.hidden = false;
        } else {
            el.hidden = true;
        }
    }

    // ---------- Admin gate ----------
    async function loadAdminFlag() {
        try {
            const r = await fetch('/api/auth/me', { credentials: 'same-origin' });
            if (!r.ok) return;
            const me = await r.json();
            isAdmin = (me?.role || me?.roleKey) === 'admin';
            if (isAdmin) {
                adminColumns.forEach(el => el.hidden = false);
            }
        } catch { /* not fatal */ }
    }

    // ---------- Events ----------
    seeAllToggle?.addEventListener('change', () => {
        seeAll = seeAllToggle.checked;
        currentPage = 1;
        loadList();
        refreshTabCounts();
    });
    document.getElementById('btn-refresh').addEventListener('click', () => {
        loadList();
        refreshTabCounts();
    });

    tabButtons.forEach(btn => {
        btn.addEventListener('click', () => {
            const next = btn.dataset.tab;
            if (!next || next === currentTab) return;
            currentTab = next;
            tabButtons.forEach(b => {
                const active = b.dataset.tab === currentTab;
                b.classList.toggle('is-active', active);
                b.setAttribute('aria-selected', active ? 'true' : 'false');
            });
            sectionTitle.textContent = currentTab === 'downloaded' ? 'Downloaded' : 'Pending';
            currentPage = 1;
            loadList();
        });
    });

    paginationCtrl = mountPagination(document.getElementById('exports-pagination'), {
        page: 1, pageSize: 50, total: 0, label: 'exports',
        ariaLabel: 'My exports pagination',
        onChange: (newPage) => { currentPage = newPage; loadList(); },
    });

    // ---------- Mark all unread as read once data is on screen ----------
    // Phase 8.5+ — visiting /Exports is the operator's signal that they
    // saw the queue; the nav-bar badge clears. Fire-and-forget; refresh
    // the badge immediately so it doesn't wait for the next 10s poll.
    async function markAllReadOnVisit() {
        try {
            await fetch('/api/exports/mark-all-read', {
                method: 'POST',
                credentials: 'same-origin',
            });
            if (typeof window.refreshExportsBadge === 'function') {
                window.refreshExportsBadge();
            }
        } catch { /* silent — badge stays whatever it is */ }
    }

    // ---------- Init ----------
    (async () => {
        await loadAdminFlag();
        await loadList();
        await refreshTabCounts();
        await markAllReadOnVisit();
        // Keep the tab badges roughly fresh while the page is open —
        // covers the case where another tab/session enqueues new jobs.
        tabCountsTimer = setInterval(refreshTabCounts, TAB_COUNTS_REFRESH_MS);
    })();
})();
