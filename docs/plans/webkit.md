# Plan: HTML/JS-customizable switcher UI (WebKit themes)

Status: complete — all phases implemented and manually validated (Phase 0
spike PASS, Phase 1 core bridge, Phase 2 tag library + sample themes, Phase 3
hardening + docs). Includes the first-show gating fix discovered in manual
testing (see Phase 2 note below).
Last updated: 2026-11-09

## Goal

Let users fully customize the switcher's look-and-feel with plain HTML/CSS/JS.
A theme is a folder containing an `index.html`, any CSS/JS/assets, and a small
`theme.json` manifest. Themes receive switcher state (window list, selection,
mode) from the native side and render it however they want — from a clone of
the native look to designs that are impossible in the built-in UI.

**Theming is opt-in and disabled by default.** The built-in SwiftUI UI remains
the default experience; nothing changes unless the user explicitly selects a
theme in Settings. The native UI also stays permanently as the automatic
fallback whenever a theme is missing, invalid, or crashes.

## Feasibility summary

Feasible, and the codebase is well-shaped for it:

- All keyboard input arrives via the CGEventTap (`HotkeyMonitor`) — the panel
  never becomes key. The web content only has to **render state and report
  clicks**. Modifier-release-to-confirm, Tab/backtick cycling, Esc, and arrows
  all stay native and unaffected.
- `SwitcherViewModel` is already a serializable snapshot (`windows`,
  `selectedIndex`, `mode`, thumbnails) — ideal bridge material.
- `SwitcherPanel` is a thin NSPanel around a content view; swapping the SwiftUI
  view for a `WKWebView` is a localized change.
- App is not sandboxed (no entitlements file), so
  `loadFileURL(_:allowingReadAccessTo:)` works on user theme folders without
  security-scoped bookmarks. WKWebView needs no extra entitlements and works
  under the current ad-hoc debug signing.

### The one load-bearing risk — VALIDATED (Phase 0, PASS)

**Mouse clicks into a WKWebView inside a `.nonactivatingPanel`.** SwiftUI tap
gestures were already proven in this panel configuration; WKWebView renders
in a separate WebContent process and had to be verified. Phase 0 results
(spike app replicating `SwitcherPanel`'s exact panel config, run while
Ghostty stayed frontmost):

- Synthetic `CGEvent` click -> JS `click` handler fired via
  `webkit.messageHandlers` — PASS (confirmed in two runs).
- **Real human click -> JS handler fired — PASS.** Frontmost app unchanged.
- Scroll wheel over an `overflow:scroll` div -> JS `scroll` event — PASS.
- CSS `:hover` renders (cursor over the button applied the hover style). JS
  `mousemove` did NOT fire from synthetic move events — likely a
  synthetic-event artifact; re-verify with a real mouse in Phase 1. Not
  gating (worst case: no JS-driven hover effects; CSS hover is confirmed).
- Focus invariant held throughout: `NSWorkspace.frontmostApplication` never
  left Ghostty.

**Gotcha found, recorded for posterity:** an *unbundled* binary (plain
`swiftc` output) shows the WKWebView window as on-screen in CGWindowList but
renders it fully invisible, and clicks pass through to whatever is beneath.
Wrapping the identical binary in a minimal `.app` bundle (Info.plist + ad-hoc
`codesign`) fixed rendering and click delivery completely. No implication for
Alter itself (always bundled/signed), but any future standalone test harness
must be bundled or it will produce false negatives.

## Decisions (locked)

1. **Theme API: data bridge + optional tag library.** The core API is a JSON
   state bridge (Native ↔ JS). Additionally, Alter ships an optional bundled
   `alter-elements.js` defining `<al-list>`, `<al-shot>`, `<al-icon>` etc. as
   web components wired to the bridge — casual users compose tags, power users
   write arbitrary rendering JS (or bundle any framework; it's all local
   files). Custom tags alone were rejected: they'd constrain layouts to what
   the component library allows, and Alter would have to ship the JS library
   anyway since a WKWebView can't render custom tags natively.
2. **Multi-screen in themed mode: active (pointer) screen only.** Today the
   native UI clones one SwiftUI view per screen for free; N live webviews are
   real memory each. Themed shows route through the existing `show(on:)`
   single-screen path. The native theme keeps its multi-screen clones.
3. **Opt-in, disabled by default.** Built-in SwiftUI UI is the default;
   theming activates only when the user picks a theme in Settings.

## Architecture

```
CGEventTap (HotkeyMonitor)                <- unchanged, sole keyboard source
  -> SwitcherCoordinator.handle(action)   <- chooses panel flavor by setting
     -> WindowCatalog.currentWindows
     -> SwitcherViewModel (state snapshot)
     -> SwitcherPanel (NSPanel)
          content: built-in SwitcherView (SwiftUI)   [default]
                OR ThemedSwitcherView (WKWebView)    [opt-in]
                     ^  |  alter.update(stateJSON)     native -> JS
                     |  v  messageHandlers.alter       JS -> native
                     alter-icon:// / alter-shot://     images via URL scheme
```

### Theme packaging

`~/Library/Application Support/Alter/Themes/<name>/` (overridable for
development via the `ALTER_THEMES_DIR` environment variable):

- `index.html` — entry point (required).
- `theme.json` — manifest: `{name, author, version, size: "auto" | {width, height}}`.
- Any CSS/JS/assets, referenced relatively. `alter-elements.js` (Phase 2) is
  provided by the app; themes opt into it with a `<script>` tag.

### Native -> JS: state bridge

On every `SwitcherViewModel` change (observed via `withObservationTracking`),
the native side evaluates:

```js
window.alter.update({
  windows: [
    { id, appName, title, bounds: {x, y, w, h}, isMinimized, selected,
      iconUrl, shotUrl }
  ],
  mode: "allWindows" | "frontApp",
  previewsEnabled: true | false
})
```

Selection moves are just another `update()` call. `iconUrl`/`shotUrl` are
`alter-icon://<pid>` / `alter-shot://<windowId>?maxw=800` strings the theme
drops straight into `<img src>`. Icons key off pid (already on `WindowEntry`);
multiple windows of one process share the icon. An injected bootstrap defines
`window.alter` (update dispatch, `onUpdate` subscription, `select`/`confirm`/
`resize` helpers) at document start, plus a `window.onerror` trap that reports
to native.

### JS -> Native: message handler

```js
window.webkit.messageHandlers.alter.postMessage({ type: "select", index })
window.webkit.messageHandlers.alter.postMessage({ type: "confirm", index })
window.webkit.messageHandlers.alter.postMessage({ type: "resize", w, h })
window.webkit.messageHandlers.alter.postMessage({ type: "error", message })
```

- `confirm` maps to the existing `onConfirm` path (click = select + confirm,
  same semantics as today's row tap).
- `resize` feeds the existing center-fit math — panel position stays derived
  from the screen's `visibleFrame`, never from the panel frame (no-drift
  invariant).
- All messages are validated native-side (known type, index in bounds,
  size clamped); anything else is ignored.

### Images: custom URL scheme (not data URLs)

A `WKURLSchemeHandler` serves:

- `alter-icon://<pid>` — app icon PNG (in-memory cache per pid).
- `alter-shot://<windowId>?maxw=N` — on-demand ScreenCaptureKit capture via
  `WindowThumbnailer.captureOnDemand`, size bucketed to 256px steps and cached
  per session (cleared on begin/endSession, generation-guarded so stale
  results are dropped).

Lazy (only what the theme renders gets captured/encoded) and avoids large
base64 blobs through the bridge. No Screen Recording permission -> failure
response; themes degrade to icons (same contract as today's `PreviewPane`
fallback).

### WebView lockdown

- `WKNavigationDelegate` allows only `file://` within the theme directory and
  `alter-*://`; everything else is cancelled.
- A `WKContentRuleList` blocks `http(s)://` subresource/fetch loads (navigation
  delegate alone doesn't cover `fetch()`). This is a HUD rendering local user
  content, not a browser.
- Transparent webview background (`drawsBackground = false` KVC +
  `underPageBackgroundColor = .clear`) over the panel's clear background, so
  CSS can do rounded corners/translucency.

## Implementation phases

### Phase 0 — Go/no-go spike — DONE (PASS)

Standalone spike app (throwaway, not committed): `.nonactivatingPanel` +
WKWebView replicating `SwitcherPanel`'s exact config. Results: clicks, scroll,
and CSS hover all reach the web content while another app stays frontmost —
see "The one load-bearing risk" above for full results and the
unbundled-binary gotcha. **Go for Phase 1.**

### Phase 1 — Core bridge (~1–2 days) — DONE (2026-11-09)

Implemented and manually validated end-to-end with `Themes/example` (run via
`ALTER_THEMES_DIR=$PWD/Themes ALTER_THEME=example`): themed panel renders on
the pointer's display, Tab-cycling/release-confirm/Esc work, click-to-confirm
activates the clicked window, and `alter-shot://` screenshots load in the
preview area (with icon fallback). Settings gained the opt-in theme picker
(default: built-in). JS `mousemove` with a real mouse remains unverified —
the example theme doesn't use it; check when a theme needs it.

New files (drop into `Alter/`; folder-synchronized target — no pbxproj edits):

- `ThemeStore.swift` — discovers/validates themes, parses `theme.json`,
  creates/reveals the themes directory.
- `SwitcherBridge.swift` — the JS contract: state push via
  `withObservationTracking`, `WKScriptMessageHandler` for
  select/confirm/resize/error, injected bootstrap user script.
- `AlterSchemeHandler.swift` — `alter-icon://` / `alter-shot://`.
- `ThemedSwitcherPanel.swift` — one pre-warmed NSPanel (created at coordinator
  start when a theme is selected, so the ~100–300ms WKWebView cold start never
  hits summon latency) hosting a locked-down `WKWebView`; active screen only.

Modified files:

- `SwitcherCoordinator.swift` — reads the theme setting (live-applies via
  `SettingsStore.onThemeChange`), owns the themed panel, falls back to the
  native controller on theme error/crash; themed shows skip the preview-pane
  prefetch but still begin the thumbnail session (on-demand shots need it).
- `WindowThumbnailer.swift` — `captureOnDemand(id:maxWidth:completion:)` with
  bucketed per-session cache.
- `SettingsStore.swift` — `themeID` setting (persisted, default nil =
  built-in), `onThemeChange`, `ALTER_THEME`/`ALTER_THEMES_DIR` dev overrides.
- `SettingsView.swift` — theme picker ("Built-in (default)" + discovered
  themes) and "Reveal Themes Folder" button.

Test fixture:

- `Themes/example/` — minimal repo-local theme (index.html + theme.json)
  exercising the raw bridge (list render, click-to-confirm, screenshot
  preview). Run with `ALTER_THEMES_DIR=$PWD/Themes ALTER_THEME=example` for
  testing without touching Settings.

### Phase 2 — `alter-elements.js` helper library — DONE (2026-11-09)

Bundled custom elements wired to the bridge: `<al-list>` (window list with
::part()s `row`/`row-selected`/`icon`/`app-name`/`title` and custom
properties `--al-icon-size`/`--al-selection`/`--al-selection-fg`),
`<al-icon for="...">`, `<al-shot for="..." maxw="N">` (icon fallback built
in), `<al-preview>` (hides itself when previews are disabled), plus
`alter.autoResize()` (ResizeObserver -> `resize` message, pairs with
`"size": "auto"`). Served from the app bundle via a new allowlisted
`alter-lib://alter-elements.js` scheme (only that one filename — never
arbitrary bundle resources); Xcode's folder-synchronized target bundles the
.js as a resource automatically. Two sample themes shipped:
`Themes/native-clone/` (built-in look via the tag library, parity check) and
`Themes/icon-strip/` (Cmd-Tab-style horizontal strip via the raw bridge,
proving tag-free themes). `<al-item>` from the original sketch was dropped —
`windowAt(for)` index addressing on al-icon/al-shot covers single-window
composition without a template system.

**Sample-theme refresh (2026-11-09):** the three test themes (example,
native-clone, icon-strip) were removed and replaced by a ten-theme showcase
gallery under `Themes/`: `coder`, `retro-gaming`, `fantasy`, `techno`,
`nineties`, `cherry-blossom`, `book`, `cats`, `moto`, `rainbow` — all
raw-bridge implementations with bundled OFL fonts (license files included per
theme) and self-contained CSS/SVG textures (no downloaded images). The
alter-elements.js tag library remains bundled and documented; the gallery
deliberately demonstrates the raw-bridge path.

**First-show gating (found in manual testing):** the panel originally
appeared while the theme was still loading, so auto-size themes visibly grew
through intermediate sizes (strip -> empty wide -> content). Fixed by gating
the first present: `show()` queues (pendingShow) until didFinish + 80ms
settle beat for fixed-size themes, or until the first *post-load* resize for
`"size": "auto"` themes — `alter.autoResize()` starts its ResizeObserver only
after the first state render, so that resize implies rendered content. 0.6s
hard cap backstops hung themes. Subsequent shows are instant (page stays
warm).

### Phase 3 — Hardening, fallback, docs — DONE (2026-11-09)

- Fallback: theme missing / manifest invalid / WebContent process terminated
  (`webViewWebContentProcessDidTerminate`) / JS bootstrap error -> log once,
  use built-in theme for that show. Phase 3 added
  `didFailProvisionalNavigation` -> same path (theme deleted/corrupted after
  the panel was built). Permanent safety net.
- README: theme format, bridge protocol reference, tag library, sample theme
  walkthrough, constraints (local-only, look-and-feel only, no persistence).
- AGENTS.md: themed-vs-native panel branch, `alter-lib://` contract,
  "themed mode = active screen only" rule, opt-in default.

## Invariants preserved

- Panel stays **non-activating**; web content never handles keys; the event tap
  remains the sole keyboard input source (trigger-combo swallow rules
  untouched).
- Own-PID exclusion and all `WindowCatalog` scoping logic untouched.
- Ad-hoc debug signing and TCC-stability notes unaffected; still no sandbox, no
  new entitlements.
- Built-in SwiftUI UI remains the default and is behaviorally unchanged when
  theming is off.

## Out of scope for v1

- Multi-screen themed clones.
- Theme-defined hotkeys or interaction changes (themes are look-and-feel only).
- Networked themes, galleries, auto-update.
- Per-theme settings schemas surfaced in Alter's Settings UI.

## Risks after Phase 0

| Risk | Mitigation |
|---|---|
| ~~Clicks don't reach JS in the non-activating panel~~ | **Resolved in Phase 0 (PASS)** — synthetic + manual clicks, scroll, CSS hover all verified |
| JS `mousemove`/drag events may not fire (unverified with real mouse) | Re-check in Phase 1; CSS hover confirmed; worst case themes use click/keys only |
| WebContent process memory (~80–150MB for one webview) | Acceptable for a utility app; pre-warm amortizes startup; document it |
| Theme JS throws / renders blank | Injected `window.onerror` bootstrap -> native fallback theme |
| Stale screenshots across sessions | Existing generation counter drops late results; scheme handler checks it |
| Standalone test harnesses mislead (unbundled = invisible webview) | Always test bundled .app; recorded in the Phase 0 gotcha |

## Effort

| Piece | Effort |
|---|---|
| Phase 0 spike | **done — PASS** |
| Phase 1 core bridge | ~1–2 days |
| Phase 2 helper library + sample themes | ~1 day |
| Phase 3 hardening + docs | ~1 day |
| **Total remaining** | **~2–3 days** |
