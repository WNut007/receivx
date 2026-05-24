/* ===== Shared pagination component (Phase 8.2) =====
 *
 * Vanilla module. Wires Prev / numeric / Next buttons to a callback
 * `onChange(newPage)` that AJAX-loads the new slice. Page-aware ellipsis:
 * with totalPages > maxButtons (default 7), the rendered set is
 *   1 … (cur-1) cur (cur+1) … N
 * so the operator always sees first + last + neighbors regardless of N.
 *
 * Usage:
 *   import 'pagination.js';        // or <script src="...">
 *   const ctrl = mountPagination(containerEl, {
 *       page: 1, pageSize: 50, total: 0,
 *       onChange: async (newPage) => { ... await fetch(...); ctrl.update({ page: newPage, total: 123 }); }
 *   });
 *   // later:
 *   ctrl.update({ page: 3, total: 200, pageSize: 50 });
 *   ctrl.destroy();
 *
 * Hides itself (sets hidden attr on the .pagination wrapper) when
 * totalPages <= 1 so the host page doesn't need to gate visibility.
 */
(function (global) {
    'use strict';

    const DEFAULT_MAX_BUTTONS = 7; // Prev + 1 + … + (cur-1) (cur) (cur+1) + … + N + Next

    function clampPage(page, totalPages) {
        if (totalPages < 1) return 1;
        return Math.max(1, Math.min(totalPages, page | 0));
    }

    function totalPagesOf(total, pageSize) {
        if (!total || !pageSize) return 0;
        return Math.max(1, Math.ceil(total / pageSize));
    }

    /**
     * Returns the page numbers to render between Prev and Next, with
     * 'ellipsis' tokens inserted where pages were skipped. Designed so
     * first + last + (cur ± 1) are always visible.
     */
    function pageWindow(currentPage, totalPages, maxButtons) {
        if (totalPages <= maxButtons) {
            return Array.from({ length: totalPages }, (_, i) => i + 1);
        }
        const result = new Set([1, totalPages, currentPage]);
        if (currentPage > 1)             result.add(currentPage - 1);
        if (currentPage < totalPages)    result.add(currentPage + 1);
        // Fill toward edges if we still have room
        const ordered = [...result].sort((a, b) => a - b);
        const out = [];
        for (let i = 0; i < ordered.length; i++) {
            if (i > 0 && ordered[i] - ordered[i - 1] > 1) out.push('ellipsis');
            out.push(ordered[i]);
        }
        return out;
    }

    function escHtml(s) {
        return String(s).replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        }[c]));
    }

    /**
     * Builds the inner HTML for the .pagination wrapper. Called by the
     * mount factory (which then attaches event listeners) and by the
     * smoke test (which asserts DOM shape against representative states).
     */
    function buildPaginationHtml(state) {
        const page = clampPage(state.page, state.totalPages);
        const tp = state.totalPages;
        const total = state.total | 0;
        const tokens = pageWindow(page, tp, state.maxButtons || DEFAULT_MAX_BUTTONS);
        const label = state.label || 'records';

        const navHtml = [
            `<li><button type="button" class="pagination-btn prev" data-page="${page - 1}" ${page <= 1 ? 'disabled' : ''} aria-label="Previous page">‹ Prev</button></li>`,
            ...tokens.map(t => t === 'ellipsis'
                ? `<li><span class="pagination-ellipsis" aria-hidden="true">…</span></li>`
                : `<li><button type="button" class="pagination-btn${t === page ? ' active' : ''}" data-page="${t}" aria-label="Page ${t}"${t === page ? ' aria-current="page"' : ''}>${t}</button></li>`),
            `<li><button type="button" class="pagination-btn next" data-page="${page + 1}" ${page >= tp ? 'disabled' : ''} aria-label="Next page">Next ›</button></li>`,
        ].join('');

        return `
            <span class="pagination-info">Page <b>${page}</b> of <b>${tp}</b> · <b>${total.toLocaleString()}</b> ${escHtml(label)}</span>
            <ul class="pagination-nav">${navHtml}</ul>
        `;
    }

    /**
     * Mounts pagination on the given container. Returns a controller
     * with .update(state) + .destroy().
     */
    function mountPagination(container, opts) {
        if (!container) throw new Error('mountPagination: container is required');
        if (typeof opts?.onChange !== 'function') {
            throw new Error('mountPagination: onChange callback is required');
        }

        const state = {
            page: opts.page || 1,
            pageSize: opts.pageSize || 50,
            total: opts.total || 0,
            label: opts.label || 'records',
            maxButtons: opts.maxButtons || DEFAULT_MAX_BUTTONS,
            onChange: opts.onChange,
        };
        state.totalPages = totalPagesOf(state.total, state.pageSize);

        container.classList.add('pagination');
        container.setAttribute('role', 'navigation');
        container.setAttribute('aria-label', opts.ariaLabel || 'Pagination');

        function render() {
            state.totalPages = totalPagesOf(state.total, state.pageSize);
            if (state.totalPages <= 1) {
                container.hidden = true;
                container.innerHTML = '';
                return;
            }
            container.hidden = false;
            container.innerHTML = buildPaginationHtml(state);
        }

        function handleClick(e) {
            const btn = e.target.closest('button.pagination-btn[data-page]');
            if (!btn || btn.disabled || btn.classList.contains('active')) return;
            const newPage = parseInt(btn.dataset.page, 10);
            if (isNaN(newPage)) return;
            const clamped = clampPage(newPage, state.totalPages);
            if (clamped === state.page) return;
            state.page = clamped;
            // Re-render immediately so the operator gets feedback even before
            // the network call resolves. The host's onChange swaps in new data
            // and calls update({total: ...}) which re-renders again.
            render();
            state.onChange(clamped);
        }

        container.addEventListener('click', handleClick);
        render();

        return {
            update(patch) {
                if (patch.page !== undefined)     state.page = patch.page;
                if (patch.pageSize !== undefined) state.pageSize = patch.pageSize;
                if (patch.total !== undefined)    state.total = patch.total;
                if (patch.label !== undefined)    state.label = patch.label;
                render();
            },
            getState() { return { ...state }; },
            destroy() {
                container.removeEventListener('click', handleClick);
                container.innerHTML = '';
                container.classList.remove('pagination');
            },
        };
    }

    // Exports — global for the inline script pattern this codebase uses;
    // also exports as CommonJS for the smoke test that runs in Node.
    global.mountPagination = mountPagination;
    global._paginationInternals = { pageWindow, totalPagesOf, buildPaginationHtml, clampPage };
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { mountPagination, pageWindow, totalPagesOf, buildPaginationHtml, clampPage };
    }
})(typeof window !== 'undefined' ? window : globalThis);
