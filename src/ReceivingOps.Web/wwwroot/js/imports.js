/* Phase 12.8 — /Imports uploader.
 * One-shot flow: dropzone → POST upload → preview panel → POST confirm →
 * status panel polls /api/imports/po/{runId} until terminal → "New import"
 * resets to dropzone.
 *
 * No history list, no admin warehouse picker (admins use session WH same
 * as supervisors). Operators never see this JS — server-side gate in
 * ImportsController omits the <script> tag for them.
 *
 * Loaded ONLY when ViewData["CanUpload"] is true, so DOM hooks are
 * guaranteed to exist. We still bail at the top if the dropzone isn't
 * found, as a belt-and-braces safeguard against bundler shenanigans.
 */
(function () {
    'use strict';

    const dropzone        = document.getElementById('imports-dropzone');
    if (!dropzone) return;

    const fileInput       = document.getElementById('imports-file-input');
    const browseBtn       = document.getElementById('imports-browse-btn');
    const previewPanel    = document.getElementById('imports-preview-panel');
    const previewFilename = document.getElementById('imports-preview-filename');
    const previewSummary  = document.getElementById('imports-preview-summary');
    const previewErrors   = document.getElementById('imports-preview-errors');
    const confirmBtn      = document.getElementById('imports-confirm-btn');
    const cancelBtn       = document.getElementById('imports-cancel-btn');
    const statusPanel     = document.getElementById('imports-status-panel');
    const statusFilename  = document.getElementById('imports-status-filename');
    const statusBody      = document.getElementById('imports-status-body');
    const statusActions   = document.getElementById('imports-status-actions');
    const newBtn          = document.getElementById('imports-new-btn');

    // Mirror PoImportController constants — these are duplicated client-side
    // for early UX feedback; the server enforces them authoritatively.
    const MAX_SIZE_BYTES  = 50 * 1024 * 1024;
    const ALLOWED_EXTS    = ['.xls', '.xlsx'];

    let currentRunId = null;
    let currentFile = null;

    // -----------------------------------------------------------------------
    // Dropzone wiring
    // -----------------------------------------------------------------------
    browseBtn.addEventListener('click', () => fileInput.click());

    ['dragenter', 'dragover'].forEach(ev => {
        dropzone.addEventListener(ev, e => {
            e.preventDefault();
            dropzone.classList.add('drag-over');
        });
    });
    ['dragleave', 'drop'].forEach(ev => {
        dropzone.addEventListener(ev, e => {
            e.preventDefault();
            dropzone.classList.remove('drag-over');
        });
    });

    dropzone.addEventListener('drop', e => {
        if (e.dataTransfer && e.dataTransfer.files.length > 0) {
            handleFile(e.dataTransfer.files[0]);
        }
    });

    fileInput.addEventListener('change', () => {
        if (fileInput.files.length > 0) handleFile(fileInput.files[0]);
    });

    cancelBtn.addEventListener('click', resetToDropzone);
    newBtn.addEventListener('click', resetToDropzone);
    confirmBtn.addEventListener('click', handleConfirm);

    // -----------------------------------------------------------------------
    // Upload
    // -----------------------------------------------------------------------
    async function handleFile(file) {
        const ext = '.' + (file.name.split('.').pop() || '').toLowerCase();
        if (!ALLOWED_EXTS.includes(ext)) {
            await confirmAction({
                title: 'Unsupported file',
                message: 'Only .xls and .xlsx workbooks are accepted.',
                icon: 'warning',
                confirmLabel: 'OK',
                cancelLabel: 'Close'
            });
            fileInput.value = '';
            return;
        }
        if (file.size > MAX_SIZE_BYTES) {
            await confirmAction({
                title: 'File too large',
                message: 'The workbook exceeds the 50 MB limit. Split it across multiple files and re-upload.',
                icon: 'warning',
                confirmLabel: 'OK',
                cancelLabel: 'Close'
            });
            fileInput.value = '';
            return;
        }

        currentFile = file;
        showUploading(file.name);

        const fd = new FormData();
        fd.append('file', file);

        try {
            const resp = await fetch('/api/imports/po/upload', {
                method: 'POST',
                body: fd,
                credentials: 'same-origin'
            });
            const data = await resp.json().catch(() => null);
            if (!resp.ok) {
                showUploadError(resp.status, data);
                return;
            }
            currentRunId = data.runId;
            showPreview(file.name, data);
        } catch (e) {
            showUploadError(0, { title: e.message });
        }
    }

    function showUploading(name) {
        dropzone.hidden = true;
        previewPanel.hidden = true;
        statusPanel.hidden = false;
        statusActions.hidden = true;
        statusFilename.textContent = name;
        statusBody.innerHTML =
            '<div class="imports-status-running">' +
                '<i class="bi bi-arrow-clockwise spin"></i>' +
                '<span>Parsing &amp; validating workbook…</span>' +
            '</div>';
    }

    function showUploadError(status, data) {
        statusPanel.hidden = false;
        statusActions.hidden = false;
        const title = (data && data.title) ? data.title : ('HTTP ' + status);
        statusBody.innerHTML =
            '<div class="imports-status-final failed">' +
                '<i class="bi bi-x-circle"></i>' +
                '<span>Upload failed: ' + escapeHtml(title) + '</span>' +
            '</div>';
    }

    // -----------------------------------------------------------------------
    // Preview
    // -----------------------------------------------------------------------
    function showPreview(fileName, data) {
        statusPanel.hidden = true;
        previewPanel.hidden = false;
        previewFilename.textContent = fileName;

        const validated = data.status === 'validated';
        const summaryCells =
            cell('POs',    data.distinctPoCount)    +
            cell('Rows',   data.totalRowsRead)      +
            cell('Errors', data.validationErrorCount);
        previewSummary.innerHTML =
            '<div class="imports-summary' + (validated ? '' : ' failed') + '">' +
                summaryCells +
            '</div>';

        const errs = data.validationErrorsPreview || [];
        if (errs.length === 0) {
            previewErrors.innerHTML = '';
        } else {
            const items = errs.map(e =>
                '<li>' +
                    (e.rowNumber ? '<code>row ' + e.rowNumber + '</code>' : '') +
                    (e.column ? '<code>' + escapeHtml(e.column) + '</code>' : '') +
                    escapeHtml(e.message || '') +
                '</li>'
            ).join('');
            const header = data.validationErrorCount > errs.length
                ? 'First ' + errs.length + ' of ' + data.validationErrorCount + ' issues'
                : errs.length + ' issue' + (errs.length === 1 ? '' : 's');
            previewErrors.innerHTML =
                '<div class="imports-errors">' +
                    '<h4>' + escapeHtml(header) + '</h4>' +
                    '<ul class="imports-errors-list">' + items + '</ul>' +
                '</div>';
        }

        // Operator can confirm only when validated. validation_failed leaves
        // them with the error list + Cancel only (re-upload is the path).
        confirmBtn.hidden = !validated;
    }

    function cell(label, value) {
        return '' +
            '<div class="imports-summary-cell">' +
                '<span class="imports-summary-label">' + escapeHtml(label) + '</span>' +
                '<span class="imports-summary-value">' + (value ?? 0) + '</span>' +
            '</div>';
    }

    // -----------------------------------------------------------------------
    // Confirm + poll
    // -----------------------------------------------------------------------
    async function handleConfirm() {
        if (!currentRunId) return;
        const ok = await confirmAction({
            title: 'Confirm this import?',
            message: 'Once confirmed the rows commit atomically — there is no per-row undo.',
            icon: 'info',
            confirmLabel: 'Confirm import',
            cancelLabel: 'Cancel'
        });
        if (!ok) return;

        confirmBtn.disabled = true;
        try {
            const resp = await fetch('/api/imports/po/' + currentRunId + '/confirm', {
                method: 'POST',
                credentials: 'same-origin'
            });
            if (!resp.ok) {
                const data = await resp.json().catch(() => null);
                const title = (data && (data.error || data.title)) || ('HTTP ' + resp.status);
                statusPanel.hidden = false;
                previewPanel.hidden = true;
                statusActions.hidden = false;
                statusBody.innerHTML =
                    '<div class="imports-status-final failed">' +
                        '<i class="bi bi-x-circle"></i>' +
                        '<span>Confirm failed: ' + escapeHtml(title) + '</span>' +
                    '</div>';
                return;
            }
            previewPanel.hidden = true;
            statusPanel.hidden = false;
            statusActions.hidden = true;
            statusFilename.textContent = (currentFile && currentFile.name) || '';
            pollUntilTerminal(currentRunId);
        } catch (e) {
            statusPanel.hidden = false;
            previewPanel.hidden = true;
            statusActions.hidden = false;
            statusBody.innerHTML =
                '<div class="imports-status-final failed">' +
                    '<i class="bi bi-x-circle"></i>' +
                    '<span>Confirm failed: ' + escapeHtml(e.message) + '</span>' +
                '</div>';
        } finally {
            confirmBtn.disabled = false;
        }
    }

    async function pollUntilTerminal(runId) {
        statusBody.innerHTML =
            '<div class="imports-status-running">' +
                '<i class="bi bi-arrow-clockwise spin"></i>' +
                '<span>Queued — waiting for Hangfire worker…</span>' +
            '</div>';

        const terminal = ['succeeded', 'failed'];
        const maxAttempts = 60; // 60 × 2s = 120s cap
        for (let i = 0; i < maxAttempts; i++) {
            await sleep(2000);
            let log;
            try {
                const resp = await fetch('/api/imports/po/' + runId, { credentials: 'same-origin' });
                if (!resp.ok) {
                    showTerminal({ status: 'failed', errorMessage: 'Polling HTTP ' + resp.status });
                    return;
                }
                log = await resp.json();
            } catch (e) {
                showTerminal({ status: 'failed', errorMessage: e.message });
                return;
            }
            if (terminal.includes(log.status)) { showTerminal(log); return; }
            statusBody.innerHTML =
                '<div class="imports-status-running">' +
                    '<i class="bi bi-arrow-clockwise spin"></i>' +
                    '<span>' + escapeHtml(log.status) + '…</span>' +
                '</div>';
        }
        showTerminal({
            status: 'failed',
            errorMessage: 'Run did not complete within 2 minutes — check the Hangfire dashboard at /hangfire.'
        });
    }

    function showTerminal(log) {
        statusActions.hidden = false;
        if (log.status === 'succeeded') {
            statusBody.innerHTML =
                '<div class="imports-status-final succeeded">' +
                    '<i class="bi bi-check-circle"></i>' +
                    '<span>Imported <strong>' + (log.posInserted ?? 0) + '</strong> POs / ' +
                          '<strong>' + (log.linesInserted ?? 0) + '</strong> lines' +
                          (log.elapsedMs ? ' in ' + log.elapsedMs + 'ms' : '') +
                    '</span>' +
                '</div>';
        } else {
            statusBody.innerHTML =
                '<div class="imports-status-final failed">' +
                    '<i class="bi bi-x-circle"></i>' +
                    '<span>' + escapeHtml(log.errorMessage || 'Import failed') + '</span>' +
                '</div>';
        }
    }

    // -----------------------------------------------------------------------
    // Reset
    // -----------------------------------------------------------------------
    function resetToDropzone() {
        currentRunId = null;
        currentFile = null;
        fileInput.value = '';
        previewPanel.hidden = true;
        statusPanel.hidden = true;
        statusActions.hidden = true;
        previewSummary.innerHTML = '';
        previewErrors.innerHTML = '';
        statusBody.innerHTML = '';
        statusFilename.textContent = '';
        previewFilename.textContent = '';
        confirmBtn.hidden = false;
        confirmBtn.disabled = false;
        dropzone.hidden = false;
    }

    // -----------------------------------------------------------------------
    // Utils
    // -----------------------------------------------------------------------
    function escapeHtml(s) {
        return String(s ?? '').replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        }[c]));
    }
    function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
})();
