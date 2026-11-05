# AGENTS.md

Guidance for agents/developers working on Alter.

## What this is

macOS window switcher app (Swift, AppKit + SwiftUI views, zero third-party dependencies). Global hotkey summons a floating panel listing windows (icon + app name + title); releasing the modifier activates the selection.

## Build & verify

- `make build` — xcodebuild, Debug, into `build/`. Must end with `BUILD SUCCEEDED`.
- `make run` — build + `open` the app. `make clean` wipes `build/`.
- No test target. Verification is manual: press the hotkey, check the panel, confirm a switch happens.
- **LSP noise**: SourceKit reports bogus "cannot find X in scope" cross-file errors until a build indexes the project. Trust `make build`, not editor diagnostics.
- **Do not** revert to a SwiftUI `Settings` scene for the settings window: its `showSettingsWindow:` action reported handled but never materialized a window on macOS 15/Xcode 26. The self-managed `NSWindow` in `AppDelegate.showSettings()` is deliberate.

## Project layout

- `alter.xcodeproj/` — hand-written, Xcode 16+ folder-synchronized format (`PBXFileSystemSynchronizedRootGroup` on `Alter/`). **Just drop new .swift files into `Alter/`** — no pbxproj edits needed. Keep `Info.plist` at the repo root (inside the synced folder it would be bundled as a resource).
- `Alter/Assets.xcassets/` — app icon (`AppIcon`, classic 10-slot mac format — the Xcode 14+ single-1024 slot is rejected by actool 26 with "unassigned child"). `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set in the target configs. The 1024 master was rendered by a throwaway AppKit script (not committed); regenerate or replace `icon_1024.png` and `sips -z` down to the other sizes if redesigning.
- `Makefile` — build/run/clean wrapper.
- Target: macOS 14.0+, Swift 5 mode, signed "Apple Development" (see Signing below).

## Architecture (data flow)

```
CGEventTap (HotkeyMonitor)
  -> SwitcherCoordinator.handle(action)
     -> show: WindowCatalog.currentWindows -> SwitcherViewModel -> SwitcherPanel (NSPanel + SwiftUI)
     -> confirm: WindowActivator.activate(entry)
```

- `main.swift` — plain AppKit bootstrap (no SwiftUI App lifecycle). AppDelegate builds the app menu by hand.
- `HotkeyMonitor` — `CGEventTap` on `.keyDown` + `.flagsChanged` at `.cgSessionEventTap`, head-insert, active (`.defaultTap`) so events can be **swallowed** (return nil). Trigger modifier is configurable (`.maskAlternate` default / `.maskCommand`). Modifier-release-to-confirm is detected in `flagsChanged`. Re-enables itself on tap-timeout. Backtick ignores autorepeat events (`keyboardEventAutorepeat` field) so each physical press advances exactly once; Tab keeps autorepeat (hold-to-cycle, like native Cmd-Tab).
- `WindowCatalog` — two CGWindowList queries merged: `.optionOnScreenOnly` (true front-to-back z-order — `.optionAll` is effectively creation order, do NOT rely on it for recency) plus `.optionAll`-only windows (minimized) appended after; `.excludeDesktopElements` on both, layer-0 only, ≥50×50pt, skips self/Dock/WindowServer. Windows that are off-screen **and** not AX-minimized are dropped (they're on other Spaces). Matches CG windows to AX windows by exact CGWindowID (`_AXUIElementGetWindow`), then title, then bounds proximity (see Invariant 6). Optional filters read from SettingsStore at summon time: `windowScope` (all displays vs pointer's display — bounds converted Quartz→Cocoa via `primaryHeight - maxY`, straddling windows count on both, minimized windows use stale pre-minimize bounds) and `frontAppScope` for the Opt-\` mode (bundle-ID clubbing vs exact frontmost PID).
- `AppRecencyTracker` — MRU order from `NSWorkspace.didActivateApplicationNotification`, keyed by **bundle ID (app key)**, not PID — apps with one process per window (Ghostty) must stay clubbed. The `.allProcesses` front-app filter in the catalog uses the same key.
- `WindowActivator` — unhide → cooperative `app.activate(from: frontmostApp, options: [])` (the deprecated `activateIgnoringOtherApps` flag is a no-op on macOS 14+ and can silently fail; only used as a no-frontmost-app fallback) → AX unminimize → `kAXRaiseAction` + set main/focused, then a +150ms verify-and-retry pass (activation is async; the immediate focus calls can land before the app is frontmost and get dropped).
- `SwitcherPanelController` — one `SwitcherPanel` per `NSScreen` (switcher shows on all monitors, identical clones keyed by `NSScreenNumber`); drops all cached panels on `didChangeScreenParametersNotification` and recreates lazily on next show (cached `NSScreen` objects go stale on rearrangement).
- `SwitcherPanel` — borderless `.nonactivatingPanel`, `.canJoinAllSpaces + .fullScreenAuxiliary`, all keys handled by the event tap so the panel never takes key status. Sized via `NSHostingController.sizingOptions = [.preferredContentSize]` + KVO on `preferredContentSize` (SwiftUI lays out asynchronously — never read a size in the same run-loop tick as a model change; that was a real bug).
- `SwitcherViewModel` — `@Observable`; selection defaults to row 1 (quick-toggle to previous window).
- `SettingsStore` — `@Observable`, UserDefaults-backed; `onTriggerModifierChange` callback applies changes live (no restart).
- `Permissions` — AX (`AXIsProcessTrustedWithOptions`) and Screen Recording (`CGPreflightScreenCaptureAccess`); Settings polls both every second while open.

## Invariants / gotchas (do not break)

1. **Never swallow more than the configured trigger combos.** The other modifier (Cmd in Option mode, Option in Command mode) and Control must pass through — users rely on Cmd-Tab falling back to native in Option mode.
2. **Panel must stay non-activating.** Focus must remain with the user's app so "frontmost app" (used by Opt-\` filtering) doesn't become Alter.
3. **Exclude Alter's own PID** in the catalog or the panel lists itself.
4. **Ad-hoc signing invalidates TCC grants on every rebuild.** Keep the Apple Development identity (`CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM = 29DC9FRNK7` in the pbxproj). If the user reports re-prompts every build, check this first.
5. If codesign hangs during build, it's a keychain prompt/lock — `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db` fixes it (asks user password).
6. CG↔AX window matching: exact CGWindowID first via the private-but-stable `_AXUIElementGetWindow` (same symbol AltTab/Amethyst use), falling back to title then bounds heuristics. Keep the fallback — the symbol is undocumented. Bounds of minimized windows can be stale — don't make heuristic matching stricter without handling that.

## Known limitations (documented in README too)

- Other-Space windows excluded (needs private SkyLight APIs — avoid unless explicitly requested).
- Hidden (Cmd-H) apps' windows excluded.
