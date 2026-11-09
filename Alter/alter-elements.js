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
})();
