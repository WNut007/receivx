/* Phase 8.5 — My Exports page. Lists export jobs from
 * /api/exports/jobs, refreshes every 5 s while any row is still
 * queued or running, falls quiet once the dataset settles. Reuses the
 * shared mountPagination() control. */
(() => {
    'use strict';

    const REFRESH_MS = 5000;
    let currentPage = 1;
    let currentTotal = 0;
    let currentRows = [];
    let seeAll = false;
    let isAdmin = false;
    let refreshTimer = null;
    let paginationCtrl = null;

    const tbody = document.getElementById('exports-tbody');
    const refreshBanner = document.getElementById('auto-refresh-banner');
    const seeAllToggle = document.getElementById('see-all');
    const adminColumns = document.querySelectorAll('[data-admin-only]');
    const listCount = document.getElementById('list-count');

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
            tbody.innerHTML = `<tr><td colspan="8" class="empty-row">
                <i class="bi bi-cloud-slash"></i> No export jobs yet.
                Run an Export from /Transactions, /Pos, or /Masters → Audit Log.
            </td></tr>`;
        } else {
            tbody.innerHTML = currentRows.map(r => {
                const status = r.effectiveStatus || r.status;
                const requesterCell = seeAll
                    ? `<td class="requester-cell"><b>${escHtml(r.requesterName || '—')}</b><br>${escHtml(r.requesterEmail || '')}</td>`
                    : '';
                const fileOrError =
                    status === 'failed'
                        ? `<span class="error-text" title="${escHtml(r.errorMessage || '')}">${escHtml(r.errorMessage || 'Unknown error')}</span>`
                        : r.fileName
                            ? `<span class="file-cell">${escHtml(r.fileName)}</span>`
                            : '<span class="file-cell">—</span>';
                let action;
                if (status === 'succeeded' && r.downloadUrl) {
                    action = `<a class="btn btn-primary" href="${escHtml(r.downloadUrl)}" title="Download (link expires in 24h)">
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

        // Auto-refresh banner ON when any row in flight
        const inFlight = currentRows.some(r => r.status === 'queued' || r.status === 'running');
        refreshBanner.hidden = !inFlight;
        scheduleRefresh(inFlight);
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
    });
    document.getElementById('btn-refresh').addEventListener('click', loadList);

    paginationCtrl = mountPagination(document.getElementById('exports-pagination'), {
        page: 1, pageSize: 50, total: 0, label: 'exports',
        ariaLabel: 'My exports pagination',
        onChange: (newPage) => { currentPage = newPage; loadList(); },
    });

    // ---------- Init ----------
    (async () => {
        await loadAdminFlag();
        await loadList();
    })();
})();
