/* ============================================================================
 * app-nav.js — Shared navigation component for the Receiving suite
 * ----------------------------------------------------------------------------
 * Drop-in script. Reads user session from localStorage.auth.user.
 * Injects either a horizontal top bar or a vertical sidebar based on
 * localStorage.app.navPosition. Behavior (sticky / auto-hide / static)
 * comes from localStorage.app.navBehavior.
 *
 * Marks the active menu item by current pathname.
 * Theme switcher lives here too — synced via localStorage.pullController.theme.
 *
 * Usage:
 *   <body data-app-page="pull">     (or "receiving" / "config")
 *   ...
 *   <script src="app-nav.js"></script>   (at end of body)
 * ========================================================================== */
(function () {
  'use strict';

  // ---- Read session ----
  // Server is the source of truth (cookie). We cache the /api/auth/me response
  // in localStorage so first paint is FOUC-free; the API check below clears
  // the cache when the cookie is missing/expired.
  const SESSION_CACHE_KEY = 'auth.session';
  function getUser() {
    try {
      const raw = localStorage.getItem(SESSION_CACHE_KEY);
      if (!raw) return null;
      return JSON.parse(raw);
    } catch (e) { return null; }
  }
  function setUser(u) {
    try {
      if (u) localStorage.setItem(SESSION_CACHE_KEY, JSON.stringify(u));
      else   localStorage.removeItem(SESSION_CACHE_KEY);
    } catch (e) {}
  }
  // Map /api/auth/me response onto the legacy mockup shape so the rest of this
  // file (drawers, profile chip, etc.) can stay verbatim.
  function adaptMe(me) {
    if (!me) return null;
    return {
      username:      me.username,
      name:          me.name,
      email:         me.email,
      role:          me.role,         // human label
      roleKey:       me.roleKey,      // whRole at this warehouse
      initials:      me.initials,
      warehouse:     me.warehouseCode,
      warehouseId:   me.warehouseId,
      warehouseName: me.warehouseName,
      signedInAt:    new Date().toISOString(),
    };
  }

  // ---- Read prefs ----
  const PREF = {
    get navPosition() { try { return localStorage.getItem('app.navPosition') || 'horizontal'; } catch (e) { return 'horizontal'; } },
    set navPosition(v) { try { localStorage.setItem('app.navPosition', v); } catch (e) {} },
    get navBehavior() { try { return localStorage.getItem('app.navBehavior') || 'sticky'; } catch (e) { return 'sticky'; } },
    set navBehavior(v) { try { localStorage.setItem('app.navBehavior', v); } catch (e) {} },
    get theme() { try { return localStorage.getItem('pullController.theme') || 'light'; } catch (e) { return 'light'; } },
    set theme(v) { try { localStorage.setItem('pullController.theme', v); } catch (e) {} },
  };

  const LOGIN_URL = '/Account/Login';

  // ---- Auth guard: bounce to login if no user.
  // The [Authorize] attribute on the controller already enforces this server-side
  // for full page loads, but we also keep a client-side check so SPA-style API
  // calls fall back cleanly if the cookie expires mid-session.
  const isLoginPage = window.location.pathname.toLowerCase().includes('/account/login');
  const user = getUser();
  if (!user && !isLoginPage) {
    // Try to fetch /me — first load after sign-in might not have populated cache yet.
    fetch('/api/auth/me', { credentials: 'same-origin' }).then(r => {
      if (r.ok) {
        r.json().then(me => { setUser(adaptMe(me)); window.location.reload(); });
      } else {
        setUser(null);
        window.location.href = LOGIN_URL;
      }
    }).catch(() => { window.location.href = LOGIN_URL; });
    return;
  }

  // ---- Menu definition (MVC routes — no more mockup .html files) ----
  // `roles` field gates visibility client-side. Omit `roles` for entries that
  // should appear for every authenticated user. The server is still the source
  // of truth (controllers carry their own [Authorize] policies); this is just
  // UX — operators shouldn't see entries they cannot use.
  const MENU = [
    { id: 'pull',         label: 'Dashboard',       icon: 'bi-grid-1x2',             href: '/Dashboard' },
    { id: 'receiving',    label: 'Receiving',       icon: 'bi-box-arrow-in-down',    href: '/Receiving' },
    { id: 'transactions', label: 'Transactions',    icon: 'bi-list-columns-reverse', href: '/Transactions' },
    { id: 'reports',      label: 'Reports',         icon: 'bi-bar-chart',            href: '#',  disabled: true },
    { id: 'masters',      label: 'Master Data',     icon: 'bi-database-gear',        href: '/Masters' },
    // §5c — Purchase Orders admin. CanManagePulls policy on the server → admin + supervisor only.
    { id: 'pos',          label: 'Purchase Orders', icon: 'bi-receipt',              href: '/Pos',     roles: ['admin', 'supervisor'] },
    { id: 'config',       label: 'Settings',        icon: 'bi-sliders',              href: '/Config' },
  ];

  // ---- Detect active page ----
  // Active highlight stays on for nested routes like /Pos/{id} because we use
  // String.startsWith / .includes — pathname matching, not exact-equals.
  const activePage = document.body.getAttribute('data-app-page') || (() => {
    const p = location.pathname.toLowerCase();
    if (p.includes('/dashboard') || p.includes('pull-controller')) return 'pull';
    if (p.includes('/receiving')) return 'receiving';
    if (p.includes('/transactions')) return 'transactions';
    if (p.includes('/masters')) return 'masters';
    if (p.startsWith('/pos'))    return 'pos';
    if (p.includes('/config'))   return 'config';
    return '';
  })();

  // ---- Inject styles ----
  const css = `
    /* ---- Shared theme tokens already exist in each page; nav just consumes them ---- */
    .app-nav {
      background: var(--surface);
      border-color: var(--border);
      box-shadow: var(--shadow-sm);
      z-index: 50;
      transition: transform 0.25s ease, opacity 0.25s ease, width 0.25s ease;
    }
    .app-nav.position-horizontal {
      position: sticky; top: 0;
      display: flex;
      align-items: center;
      padding: 10px 24px;
      gap: 14px;
      border-bottom: 1px solid var(--border);
    }
    .app-nav.position-horizontal.behavior-static { position: relative; }
    .app-nav.position-horizontal.behavior-hidden { transform: translateY(-100%); }

    .app-nav.position-vertical {
      position: fixed;
      top: 0; left: 0; bottom: 0;
      width: 240px;
      display: flex;
      flex-direction: column;
      padding: 0 12px 14px;
      gap: 4px;
      border-right: 1px solid var(--border);
      box-shadow: var(--shadow-md);
    }
    /* Vertical "collapsed" — narrow icon rail (SmartAdmin pattern) */
    .app-nav.position-vertical.collapsed {
      width: 64px;
      padding: 0 8px 14px;
    }
    .app-nav.position-vertical.collapsed .app-nav-brand .name,
    .app-nav.position-vertical.collapsed .app-nav-item .label,
    .app-nav.position-vertical.collapsed .app-nav-item.disabled::after,
    .app-nav.position-vertical.collapsed .app-nav-trail {
      display: none;
    }
    .app-nav.position-vertical.collapsed .app-nav-item {
      justify-content: center;
      padding: 10px 0;
    }

    /* Vertical: full-hide via behavior-hidden — slides off-screen, floating hamburger reveals it */
    .app-nav.position-vertical.behavior-hidden { transform: translateX(-100%); }

    /* When sidebar is on, push the page over */
    body.has-vertical-nav .app { padding-left: 240px; transition: padding-left 0.25s ease; }
    body.has-vertical-nav.nav-collapsed .app { padding-left: 64px; }
    body.has-vertical-nav.nav-hidden .app { padding-left: 0; }
    body.has-vertical-nav .app .topbar { padding-left: 28px; }

    /* ============ UTILITY BAR (vertical mode only) ============
       Slim horizontal strip above page content.
       Layout: [ hamburger ☰ ]              [ theme · profile ]
       The hamburger lives here (not in sidebar) so it stays accessible
       even when the sidebar is collapsed to icon-rail. */
    .app-nav-utility {
      position: fixed;
      top: 0;
      right: 0;
      left: 240px;
      height: 56px;
      display: none;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      padding: 0 20px;
      background: color-mix(in srgb, var(--surface) 80%, transparent);
      backdrop-filter: blur(20px);
      border-bottom: 1px solid var(--border);
      z-index: 45;
      transition: left 0.25s ease;
    }
    .app-nav-utility-left {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .app-nav-utility-right {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    body.has-vertical-nav .app-nav-utility { display: flex; }
    body.has-vertical-nav.nav-collapsed .app-nav-utility { left: 64px; }
    body.has-vertical-nav.nav-hidden .app-nav-utility { left: 0; }
    body.has-vertical-nav .app { padding-top: 56px; }
    body.has-vertical-nav .app .topbar { top: 56px; }

    /* Brand */
    .app-nav-brand {
      display: flex;
      align-items: center;
      gap: 10px;
      text-decoration: none;
      color: var(--text);
      padding: 4px 6px;
      border-radius: 8px;
    }
    .app-nav-brand:hover { color: var(--text); }
    .app-nav-brand .logo {
      width: 32px;
      height: 32px;
      border-radius: 8px;
      background: linear-gradient(135deg, var(--accent), var(--accent-2, #0a8a92));
      display: grid;
      place-items: center;
      color: var(--accent-fg, #fff);
      box-shadow: var(--shadow-sm);
    }
    .app-nav-brand .logo i { font-size: 16px; }
    .app-nav-brand .name {
      font-size: 16px;
      font-weight: 500;
      letter-spacing: -0.01em;
      line-height: 1;
    }
    .app-nav-brand .ver {
      display: block;
      font-family: 'Roboto Mono', monospace;
      font-size: 9px;
      font-weight: 600;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 0.18em;
      margin-top: 2px;
    }
    .app-nav.position-vertical .app-nav-brand {
      /* Match utility bar height (56px) so the brand row aligns with the
         hamburger/profile row across the dividing line. */
      height: 56px;
      padding: 0 8px;
      margin-bottom: 8px;
      gap: 12px;
      border-bottom: 1px solid var(--border);
      flex-shrink: 0;
    }
    .app-nav.position-vertical .app-nav-brand .logo {
      width: 36px;
      height: 36px;
      border-radius: 9px;
    }
    .app-nav.position-vertical .app-nav-brand .logo i { font-size: 18px; }
    .app-nav.position-vertical .app-nav-brand .name { font-size: 15px; }
    .app-nav.position-vertical .app-nav-brand .ver { font-size: 9px; margin-top: 3px; }

    /* When sidebar is collapsed (icon rail), brand becomes just the logo, centered */
    .app-nav.position-vertical.collapsed .app-nav-brand {
      padding: 0;
      justify-content: center;
    }

    /* Menu */
    .app-nav-menu {
      display: flex;
      gap: 2px;
      flex: 1;
    }
    .app-nav.position-vertical .app-nav-menu {
      flex-direction: column;
      flex: 1;
      gap: 3px;
    }
    .app-nav.position-vertical .app-nav-item {
      width: 100%;
      padding: 10px 14px;
      font-size: 14px;
      gap: 12px;
    }
    .app-nav.position-vertical .app-nav-item i { font-size: 17px; }
    .app-nav.position-vertical .app-nav-item.disabled::after { margin-left: auto; }
    .app-nav-item {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 14px;
      border-radius: 8px;
      text-decoration: none;
      color: var(--text-dim);
      font-size: 14px;
      font-weight: 500;
      transition: all 0.12s ease;
      white-space: nowrap;
    }
    .app-nav-item i { font-size: 16px; opacity: 0.85; }
    .app-nav-item:hover { background: var(--surface-2); color: var(--text); }
    .app-nav-item.active {
      background: var(--accent-bg);
      color: var(--accent);
    }
    .app-nav-item.active i { opacity: 1; }
    .app-nav-item.disabled {
      opacity: 0.4;
      pointer-events: none;
      cursor: not-allowed;
    }
    .app-nav-item.disabled::after {
      content: 'Soon';
      font-family: 'Roboto Mono', monospace;
      font-size: 9px;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      padding: 2px 6px;
      border: 1px solid var(--border);
      border-radius: 4px;
      margin-left: 4px;
      color: var(--text-muted);
    }

    /* Trailing controls */
    .app-nav-trail {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .app-nav.position-vertical .app-nav-trail {
      /* Trail moves to utility bar in vertical mode — hide it from the sidebar */
      display: none;
    }

    /* Theme switch */
    .app-nav-theme {
      display: inline-flex;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 100px;
      padding: 3px;
      box-shadow: var(--shadow-sm);
    }
    .app-nav-theme-swatch {
      width: 24px; height: 24px;
      border-radius: 50%;
      border: none;
      cursor: pointer;
      position: relative;
      transition: transform 0.15s ease;
    }
    .app-nav-theme-swatch:hover { transform: scale(1.08); }
    .app-nav-theme-swatch.active::after {
      content: '';
      position: absolute; inset: -3px;
      border: 2px solid var(--accent);
      border-radius: 50%;
    }
    .app-nav-theme-swatch.light    { background: linear-gradient(135deg, #f6f5f1 50%, #ffffff 50%); border: 1px solid #d4d0c6; }
    .app-nav-theme-swatch.midnight { background: linear-gradient(135deg, #0e1116 50%, #5fd49a 50%); }
    .app-nav-theme-swatch.slate    { background: linear-gradient(135deg, #eef1f4 50%, #2e4d6b 50%); }

    /* Nav toggle (hide/show) — old style kept for backward-compat */
    .app-nav-toggle {
      background: var(--surface-2);
      border: 1px solid var(--border);
      color: var(--text-dim);
      width: 34px; height: 34px;
      border-radius: 8px;
      display: grid; place-items: center;
      cursor: pointer;
      transition: all 0.15s ease;
    }
    .app-nav-toggle:hover { background: var(--surface-3); color: var(--text); }

    /* Default hamburger style (horizontal mode) — simple ghost icon button */
    .app-nav-hamburger {
      background: transparent;
      border: none;
      color: var(--text-dim);
      width: 38px;
      height: 38px;
      border-radius: 8px;
      display: grid;
      place-items: center;
      cursor: pointer;
      transition: all 0.18s ease;
      flex-shrink: 0;
    }
    .app-nav-hamburger i {
      font-size: 20px;
      line-height: 1;
      transition: transform 0.25s ease;
    }
    .app-nav-hamburger:hover {
      background: var(--surface-2);
      color: var(--text);
    }
    .app-nav-hamburger:active { transform: scale(0.96); }

    /* SmartAdmin-style collapse toggle — exact match.
       Rounded-rect button (~36×30) with TWO TONES:
         - Left ~10px strip: slightly darker (gives the "grip" feel)
         - Right area:        lighter, contains the chevron centered
       Divider line between the two tones. */
    body.has-vertical-nav .app-nav-hamburger {
      position: relative;
      background: var(--surface);
      border: 1px solid var(--border);
      width: 38px;
      height: 30px;
      border-radius: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 0 0 0 11px;  /* left strip width baked in as padding */
      box-shadow: var(--shadow-sm);
      overflow: hidden;
    }
    /* Left strip — slightly darker, gives the "two-tone" SmartAdmin look */
    body.has-vertical-nav .app-nav-hamburger::before {
      content: '';
      position: absolute;
      left: 0;
      top: 0;
      bottom: 0;
      width: 11px;
      background: var(--surface-2);
      border-right: 1px solid var(--border);
    }
    body.has-vertical-nav .app-nav-hamburger i {
      font-size: 14px;
    }
    /* SmartAdmin chevron SVG — naturally points LEFT (<). Sized to ~10×10 in the pill.
       Fill matches the icon color so theme changes propagate automatically. */
    .app-nav-chevron {
      width: 9px;
      height: 14px;
      flex-shrink: 0;
      transition: transform 0.25s ease;
      pointer-events: none;
    }
    .app-nav-chevron polygon {
      fill: var(--text-dim);
      transition: fill 0.15s ease;
    }
    body.has-vertical-nav .app-nav-hamburger:hover .app-nav-chevron polygon {
      fill: var(--text);
    }
    body.has-vertical-nav .app-nav-hamburger:hover {
      background: var(--surface-3);
      border-color: var(--border-bright);
    }
    /* Default polygon points LEFT (<).
       When sidebar is COLLAPSED, rotate 180° so it points RIGHT (>) meaning "click to expand". */
    body.has-vertical-nav.nav-collapsed .app-nav-chevron {
      transform: rotate(180deg);
    }

    /* Profile */
    .app-nav-profile {
      position: relative;
    }
    .app-nav-profile-trigger {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 4px 12px 4px 4px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 100px;
      cursor: pointer;
      transition: all 0.15s ease;
      box-shadow: var(--shadow-sm);
    }
    .app-nav-profile-trigger:hover { background: var(--surface-2); border-color: var(--border-bright); }
    .app-nav-profile-trigger .avatar {
      width: 28px; height: 28px;
      border-radius: 50%;
      background: linear-gradient(135deg, var(--accent), var(--accent-2, #0a8a92));
      color: var(--accent-fg, #fff);
      display: grid; place-items: center;
      font-weight: 700;
      font-size: 11px;
      font-family: 'Roboto Mono', monospace;
    }
    .app-nav-profile-trigger .who { display: flex; flex-direction: column; gap: 1px; line-height: 1.1; }
    .app-nav-profile-trigger .who-name { font-size: 13px; color: var(--text); font-weight: 500; }
    .app-nav-profile-trigger .who-role {
      font-family: 'Roboto Mono', monospace;
      font-size: 10px;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .app-nav-profile-trigger .chev {
      color: var(--text-muted);
      font-size: 13px;
      margin-left: 4px;
      transition: transform 0.2s ease, color 0.15s ease;
    }
    .app-nav-profile-trigger:hover .chev { color: var(--text-dim); }
    .app-nav-profile-trigger[aria-expanded="true"] {
      background: var(--surface-2);
      border-color: var(--border-bright);
    }
    .app-nav-profile-trigger[aria-expanded="true"] .chev {
      transform: rotate(180deg);
      color: var(--accent);
    }

    .app-nav-profile-menu {
      position: absolute;
      top: calc(100% + 8px);
      right: 0;
      background: var(--surface);
      border: 1px solid var(--border-bright);
      border-radius: 12px;
      min-width: 260px;
      padding: 6px;
      box-shadow: var(--shadow-lg);
      display: none;
      z-index: 60;
    }
    .app-nav-profile-menu.open { display: block; }
    .app-nav-profile-card {
      padding: 14px 14px 12px;
      border-bottom: 1px solid var(--border);
      margin-bottom: 6px;
    }
    .app-nav-profile-card .name-row {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 8px;
    }
    .app-nav-profile-card .big-avatar {
      width: 38px; height: 38px;
      border-radius: 50%;
      background: linear-gradient(135deg, var(--accent), var(--accent-2, #0a8a92));
      color: var(--accent-fg, #fff);
      display: grid; place-items: center;
      font-weight: 700;
      font-size: 14px;
      font-family: 'Roboto Mono', monospace;
    }
    .app-nav-profile-card .name-big {
      font-size: 14px;
      font-weight: 500;
      color: var(--text);
      line-height: 1.2;
    }
    .app-nav-profile-card .role-big {
      font-family: 'Roboto Mono', monospace;
      font-size: 10px;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.1em;
      margin-top: 2px;
    }
    .app-nav-profile-card .meta-line {
      font-family: 'Roboto Mono', monospace;
      font-size: 11px;
      color: var(--text-dim);
      padding: 3px 0;
      display: flex;
      justify-content: space-between;
    }
    .app-nav-profile-card .meta-line span:first-child {
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.1em;
      font-size: 10px;
    }
    .app-nav-profile-menu-item {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 9px 12px;
      border-radius: 7px;
      text-decoration: none;
      color: var(--text);
      font-size: 13px;
      cursor: pointer;
      border: none;
      background: transparent;
      width: 100%;
      text-align: left;
    }
    .app-nav-profile-menu-item:hover { background: var(--surface-2); color: var(--text); }
    .app-nav-profile-menu-item i { color: var(--text-muted); font-size: 14px; }
    .app-nav-profile-menu-item.danger { color: var(--error, #c0392b); }
    .app-nav-profile-menu-item.danger i { color: var(--error, #c0392b); }
    .app-nav-profile-divider {
      height: 1px;
      background: var(--border);
      margin: 4px 0;
    }

    /* Theme toggle row inside profile menu — collapsible inline submenu */
    .app-nav-theme-toggle {
      display: flex;
      align-items: center;
      gap: 10px;
      width: 100%;
      padding: 9px 12px;
      border: none;
      background: transparent;
      color: var(--text);
      font-size: 13px;
      border-radius: 7px;
      cursor: pointer;
      text-align: left;
    }
    .app-nav-theme-toggle:hover { background: var(--surface-2); }
    .app-nav-theme-toggle > i:first-child { color: var(--text-muted); font-size: 14px; }
    .app-nav-theme-toggle .theme-current {
      margin-left: auto;
      font-family: 'Roboto Mono', monospace;
      font-size: 11px;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .app-nav-theme-toggle .submenu-chev {
      color: var(--text-muted);
      font-size: 12px;
      transition: transform 0.2s ease;
    }
    .app-nav-theme-toggle[aria-expanded="true"] .submenu-chev {
      transform: rotate(90deg);
      color: var(--accent);
    }

    .app-nav-theme-submenu {
      display: none;
      flex-direction: column;
      gap: 2px;
      padding: 4px 4px 6px 4px;
      margin: 2px 0 4px;
      background: var(--surface-2);
      border-radius: 7px;
    }
    .app-nav-theme-submenu.open { display: flex; }
    .app-nav-theme-option {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 7px 12px;
      border: none;
      background: transparent;
      color: var(--text);
      font-size: 13px;
      border-radius: 6px;
      cursor: pointer;
      text-align: left;
      width: 100%;
    }
    .app-nav-theme-option:hover { background: var(--surface); }
    .app-nav-theme-option .dot {
      width: 16px; height: 16px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .app-nav-theme-option .dot.light    { background: linear-gradient(135deg, #f6f5f1 50%, #ffffff 50%); border: 1px solid #d4d0c6; }
    .app-nav-theme-option .dot.midnight { background: linear-gradient(135deg, #0e1116 50%, #5fd49a 50%); }
    .app-nav-theme-option .dot.slate    { background: linear-gradient(135deg, #eef1f4 50%, #2e4d6b 50%); }
    .app-nav-theme-option .label { flex: 1; }
    .app-nav-theme-option .check {
      color: var(--accent);
      font-size: 14px;
      display: none;
    }
    .app-nav-theme-option.active { background: var(--accent-bg); color: var(--accent); }
    .app-nav-theme-option.active .check { display: inline; }

    /* Floating hamburger — appears top-left when nav is hidden,
       lets user bring the nav back. Standard pattern across modern apps. */
    .app-nav-floating-hamburger {
      position: fixed;
      top: 14px;
      left: 14px;
      width: 40px;
      height: 40px;
      border-radius: 10px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text);
      display: none;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      box-shadow: var(--shadow-md);
      z-index: 49;
      transition: all 0.15s ease;
    }
    .app-nav-floating-hamburger i { font-size: 20px; }
    .app-nav-floating-hamburger:hover {
      background: var(--surface-2);
      border-color: var(--border-bright);
      transform: scale(1.05);
    }
    .nav-hidden .app-nav-floating-hamburger { display: flex; }

    /* Reveal-on-hover bar when nav is hidden */
    .app-nav-reveal-bar {
      position: fixed;
      top: 0; left: 0; right: 0;
      height: 6px;
      background: linear-gradient(180deg, color-mix(in srgb, var(--accent) 35%, transparent), transparent);
      z-index: 48;
      display: none;
    }
    .nav-hidden .app-nav-reveal-bar { display: block; }
    .nav-hidden.position-vertical .app-nav-reveal-bar {
      top: 0; left: 0; bottom: 0; right: auto;
      width: 6px;
      height: auto;
      background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 35%, transparent), transparent);
    }

    @media (max-width: 700px) {
      .app-nav.position-horizontal { padding: 10px 14px; gap: 8px; }
      .app-nav-item .label { display: none; }
      .app-nav-profile-trigger .who { display: none; }
    }

    /* Hide redundant in-page theme switchers and user-chips — the app-nav owns these now.
       Pages can still keep their topbars for context (live time, pull/wh chip). */
    body[data-app-page] .topbar > .topbar-right > .theme-switch { display: none; }
    body[data-app-page] .topbar > .topbar-right > .user-chip { display: none; }
  `;

  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  // ---- Render nav ----
  function render() {
    // Robust cleanup — remove ALL stale elements (not just the first)
    document.querySelectorAll('.app-nav').forEach(el => el.remove());
    document.querySelectorAll('.app-nav-reveal-bar').forEach(el => el.remove());
    document.querySelectorAll('.app-nav-utility').forEach(el => el.remove());
    document.querySelectorAll('.app-nav-floating-hamburger').forEach(el => el.remove());

    const nav = document.createElement('nav');
    nav.className = 'app-nav position-' + PREF.navPosition + ' behavior-' + PREF.navBehavior;
    // Restore collapsed state for vertical
    if (PREF.navPosition === 'vertical' && document.body.classList.contains('nav-collapsed')) {
      nav.classList.add('collapsed');
    }

    const u = getUser() || { name: 'Guest', role: 'Unknown', initials: 'G?', warehouseName: '—' };
    const initials = u.initials || (u.name || 'U').slice(0,2).toUpperCase();

    // Trail markup is shared between horizontal nav and vertical utility bar
    const trailHTML = `
      <div class="app-nav-trail">
        <div class="app-nav-theme" role="group" aria-label="Theme">
          <button class="app-nav-theme-swatch light"    data-theme="light"    title="Light"></button>
          <button class="app-nav-theme-swatch midnight" data-theme="midnight" title="Midnight"></button>
          <button class="app-nav-theme-swatch slate"    data-theme="slate"    title="Slate"></button>
        </div>

        <div class="app-nav-profile">
          <button class="app-nav-profile-trigger" id="app-nav-profile-btn">
            <span class="avatar">${initials}</span>
            <span class="who">
              <span class="who-name">${u.name || 'Guest'}</span>
              <span class="who-role">${u.warehouse || 'No WH'}</span>
            </span>
            <i class="bi bi-chevron-down chev"></i>
          </button>

          <div class="app-nav-profile-menu" id="app-nav-profile-menu">
            <div class="app-nav-profile-card">
              <div class="name-row">
                <span class="big-avatar">${initials}</span>
                <div>
                  <div class="name-big">${u.name || 'Guest'}</div>
                  <div class="role-big">${u.role || 'User'}</div>
                </div>
              </div>
              <div class="meta-line"><span>Warehouse</span><span>${u.warehouseName || u.warehouse || '—'}</span></div>
              <div class="meta-line"><span>Username</span><span>${u.username || '—'}</span></div>
              <div class="meta-line"><span>Session</span><span>${u.signedInAt ? new Date(u.signedInAt).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : '—'}</span></div>
            </div>
            <a class="app-nav-profile-menu-item" href="config.html"><i class="bi bi-person-gear"></i> Profile &amp; account</a>
            <a class="app-nav-profile-menu-item" href="config.html"><i class="bi bi-sliders"></i> Settings</a>

            <button class="app-nav-profile-menu-item app-nav-theme-toggle" id="app-nav-theme-toggle" aria-expanded="false">
              <i class="bi bi-palette"></i>
              <span>Theme</span>
              <span class="theme-current" id="app-nav-theme-current"></span>
              <i class="bi bi-chevron-right submenu-chev"></i>
            </button>
            <div class="app-nav-theme-submenu" id="app-nav-theme-submenu">
              <button class="app-nav-theme-option" data-theme="light">
                <span class="dot light"></span>
                <span class="label">Light Paper</span>
                <i class="bi bi-check2 check"></i>
              </button>
              <button class="app-nav-theme-option" data-theme="midnight">
                <span class="dot midnight"></span>
                <span class="label">Midnight</span>
                <i class="bi bi-check2 check"></i>
              </button>
              <button class="app-nav-theme-option" data-theme="slate">
                <span class="dot slate"></span>
                <span class="label">Slate</span>
                <i class="bi bi-check2 check"></i>
              </button>
            </div>

            <a class="app-nav-profile-menu-item" href="#" id="app-nav-help"><i class="bi bi-question-circle"></i> Help &amp; support</a>
            <div class="app-nav-profile-divider"></div>
            <button class="app-nav-profile-menu-item danger" id="app-nav-signout"><i class="bi bi-box-arrow-right"></i> Logout</button>
          </div>
        </div>
      </div>
    `;

    // Hamburger button markup — icon differs by mode:
    //   vertical:   pill with SmartAdmin chevron SVG (collapse sidebar)
    //   horizontal: simple hamburger lines (hide nav)
    // SmartAdmin's exact SVG: viewBox 0 0 5 8, polygon points 4.5,1 3.8,0.2 0,4 3.8,7.8 4.5,7 1.5,4
    // The polygon naturally points LEFT (<) — perfect default for "expanded sidebar, click to collapse"
    const hamburgerIconHTML = PREF.navPosition === 'vertical'
      ? `<svg class="app-nav-chevron" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 5 8" aria-hidden="true">
           <polygon points="4.5,1 3.8,0.2 0,4 3.8,7.8 4.5,7 1.5,4"></polygon>
         </svg>`
      : `<i class="bi bi-list"></i>`;
    const hamburgerTitle = PREF.navPosition === 'vertical' ? 'Toggle Navigation Size' : 'Hide navigation';
    const hamburgerHTML = `
      <button class="app-nav-hamburger" id="app-nav-hide-toggle" title="${hamburgerTitle}" aria-label="${hamburgerTitle}">
        ${hamburgerIconHTML}
      </button>
    `;

    const brandHTML = `
      <a class="app-nav-brand" href="/Dashboard" title="Home">
        <span class="logo"><i class="bi bi-box-seam"></i></span>
        <span>
          <span class="name">Receiving<span class="ver">OPS v3.2</span></span>
        </span>
      </a>
    `;

    // Role-based visibility — `roles` field on a MENU entry restricts it to
    // sessions whose whRole is in the list. Entries without `roles` are
    // visible to everyone. The server still enforces with [Authorize] policies;
    // this just hides what the user can't reach.
    const userRole = (u.roleKey || '').toLowerCase();
    const visibleMenu = MENU.filter(m => !m.roles || m.roles.includes(userRole));

    const menuHTML = `
      <div class="app-nav-menu">
        ${visibleMenu.map(m => `
          <a class="app-nav-item ${m.id === activePage ? 'active' : ''} ${m.disabled ? 'disabled' : ''}"
             href="${m.href}" data-id="${m.id}" title="${m.label}">
            <i class="bi ${m.icon}"></i>
            <span class="label">${m.label}</span>
          </a>
        `).join('')}
      </div>
    `;

    if (PREF.navPosition === 'horizontal') {
      // Horizontal: everything in one bar
      nav.innerHTML = hamburgerHTML + brandHTML + menuHTML + trailHTML;
    } else {
      // Vertical: sidebar holds only brand + menu (no hamburger, no trail)
      nav.innerHTML = brandHTML + menuHTML;
    }

    document.body.insertBefore(nav, document.body.firstChild);

    // Build the utility bar (vertical mode only)
    // Layout: [hamburger]  ...  [theme · profile]
    if (PREF.navPosition === 'vertical') {
      const util = document.createElement('div');
      util.className = 'app-nav-utility';
      util.innerHTML = `
        <div class="app-nav-utility-left">${hamburgerHTML}</div>
        <div class="app-nav-utility-right">${trailHTML}</div>
      `;
      document.body.appendChild(util);
    }

    // Reveal bar (visible only when nav is hidden) — soft accent at top
    let rev = document.querySelector('.app-nav-reveal-bar');
    if (!rev) {
      rev = document.createElement('div');
      rev.className = 'app-nav-reveal-bar';
      document.body.appendChild(rev);
    }

    // Floating hamburger — shows when nav is hidden, so user can bring it back
    let floatBtn = document.querySelector('.app-nav-floating-hamburger');
    if (!floatBtn) {
      floatBtn = document.createElement('button');
      floatBtn.className = 'app-nav-floating-hamburger';
      floatBtn.title = 'Show navigation';
      floatBtn.setAttribute('aria-label', 'Show navigation');
      floatBtn.innerHTML = '<i class="bi bi-list"></i>';
      document.body.appendChild(floatBtn);
    }

    // Apply body classes for layout
    document.body.classList.toggle('has-vertical-nav', PREF.navPosition === 'vertical');

    // ---- Theme apply (single source of truth) ----
    const THEME_LABELS = { light: 'Light', midnight: 'Midnight', slate: 'Slate' };
    function applyThemeChoice(name) {
      PREF.theme = name;
      document.documentElement.setAttribute('data-theme', name);
      // Update swatch row
      document.querySelectorAll('.app-nav-theme-swatch').forEach(s =>
        s.classList.toggle('active', s.dataset.theme === name));
      // Update profile-menu Theme submenu options
      document.querySelectorAll('.app-nav-theme-option').forEach(s =>
        s.classList.toggle('active', s.dataset.theme === name));
      // Update current label in the submenu trigger
      const lbl = document.getElementById('app-nav-theme-current');
      if (lbl) lbl.textContent = THEME_LABELS[name] || name;
      // Sync any in-page theme swatches (the old per-page ones)
      document.querySelectorAll('.theme-swatch').forEach(s => {
        if (s.dataset.theme) s.classList.toggle('active', s.dataset.theme === name);
      });
    }

    // Theme swatch row (top utility / horizontal trail)
    document.querySelectorAll('.app-nav-theme-swatch').forEach(b => {
      b.addEventListener('click', () => applyThemeChoice(b.dataset.theme));
    });

    // Theme submenu inside profile dropdown
    const themeToggle = document.getElementById('app-nav-theme-toggle');
    const themeSubmenu = document.getElementById('app-nav-theme-submenu');
    if (themeToggle && themeSubmenu) {
      themeToggle.addEventListener('click', (e) => {
        e.stopPropagation();
        const open = !themeSubmenu.classList.contains('open');
        themeSubmenu.classList.toggle('open', open);
        themeToggle.setAttribute('aria-expanded', String(open));
      });
    }
    document.querySelectorAll('.app-nav-theme-option').forEach(opt => {
      opt.addEventListener('click', (e) => {
        e.stopPropagation();
        applyThemeChoice(opt.dataset.theme);
      });
    });

    // Initial application — sets swatches, options, and label
    applyThemeChoice(PREF.theme);

    // Hamburger toggle — behavior differs by position:
    //   vertical:   toggle collapsed (icon rail) ↔ expanded
    //   horizontal: toggle fully hidden ↔ visible (floating hamburger reveals)
    document.getElementById('app-nav-hide-toggle').addEventListener('click', () => {
      if (PREF.navPosition === 'vertical') {
        const willCollapse = !document.body.classList.contains('nav-collapsed');
        document.body.classList.toggle('nav-collapsed', willCollapse);
        nav.classList.toggle('collapsed', willCollapse);
        try { localStorage.setItem('app.navCollapsed', willCollapse ? '1' : '0'); } catch (e) {}
      } else {
        const willHide = !document.body.classList.contains('nav-hidden');
        document.body.classList.toggle('nav-hidden', willHide);
        nav.classList.toggle('behavior-hidden', willHide);
      }
    });

    // Wire the floating hamburger to bring the nav back (horizontal mode)
    const floatHamburger = document.querySelector('.app-nav-floating-hamburger');
    if (floatHamburger) {
      floatHamburger.onclick = () => {
        document.body.classList.remove('nav-hidden');
        nav.classList.remove('behavior-hidden');
      };
    }

    // Profile menu
    const profileBtn = document.getElementById('app-nav-profile-btn');
    const profileMenu = document.getElementById('app-nav-profile-menu');
    profileBtn.setAttribute('aria-expanded', 'false');
    profileBtn.setAttribute('aria-haspopup', 'menu');
    profileBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const willOpen = !profileMenu.classList.contains('open');
      profileMenu.classList.toggle('open', willOpen);
      profileBtn.setAttribute('aria-expanded', String(willOpen));
      // Collapse the theme submenu whenever the profile menu opens/closes,
      // so it starts in a clean state every time.
      if (themeSubmenu) {
        themeSubmenu.classList.remove('open');
        if (themeToggle) themeToggle.setAttribute('aria-expanded', 'false');
      }
    });
    document.addEventListener('click', (e) => {
      if (!profileMenu.contains(e.target) && !profileBtn.contains(e.target)) {
        profileMenu.classList.remove('open');
        profileBtn.setAttribute('aria-expanded', 'false');
        if (themeSubmenu) {
          themeSubmenu.classList.remove('open');
          if (themeToggle) themeToggle.setAttribute('aria-expanded', 'false');
        }
      }
    });
    // ESC closes
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && profileMenu.classList.contains('open')) {
        profileMenu.classList.remove('open');
        profileBtn.setAttribute('aria-expanded', 'false');
        if (themeSubmenu) {
          themeSubmenu.classList.remove('open');
          if (themeToggle) themeToggle.setAttribute('aria-expanded', 'false');
        }
      }
    });

    // Sign out
    document.getElementById('app-nav-signout').addEventListener('click', async () => {
      try {
        await fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin' });
      } catch (e) { /* cookie may still be expired-stale; proceed to clear local state */ }
      setUser(null);
      window.location.href = LOGIN_URL;
    });

    // Help (placeholder)
    const help = document.getElementById('app-nav-help');
    if (help) help.addEventListener('click', (e) => { e.preventDefault(); alert('Help center coming soon'); });
  }

  function setBehavior(b) {
    PREF.navBehavior = b;
    render();
  }

  // ---- Public API on window for the Config page ----
  window.AppNav = {
    refresh: render,
    setPosition(p) { PREF.navPosition = p; render(); },
    setBehavior(b) { PREF.navBehavior = b; render(); },
    setTheme(t) {
      PREF.theme = t;
      document.documentElement.setAttribute('data-theme', t);
      render();
    },
    getPrefs() {
      return {
        position: PREF.navPosition,
        behavior: PREF.navBehavior,
        theme: PREF.theme,
        user: getUser(),
      };
    },
    async signOut() {
      try { await fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin' }); }
      catch (e) {}
      setUser(null);
      window.location.href = LOGIN_URL;
    },
  };

  // ---- Init ----
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }

  // Auto-hide on scroll (optional behavior)
  let lastScroll = 0;
  window.addEventListener('scroll', () => {
    if (PREF.navBehavior !== 'auto-hide') return;
    const nav = document.querySelector('.app-nav');
    if (!nav) return;
    const cur = window.scrollY;
    if (cur > lastScroll && cur > 60) {
      nav.classList.add('behavior-hidden');
      document.body.classList.add('nav-hidden');
    } else {
      nav.classList.remove('behavior-hidden');
      document.body.classList.remove('nav-hidden');
    }
    lastScroll = cur;
  }, { passive: true });

})();
