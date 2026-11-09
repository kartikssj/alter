# Alter

A fast window switcher for macOS — a replacement-grade alternative to the built-in Cmd-Tab, showing a centered list of windows (app icon + app name + window title), including minimized windows.

<p align="center">
  <img width="1204" height="483" alt="native" src="https://github.com/user-attachments/assets/9e7589a1-960c-4a9a-be59-ee77c7a15ae3" />
</p>

## Features

- **Opt-Tab** — list all on-screen and minimized windows across apps, sorted most-recently-used. Keep holding Option and tap Tab (Shift-Tab to go backwards); release Option to switch.
- **Opt-\`** — same list, filtered to the frontmost app's windows. Apps that run one process per window are clubbed together by bundle ID (configurable).
- **Live preview pane** — a screenshot of the highlighted window appears beside the list while you cycle (requires Screen Recording permission; can be turned off in Settings).
- **Command mode** (Settings) — use Cmd-Tab / Cmd-\` instead, replacing the native switcher and per-app window cycling while Alter runs. Quitting Alter instantly restores the native behavior.
- **Minimized windows** are listed (dimmed, with a dock badge) and restored on activation.
- **Settings window** — via Dock icon click, the menu-bar icon, or Cmd-, — with a trigger-modifier picker, live permission status, and launch-at-login.
- Esc cancels, ↑/↓ move, Enter confirms, clicking a row jumps straight to it.

## Install

**Homebrew** (from [kartikssj/homebrew-tap](https://github.com/kartikssj/homebrew-tap)):

```sh
brew install --cask kartikssj/tap/alter
```

**Manual:** grab `Alter-<version>.zip` from
[GitHub Releases](https://github.com/kartikssj/alter/releases), unzip, and move
`Alter.app` to `/Applications`.

Alter is not yet signed with an Apple Developer ID certificate, so Gatekeeper
will block the first launch ("cannot be opened because the developer cannot be
verified"). Right-click the app → **Open** once to bypass it permanently (or
install with `brew install --cask kartikssj/tap/alter --no-quarantine`).

## Requirements

- macOS 14+, Apple Silicon or Intel.
- **Accessibility permission** (required) — Alter intercepts the hotkeys via a CGEventTap and focuses windows via the AX API.
- **Screen Recording permission** (optional) — enables other apps' window titles and the live preview pane. Without it, rows show app names only.

## Build & run

```sh
make build    # compile -> build/Build/Products/Debug/Alter.app
make run      # build + launch
make clean    # wipe build/
```

Or open `alter.xcodeproj` in Xcode (16+) and run the `Alter` scheme.

The app is signed with an Apple Development certificate (configured in the target build settings) so that Accessibility/Screen Recording grants persist across rebuilds.

## Usage notes

- Quick-tap the shortcut to toggle between the two most recent windows (the list opens with the second row pre-selected).
- In Command mode, only exactly Cmd(+Shift)+Tab and Cmd-\` are intercepted — Cmd-Space, Cmd-Q, Cmd-Opt-Esc etc. pass through untouched.
- If Alter hangs or quits, macOS disables its event tap and the native switcher automatically works again — Cmd-Tab is never left dead.
- Inside secure password fields, event taps are blocked by macOS, so the shortcut briefly reverts to native behavior.

## Custom themes

The switcher's look is fully customizable with plain HTML/CSS/JS. **Ten
showcase themes are bundled with the app** — pick one in Settings →
Appearance → Switcher theme; no setup needed. Theming is opt-in: the built-in
UI stays the default, and is also the automatic fallback if a theme is
missing, fails to load, or throws a JS error.

To build your own: Settings → "Reveal Themes Folder…" opens
`~/Library/Application Support/Alter/Themes/` — drop a theme folder in there
and it appears in the picker. User themes **override bundled ones with the
same folder name**, so to customize a bundled theme, copy it into your themes
folder and edit the copy.

A theme is a folder in that directory:

```
Themes/my-theme/
  index.html   (required)
  theme.json   (optional manifest)
  ...any CSS/JS/assets, referenced relatively
```

```json
// theme.json
{
  "name": "My Theme",
  "author": "you",
  "size": "auto"                 // or { "width": 640, "height": 400 }
}
```

With `"size": "auto"`, call `alter.autoResize()` once and the panel fits
itself to your content; otherwise the manifest size (or the `alter.resize(w,
h)` message) drives the panel size. Themed mode shows on the pointer's
display only (the built-in UI keeps its per-display clones).

### The bridge

Alter pushes state as JSON whenever anything changes (selection moves are
just another update):

```js
window.alter.onUpdate(function (state) {
  // state = {
  //   windows: [{ id, pid, appName, title,
  //               bounds: { x, y, w, h },   // Quartz coords (top-left origin)
  //               isMinimized, selected, iconUrl, shotUrl }],
  //   selectedIndex, mode: "allWindows" | "frontApp", previewsEnabled
  // }
  render(state);
});
```

Report interactions back:

```js
alter.select(i);   // move the highlight
alter.confirm(i);  // click semantics: select + switch to that window
alter.resize(w, h);
```

`iconUrl` (`alter-icon://<pid>`) and `shotUrl` (`alter-shot://<windowId>?maxw=N`)
are plain `<img src>` URLs. Shots fail when a window is minimized or Screen
Recording is off — handle `img.onerror` and fall back to `iconUrl` (or use
the tag library, which does it for you).

### Tag library (optional)

```html
<script src="alter-lib://alter-elements.js"></script>
```

defines custom elements so simple themes need no rendering JS:

- `<al-list>` — the window list. Style via `::part(row)`, `::part(row-selected)`,
  `::part(icon)`, `::part(app-name)`, `::part(title)`; custom properties
  `--al-icon-size`, `--al-selection`, `--al-selection-fg`. Clicking a row
  confirms it.
- `<al-icon for="selected">` — an app icon (`for` = window index or `selected`).
- `<al-shot for="selected" maxw="800">` — a live window screenshot with
  automatic icon fallback.
- `<al-preview>` — the selected window's shot; hides itself when previews are
  disabled (mirrors the built-in behavior).

### Bundled themes

Ten showcase themes ship with the app (repo: `Themes/`, fonts are bundled,
SIL OFL — license files included per theme):

<p align="center">
  <img src="https://github.com/user-attachments/assets/f2889a0f-43af-4251-8443-f76296ae5df6" alt="The ten bundled themes, cycling" width="640">
</p>

- `coder/` — IDE/terminal look: line numbers, `❯` caret + blinking cursor,
  traffic-light header, preview in a split-editor pane.
- `retro-gaming/` — phosphor CRT: scanlines, pixel font, `▶` selection marker,
  pixelated screenshots.
- `fantasy/` — illuminated parchment scroll (light): Cinzel + IM Fell English,
  `❧` ornaments, wax-seal selection, framed-painting preview.
- `techno/` — neon HUD: notched corners, grid background, scanline sweep,
  glowing cyan/magenta.
- `nineties/` — Windows 95: gray bevels, gradient title bar, navy listbox
  selection, status bar, no preview (authentic).
- `cherry-blossom/` — sakura spring (light): falling petals, soft pink cards,
  Zen Maru Gothic.
- `book/` — an open book spread (light): spine crease, EB Garamond + Playfair
  Display, drop-cap + bookmark-ribbon selection, roman-numeral folio, preview
  as the illustration plate on the right page.
- `cats/` — cat café (light): the card has ears, paw-print bullets, tabby
  selection with wiggle, Baloo 2.
- `moto/` — race leaderboard (dark): carbon weave, P1…Pn positions, Ducati-red
  selection, checkered-flag strip, helmet-visor preview.
- `rainbow/` — gradient celebration (dark): animated rainbow ring (conic
  `@property`), golden-angle hue accent per row, Fredoka + Quicksand.

<details>
<summary><b>Full-size screenshots of every theme</b></summary>

<table>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/e6fd7f01-88cd-45d5-bda5-24e3395adbd3" alt="Coder theme" width="420"><br><b>Coder</b></td>
    <td><img src="https://github.com/user-attachments/assets/a3ecf072-bb90-4d1d-a911-ed62eb08c4c7" alt="Retro Gaming theme" width="420"><br><b>Retro Gaming</b></td>
  </tr>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/fa09f878-78f3-49e2-93c7-0e6ed8441e76" alt="Fantasy theme" width="420"><br><b>Fantasy</b></td>
    <td><img src="https://github.com/user-attachments/assets/4e4f7e37-1301-4a81-89b6-a07e3726388f" alt="Techno theme" width="420"><br><b>Techno</b></td>
  </tr>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/c005b1c1-0fa8-4495-a9cc-107bf1286969" alt="90s theme" width="420"><br><b>90s</b></td>
    <td><img src="https://github.com/user-attachments/assets/2495f041-43cb-408c-8c45-d4d189d6df42" alt="Cherry Blossom theme" width="420"><br><b>Cherry Blossom</b></td>
  </tr>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/739ac25f-c53d-4a88-8999-7605039c5e32" alt="Book theme" width="420"><br><b>Book</b></td>
    <td><img src="https://github.com/user-attachments/assets/e2f2c8d9-36d8-4da0-84c7-1a4d248c8c83" alt="Cats theme" width="420"><br><b>Cats</b></td>
  </tr>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/8d64825c-05e5-4bf8-8f4a-0d069737704a" alt="Moto theme" width="420"><br><b>Moto</b></td>
    <td><img src="https://github.com/user-attachments/assets/14ffa8d9-b3cb-40fc-a2cd-a5525f87eda7" alt="Rainbow theme" width="420"><br><b>Rainbow</b></td>
  </tr>
</table>
</details>

All ten are selectable in Settings out of the box. For theme development, run
from the repo with env overrides (launch the binary directly — `make run`'s
`open` doesn't forward them):
`ALTER_THEMES_DIR=$PWD/Themes ALTER_THEME=techno build/Build/Products/Debug/Alter.app/Contents/MacOS/Alter`

### Constraints (by design)

- Themes are **local-only**: network loads (http/https, including `fetch()`)
  are blocked; navigation is confined to the theme folder and `alter-*` URLs.
- Themes control **look-and-feel only**. Keyboard handling (Tab/backtick
  cycling, release-to-confirm, Esc, arrows, Enter) is always native.
- No persistent web storage; each show starts from a fresh push of state.

## Known limitations

- Windows on **other Spaces** are not listed (reliably switching Spaces requires private SkyLight APIs).
- Windows of **hidden apps** (Cmd-H) are not listed.
- Duplicate window titles within one app can occasionally cross-match the CG↔AX window pairing (title match is primary, bounds proximity is the fallback).

## Troubleshooting

- **Hotkeys stopped working after a rebuild** — System Settings → Privacy & Security → Accessibility, toggle Alter off and on (only needed if the signing identity changed). The Settings window shows live grant status.
- **codesign asks for the keychain password repeatedly during builds** — run once:
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`
- **App shows no window on launch** — that's by design; it's a switcher, not a document app. Look for the Dock icon or the menu-bar icon.
