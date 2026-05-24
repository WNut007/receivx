/* Phase 8.5+ — nav-bar badge for unread completed exports.
 *
 * Polls /api/exports/unread-count every 10s while the page is loaded.
 * Renders the count inside #exports-badge (placed by app-nav.js inside
 * the Exports menu entry). Caps display at "99+". Subtle pulse when
 * the count increases — quiet otherwise.
 *
 * /Exports calls window.refreshExportsBadge() after firing the
 * mark-all-read POST so the badge clears immediately rather than
 * waiting for the next poll cycle.
 *
 * Silent failure on network errors — a stale badge is not worth
 * spamming the console with errors.
 */
(function () {
    'use strict';

    const POLL_INTERVAL_MS = 10_000;
    let pollTimer = null;
    let currentCount = 0;

    async function updateBadge() {
        const badge = document.getElementById('exports-badge');
        if (!badge) return; // nav hasn't rendered yet, or user not logged in
        try {
            const r = await fetch('/api/exports/unread-count', { credentials: 'same-origin' });
            if (!r.ok) return;
            const data = await r.json();
            const newCount = data.count | 0;
            if (newCount === 0) {
                badge.hidden = true;
                badge.textContent = '';
            } else {
                badge.textContent = newCount > 99 ? '99+' : String(newCount);
                badge.hidden = false;
                if (newCount > currentCount) {
                    badge.classList.add('bump');
                    setTimeout(() => badge.classList.remove('bump'), 320);
                }
            }
            currentCount = newCount;
        } catch (e) {
            // Stale badge is acceptable — don't spam console
        }
    }

    function start() {
        if (pollTimer) return;
        updateBadge();
        pollTimer = setInterval(updateBadge, POLL_INTERVAL_MS);
    }

    function stop() {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    }

    // Expose the manual-refresh hook for /Exports page after mark-all-read.
    window.refreshExportsBadge = updateBadge;

    // app-nav.js renders the badge element asynchronously after fetching
    // the user; start polling once it exists. MutationObserver wakes us
    // up the moment the nav is in the DOM.
    if (document.getElementById('exports-badge')) {
        start();
    } else {
        const obs = new MutationObserver(() => {
            if (document.getElementById('exports-badge')) {
                obs.disconnect();
                start();
            }
        });
        obs.observe(document.body, { childList: true, subtree: true });
        // Safety: stop watching after 10s — if the badge never showed up
        // we're probably on an unauthenticated page (login).
        setTimeout(() => obs.disconnect(), 10_000);
    }

    window.addEventListener('beforeunload', stop);
})();
