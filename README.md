# Alter

A fast window switcher for macOS — a replacement-grade alternative to the built-in Cmd-Tab, showing a centered list of windows (app icon + app name + window title), including minimized windows.

## Features

- **Opt-Tab** — list all on-screen and minimized windows across apps, sorted most-recently-used. Keep holding Option and tap Tab (Shift-Tab to go backwards); release Option to switch.
- **Opt-\`** — same list, filtered to the frontmost app's windows. Apps that run one process per window (e.g. Ghostty) are clubbed together by bundle ID.
- **Command mode** (Settings) — use Cmd-Tab / Cmd-\` instead, replacing the native switcher and per-app window cycling while Alter runs. Quitting Alter instantly restores the native behavior.
- **Minimized windows** are listed (dimmed, with a dock badge) and restored on activation.
- **Settings window** — via Dock icon click, the menu-bar icon, or Cmd-, — with a trigger-modifier picker, live permission status, and launch-at-login.
- Esc cancels, ↑/↓ move, Enter confirms, clicking a row jumps straight to it.

## Install

Grab `Alter-<version>.zip` from
[GitHub Releases](https://github.com/kartikssj/alter/releases), unzip, and move
`Alter.app` to `/Applications`.

Alter is not yet signed with an Apple Developer ID certificate, so Gatekeeper
will block the first launch ("cannot be opened because the developer cannot be
verified"). Right-click the app → **Open** once to bypass it permanently.

## Requirements

- macOS 14+, Apple Silicon or Intel.
- **Accessibility permission** (required) — Alter intercepts the hotkeys via a CGEventTap and focuses windows via the AX API.
- **Screen Recording permission** (optional) — without it, other apps' window titles can't be read and rows show app names only.

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

## Known limitations

- Windows on **other Spaces** are not listed (reliably switching Spaces requires private SkyLight APIs).
- Windows of **hidden apps** (Cmd-H) are not listed.
- Duplicate window titles within one app can occasionally cross-match the CG↔AX window pairing (title match is primary, bounds proximity is the fallback).

## Troubleshooting

- **Hotkeys stopped working after a rebuild** — System Settings → Privacy & Security → Accessibility, toggle Alter off and on (only needed if the signing identity changed). The Settings window shows live grant status.
- **codesign asks for the keychain password repeatedly during builds** — run once:
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`
- **App shows no window on launch** — that's by design; it's a switcher, not a document app. Look for the Dock icon or the menu-bar icon.
