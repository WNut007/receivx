/* ===== Shared ERP source dropdown (Phase 13.8.3) =====
 *
 * Populates a <select> with the currently-enabled ERP sources from
 *   GET /api/admin/config/sections/ErpSync
 * filtering on ErpSync:Sources:<X>:Enabled === "true". When two or more
 * sources are enabled, an "All enabled (X + Y)" option is added at the
 * top with value="" — that empty string is the wire contract that
 * means "no source filter" on POST /api/admin/erp-sync/trigger.
 *
 * A companion <code> element displays the live wording in the modal
 * description ("Pulls planning data from <code>X</code>..."). On every
 * dropdown change the helper rewrites that element's textContent to
 * the selected source name (or "all enabled sources" when value="").
 *
 * Usage:
 *   await ErpSourceDropdown.populate({
 *       selectEl: document.getElementById('sync-source'),
 *       labelEl:  document.getElementById('sync-source-label'),
 *   });
 *
 * Returns the populated source list (array of strings) so callers can
 * react (e.g. disable the Start button when zero sources are enabled).
 * Defensive on network/auth failures: renders a single
 * "Error loading sources" option, returns []; the caller can decide
 * whether to disable the form.
 */
(function () {
  'use strict';

  // The two known sources today. Adding a third one means:
  //   1. Add a new IErpSource implementation server-side
  //   2. Add the section key triplet under ErpSync:Sources:<X>:* in
  //      ConfigController.KnownSections + config-editor-erpsync.js
  //   3. Append the (key, name) tuple here
  // No other client-side changes required — the rest is data-driven.
  const SOURCE_REGISTRY = [
    { configKey: 'ErpSync:Sources:Bpi:Enabled', name: 'BPI_PRS' },
    { configKey: 'ErpSync:Sources:Prb:Enabled', name: 'PRB_PRS' },
  ];

  const ALL_ENABLED_LABEL = 'all enabled sources';

  async function populate(opts) {
    const { selectEl, labelEl } = opts || {};
    if (!selectEl) throw new Error('ErpSourceDropdown.populate: selectEl is required');

    selectEl.innerHTML = '';
    let enabled = [];
    try {
      const resp = await fetch('/api/admin/config/sections/ErpSync', {
        credentials: 'same-origin',
        headers: { 'Accept': 'application/json' },
      });
      if (!resp.ok) {
        renderError(selectEl, 'HTTP ' + resp.status);
        if (labelEl) labelEl.textContent = ALL_ENABLED_LABEL;
        return [];
      }
      const data = await resp.json();
      const values = data && data.values ? data.values : {};
      // Case-insensitive truthy check — appsettings.json + DB rows can emit
      // "true" / "True" depending on source.
      const isTrue = (v) => v != null && String(v).toLowerCase() === 'true';
      enabled = SOURCE_REGISTRY
        .filter(s => isTrue(values[s.configKey]))
        .map(s => s.name);
    } catch (err) {
      console.error('ErpSourceDropdown.populate failed:', err);
      renderError(selectEl, err.message || String(err));
      if (labelEl) labelEl.textContent = ALL_ENABLED_LABEL;
      return [];
    }

    // Build options. "All enabled" is added FIRST only when there are
    // 2+ enabled sources — a 1-source environment doesn't need the
    // composite option (it'd be confusing — same as picking the source).
    if (enabled.length === 0) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = 'No sources enabled — configure /Config first';
      opt.disabled = true;
      opt.selected = true;
      selectEl.appendChild(opt);
    } else {
      if (enabled.length >= 2) {
        const allOpt = document.createElement('option');
        allOpt.value = '';   // empty string = wire contract for "no filter"
        allOpt.textContent = 'All enabled (' + enabled.join(' + ') + ')';
        selectEl.appendChild(allOpt);
      }
      enabled.forEach(name => {
        const opt = document.createElement('option');
        opt.value = name;
        opt.textContent = name;
        selectEl.appendChild(opt);
      });
      // Single-source environment: that source is auto-selected. Multi-source:
      // "All enabled" wins by default (it's first).
      if (enabled.length === 1) selectEl.value = enabled[0];
    }

    // Wire the live-label update + run it once for the initial value.
    if (labelEl) {
      const updateLabel = () => {
        labelEl.textContent = selectEl.value || ALL_ENABLED_LABEL;
      };
      // Replace any prior listener — populate() may be called multiple times
      // (e.g. each time the modal opens) so we avoid stacked handlers by
      // cloning the listener-clearing pattern via dataset flag.
      if (selectEl.dataset.erpSourceWired !== '1') {
        selectEl.addEventListener('change', () => {
          // The label element passed to THIS populate() call is the one we
          // update — even if the caller passes a different labelEl on a
          // subsequent call (won't happen in practice, but cheap to be safe).
          updateLabel();
        });
        selectEl.dataset.erpSourceWired = '1';
      }
      updateLabel();
    }

    return enabled;
  }

  function renderError(selectEl, detail) {
    selectEl.innerHTML = '';
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = 'Error loading sources (' + (detail || 'unknown') + ')';
    opt.disabled = true;
    opt.selected = true;
    selectEl.appendChild(opt);
  }

  window.ErpSourceDropdown = { populate };
})();
