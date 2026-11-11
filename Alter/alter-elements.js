/*
 * alter-elements.js — optional custom elements wired to Alter's bridge.
 *
 * Load from a theme with:
 *   <script src="alter-lib://alter-elements.js"></script>
 *
 * Elements (all styling via your CSS; internals exposed as ::part()s):
 *
 *   <al-list>                 the full window list (icon + app + title rows).
 *                             Parts: scroll, row, row-selected, icon,
 *                             app-name, title. Custom properties:
 *                             --al-icon-size, --al-selection,
 *                             --al-selection-fg. Clicking a row selects +
 *                             confirms it (same as the built-in UI).
 *   <al-icon for="selected">  an app's icon. `for` is a window index or
 *                             "selected" (default). Size it in CSS.
 *   <al-shot for="selected" maxw="800">
 *                             a live window screenshot; falls back to the app
 *                             icon while capturing, when minimized, or when
 *                             Screen Recording permission is missing.
 *   <al-preview>              al-shot for="selected" that also hides itself
 *                             when previews are disabled (native behavior).
 *
 * Search pages (search.html) use the same window.alter bridge with a
 * search-shaped state ({query, searching, selectedIndex, results:[...]}):
 *
 *   <al-search-field placeholder="Search">
 *                             the query text with a blinking caret.
 *                             Parts: field, placeholder, query, caret.
 *   <al-search-list>          the search result rows (icon + name + subtitle).
 *                             Parts: scroll, row, row-selected, icon, name,
 *                             subtitle, empty. Custom properties:
 *                             --al-icon-size, --al-selection,
 *                             --al-selection-fg. `empty-text` attribute sets
 *                             the no-results label (default "No results").
 *                             Clicking a row opens it (same as Return).
 *
 * Switcher elements no-op on search state and vice versa, so one script tag
 * safely serves both page types.
 *
 * Also installs window.alter.autoResize(): call it once (ideally combined
 * with `"size": "auto"` in theme.json) to keep the panel fitted to your
 * content via a ResizeObserver.
 */
(function () {
  if (!window.alter || !window.customElements) {
    console.error('alter-elements.js: window.alter bridge not found — is this running inside Alter?');
    return;
  }

  var state = null;
  var subscribers = [];

  window.alter.onUpdate(function (s) {
    state = s;
    subscribers.slice().forEach(function (el) {
      if (el.alterUpdate) el.alterUpdate(s);
    });
  });

  function windowAt(ref) {
    if (!state || !state.windows || state.windows.length === 0) return null;
    if (ref == null || ref === 'selected') return state.windows[state.selectedIndex] || null;
    var i = parseInt(ref, 10);
    return (i >= 0 && i < state.windows.length) ? state.windows[i] : null;
  }

  function subscribe(el) {
    subscribers.push(el);
    if (state && el.alterUpdate) el.alterUpdate(state);
  }

  function unsubscribe(el) {
    var i = subscribers.indexOf(el);
    if (i >= 0) subscribers.splice(i, 1);
  }

  /* ------------------------------------------------------------------ *
   *  <al-list> — the window list                                       *
   * ------------------------------------------------------------------ */

  var LIST_CSS = `
    :host { display: block; contain: content; color: #eee; font: 13px -apple-system, sans-serif; }
    .scroll { max-height: inherit; height: 100%; overflow-y: auto; padding: 6px; box-sizing: border-box; }
    .row { display: flex; align-items: center; gap: 12px; padding: 6px 10px;
           border-radius: 8px; cursor: default; }
    .row.selected { background: var(--al-selection, rgba(10, 132, 255, 0.85));
                    color: var(--al-selection-fg, #fff); }
    .row.minimized { opacity: 0.6; }
    .icon { width: var(--al-icon-size, 32px); height: var(--al-icon-size, 32px); flex: none; }
    .text { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .app { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .title { opacity: 0.65; font-size: 0.85em; white-space: nowrap; overflow: hidden;
             text-overflow: ellipsis; }
  `;

  class AlList extends HTMLElement {
    constructor() {
      super();
      var root = this.attachShadow({ mode: 'open' });
      var style = document.createElement('style');
      style.textContent = LIST_CSS;
      this._scroll = document.createElement('div');
      this._scroll.className = 'scroll';
      this._scroll.setAttribute('part', 'scroll');
      root.appendChild(style);
      root.appendChild(this._scroll);
    }

    connectedCallback() { subscribe(this); }
    disconnectedCallback() { unsubscribe(this); }

    alterUpdate(s) {
      if (!s.windows) return; // search-shaped state — not our page
      var scroll = this._scroll;
      scroll.innerHTML = '';
      var selectedRow = null;
      s.windows.forEach(function (w, i) {
        var row = document.createElement('div');
        row.className = 'row' + (w.selected ? ' selected' : '') + (w.isMinimized ? ' minimized' : '');
        row.setAttribute('part', w.selected ? 'row row-selected' : 'row');

        var icon = document.createElement('img');
        icon.className = 'icon';
        icon.setAttribute('part', 'icon');
        icon.src = w.iconUrl;
        icon.alt = '';

        var text = document.createElement('div');
        text.className = 'text';
        var app = document.createElement('div');
        app.className = 'app';
        app.setAttribute('part', 'app-name');
        app.textContent = w.appName;
        text.appendChild(app);
        if (w.title) {
          var t = document.createElement('div');
          t.className = 'title';
          t.setAttribute('part', 'title');
          t.textContent = w.title;
          text.appendChild(t);
        }

        row.appendChild(icon);
        row.appendChild(text);
        row.addEventListener('click', function () { window.alter.confirm(i); });
        scroll.appendChild(row);
        if (w.selected) selectedRow = row;
      });
      if (selectedRow) selectedRow.scrollIntoView({ block: 'nearest' });
    }
  }

  /* ------------------------------------------------------------------ *
   *  <al-icon> — one app's icon                                        *
   * ------------------------------------------------------------------ */

  class AlIcon extends HTMLElement {
    static get observedAttributes() { return ['for']; }

    constructor() {
      super();
      var root = this.attachShadow({ mode: 'open' });
      var style = document.createElement('style');
      style.textContent = `
        :host { display: inline-block; width: 32px; height: 32px; }
        img { width: 100%; height: 100%; object-fit: contain; display: block; }
      `;
      this._img = document.createElement('img');
      this._img.setAttribute('part', 'img');
      this._img.alt = '';
      root.appendChild(style);
      root.appendChild(this._img);
    }

    connectedCallback() { subscribe(this); }
    disconnectedCallback() { unsubscribe(this); }
    attributeChangedCallback() { this._render(); }

    alterUpdate() { this._render(); }

    _render() {
      var w = windowAt(this.getAttribute('for'));
      if (w && this._img.src !== w.iconUrl) this._img.src = w.iconUrl;
    }
  }

  /* ------------------------------------------------------------------ *
   *  <al-shot> — one window's live screenshot (icon fallback)          *
   * ------------------------------------------------------------------ */

  class AlShot extends HTMLElement {
    static get observedAttributes() { return ['for', 'maxw']; }

    constructor() {
      super();
      var root = this.attachShadow({ mode: 'open' });
      var style = document.createElement('style');
      style.textContent = `
        :host { display: flex; align-items: center; justify-content: center; }
        img { max-width: 100%; max-height: 100%;
              border-radius: var(--al-shot-radius, 6px); display: block; }
      `;
      this._img = document.createElement('img');
      this._img.setAttribute('part', 'img');
      this._img.alt = '';
      root.appendChild(style);
      root.appendChild(this._img);
    }

    connectedCallback() { subscribe(this); }
    disconnectedCallback() { unsubscribe(this); }
    attributeChangedCallback() { this._render(); }

    alterUpdate() { this._render(); }

    _render() {
      var w = windowAt(this.getAttribute('for'));
      if (!w) {
        this._img.removeAttribute('src');
        return;
      }
      // No permission / minimized -> straight to the icon, no broken image.
      var useShot = state.previewsEnabled && !w.isMinimized;
      var url = w.iconUrl;
      if (useShot) {
        url = w.shotUrl;
        var maxw = parseInt(this.getAttribute('maxw'), 10);
        if (maxw > 0) url = url.replace(/maxw=\d+/, 'maxw=' + Math.min(Math.max(maxw, 64), 2048));
      }
      if (this._img.src === url) return;
      var img = this._img;
      var iconUrl = w.iconUrl;
      img.onerror = useShot
        ? function () { img.onerror = null; img.src = iconUrl; } // capture failed mid-flight
        : null;
      img.src = url;
    }
  }

  /* ------------------------------------------------------------------ *
   *  <al-preview> — selected window's shot; hidden when previews off   *
   * ------------------------------------------------------------------ */

  class AlPreview extends AlShot {
    alterUpdate(s) {
      this.style.display = s.previewsEnabled ? '' : 'none';
      super.alterUpdate(s);
    }
  }

  /* ------------------------------------------------------------------ *
   *  <al-search-field> — query text + blinking caret (search pages)     *
   * ------------------------------------------------------------------ */

  var SEARCH_FIELD_CSS = `
    :host { display: block; color: inherit; font: inherit; }
    .field { display: flex; align-items: center; min-width: 0; min-height: 1.2em; }
    .placeholder { opacity: 0.4; white-space: nowrap; overflow: hidden; }
    .query { white-space: nowrap; overflow: hidden; }
    .caret { display: inline-block; flex: none; width: 2px; height: 1.1em;
             margin-left: 1px; background: currentColor; vertical-align: text-bottom;
             animation: al-blink 1.06s steps(1) infinite; }
    @keyframes al-blink { 50% { opacity: 0; } }
  `;

  class AlSearchField extends HTMLElement {
    constructor() {
      super();
      var root = this.attachShadow({ mode: 'open' });
      var style = document.createElement('style');
      style.textContent = SEARCH_FIELD_CSS;
      this._field = document.createElement('div');
      this._field.className = 'field';
      this._field.setAttribute('part', 'field');
      this._placeholder = document.createElement('span');
      this._placeholder.className = 'placeholder';
      this._placeholder.setAttribute('part', 'placeholder');
      this._query = document.createElement('span');
      this._query.className = 'query';
      this._query.setAttribute('part', 'query');
      this._caret = document.createElement('span');
      this._caret.className = 'caret';
      this._caret.setAttribute('part', 'caret');
      this._field.appendChild(this._placeholder);
      this._field.appendChild(this._query);
      this._field.appendChild(this._caret);
      root.appendChild(style);
      root.appendChild(this._field);
    }

    connectedCallback() {
      this._placeholder.textContent = this.getAttribute('placeholder') || 'Search';
      subscribe(this);
    }
    disconnectedCallback() { unsubscribe(this); }

    alterUpdate(s) {
      if (!s.results) return; // window-shaped state — not our page
      var q = s.query || '';
      this._query.textContent = q;
      if (q) {
        this._placeholder.style.display = 'none';
        // caret last: insertion point after the query text
        this._field.appendChild(this._caret);
      } else {
        this._placeholder.style.display = '';
        // caret first: before the placeholder, not after it
        this._field.insertBefore(this._caret, this._placeholder);
      }
    }
  }

  /* ------------------------------------------------------------------ *
   *  <al-search-list> — search result rows (search pages)               *
   * ------------------------------------------------------------------ */

  var SEARCH_LIST_CSS = `
    :host { display: block; contain: content; color: #eee; font: 13px -apple-system, sans-serif; }
    .scroll { max-height: inherit; height: 100%; overflow-y: auto; padding: 6px; box-sizing: border-box; }
    .row { display: flex; align-items: center; gap: 12px; padding: 6px 10px;
           border-radius: 8px; cursor: default; }
    .row.selected { background: var(--al-selection, rgba(10, 132, 255, 0.85));
                    color: var(--al-selection-fg, #fff); }
    .icon { width: var(--al-icon-size, 32px); height: var(--al-icon-size, 32px); flex: none; }
    .text { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .subtitle { opacity: 0.65; font-size: 0.85em; white-space: nowrap; overflow: hidden;
                text-overflow: ellipsis; }
    .row.selected .subtitle { opacity: 0.8; }
    .empty { padding: 18px 10px; text-align: center; opacity: 0.55; }
  `;

  class AlSearchList extends HTMLElement {
    constructor() {
      super();
      var root = this.attachShadow({ mode: 'open' });
      var style = document.createElement('style');
      style.textContent = SEARCH_LIST_CSS;
      this._scroll = document.createElement('div');
      this._scroll.className = 'scroll';
      this._scroll.setAttribute('part', 'scroll');
      root.appendChild(style);
      root.appendChild(this._scroll);
    }

    connectedCallback() { subscribe(this); }
    disconnectedCallback() { unsubscribe(this); }

    alterUpdate(s) {
      if (!s.results) return; // window-shaped state — not our page
      var scroll = this._scroll;
      scroll.innerHTML = '';
      if (!s.query) return; // nothing typed yet — theme's chrome stands alone
      var selectedRow = null;
      if (s.results.length === 0 && !s.searching) {
        var empty = document.createElement('div');
        empty.className = 'empty';
        empty.setAttribute('part', 'empty');
        empty.textContent = this.getAttribute('empty-text') || 'No results';
        scroll.appendChild(empty);
        return;
      }
      s.results.forEach(function (r, i) {
        var row = document.createElement('div');
        row.className = 'row' + (r.selected ? ' selected' : '');
        row.setAttribute('part', r.selected ? 'row row-selected' : 'row');

        var icon = document.createElement('img');
        icon.className = 'icon';
        icon.setAttribute('part', 'icon');
        icon.src = r.iconUrl;
        icon.alt = '';

        var text = document.createElement('div');
        text.className = 'text';
        var name = document.createElement('div');
        name.className = 'name';
        name.setAttribute('part', 'name');
        name.textContent = r.name;
        text.appendChild(name);
        if (r.subtitle) {
          var sub = document.createElement('div');
          sub.className = 'subtitle';
          sub.setAttribute('part', 'subtitle');
          sub.textContent = r.subtitle;
          text.appendChild(sub);
        }

        row.appendChild(icon);
        row.appendChild(text);
        row.addEventListener('click', function () { window.alter.confirm(i); });
        scroll.appendChild(row);
        if (r.selected) selectedRow = row;
      });
      if (selectedRow) selectedRow.scrollIntoView({ block: 'nearest' });
    }
  }

  /* ------------------------------------------------------------------ *
   *  autoResize — fit the panel to the content                         *
   * ------------------------------------------------------------------ */

  window.alter.autoResize = function () {
    var started = false;
    // Start measuring only after the theme has rendered the first state —
    // otherwise the panel sizes to an empty, pre-data body (strip flash).
    window.alter.onUpdate(function () {
      // rAF: let the render listeners (registered before this one) and the
      // resulting layout complete first.
      requestAnimationFrame(function () {
        if (started) return;
        started = true;
        var pending = false;
        new ResizeObserver(function () {
          if (pending) return;
          pending = true;
          requestAnimationFrame(function () {
            pending = false;
            window.alter.resize(
              Math.ceil(document.documentElement.scrollWidth),
              Math.ceil(document.documentElement.scrollHeight)
            );
          });
        }).observe(document.documentElement);
      });
    });
  };

  customElements.define('al-list', AlList);
  customElements.define('al-icon', AlIcon);
  customElements.define('al-shot', AlShot);
  customElements.define('al-preview', AlPreview);
  customElements.define('al-search-field', AlSearchField);
  customElements.define('al-search-list', AlSearchList);
})();
