import Cocoa

/// Intercepts Opt-Tab / Opt-` globally via a CGEventTap and swallows them so the
/// system never sees them. Requires Accessibility permission; `start()` returns
/// false if the tap could not be created.
final class HotkeyMonitor {
    enum Action: Equatable {
        case cycleForward
        case cycleBackward
        case showFrontApp
        case confirm
        case cancel
        case move(Int)
        /// Search hotkey pressed (search-trigger modifier + Space).
        case searchToggle
        /// Keystroke for the open search panel: layout-correct text for
        /// printable keys, nil for the handled navigation/action keys
        /// (Escape/arrows/Return/Delete, identified by keyCode).
        case searchKey(text: String?, keyCode: Int, command: Bool)
    }

    /// Called on the main run loop (the tap is installed there).
    var onAction: ((Action) -> Void)?

    /// Set by the coordinator so the monitor knows whether releasing the
    /// trigger modifier confirms and whether arrows/Esc should be swallowed.
    var isSwitcherVisible = false

    /// While the search panel is visible, keystrokes are routed to it
    /// (see Action.searchKey) and the switcher combos are left untouched.
    var isSearchVisible = false

    /// Spotlight-style search: enabled toggle + modifier for Trigger+Space.
    var searchEnabled = true
    var searchTriggerModifier: CGEventFlags = .maskAlternate

    /// Which modifier summons the switcher: .maskAlternate (Option, default)
    /// or .maskCommand (Command, which replaces the native app switcher).
    var triggerModifier: CGEventFlags = .maskAlternate

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var triggerIsDown = false

    deinit {
        stop()
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let eventsOfInterest: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disables slow taps; re-enable ours.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch type {
        case .keyDown:
            // Search toggle: search-trigger + Space, same guard rule as the
            // switcher combos (other trigger modifier / Control not held).
            let otherSearchTrigger: CGEventFlags = searchTriggerModifier == .maskAlternate ? .maskCommand : .maskAlternate
            if searchEnabled,
               flags.contains(searchTriggerModifier),
               !flags.contains(otherSearchTrigger),
               !flags.contains(.maskControl),
               keyCode == Key.space {
                emit(.searchToggle)
                return nil // swallow
            }
            // Trigger+Tab / Trigger+Shift+Tab / Trigger+`. Only swallow when the
            // OTHER candidate trigger modifier is not also held (e.g. in Option
            // mode, Cmd-Tab must keep reaching the native switcher), and never
            // when Control is involved. Ignored while the search panel owns
            // the keyboard (the event falls through unswallowed).
            if !isSearchVisible {
                let otherTrigger: CGEventFlags = triggerModifier == .maskAlternate ? .maskCommand : .maskAlternate
                if flags.contains(triggerModifier),
                   !flags.contains(otherTrigger),
                   !flags.contains(.maskControl) {
                    if keyCode == Key.tab {
                        emit(flags.contains(.maskShift) ? .cycleBackward : .cycleForward)
                        return nil // swallow
                    }
                    if keyCode == Key.backtick {
                        // Ignore autorepeat: each physical press advances once.
                        // A held key would otherwise fly past the intended window —
                        // with exactly 2 windows a single repeat wraps back to the
                        // current one. (Tab keeps autorepeat: hold-to-cycle matches
                        // the native Cmd-Tab behavior.)
                        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                            emit(.showFrontApp)
                        }
                        return nil
                    }
                }
            }
            if isSearchVisible {
                return handleSearchKey(event, keyCode: keyCode, flags: flags)
            }
            if isSwitcherVisible {
                switch keyCode {
                case Key.escape:
                    emit(.cancel)
                    return nil
                case Key.downArrow:
                    emit(.move(1))
                    return nil
                case Key.upArrow:
                    emit(.move(-1))
                    return nil
                case Key.return:
                    emit(.confirm)
                    return nil
                default:
                    break
                }
            }
        case .flagsChanged:
            let triggerDown = flags.contains(triggerModifier)
            if triggerIsDown, !triggerDown, isSwitcherVisible {
                emit(.confirm)
            }
            triggerIsDown = triggerDown
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func emit(_ action: Action) {
        onAction?(action)
    }

    /// Routes a keystroke to the search panel. The search owns Escape,
    /// Return (⌘↩ = reveal in Finder), arrows, and Delete, plus any printable
    /// character without Command/Control. Everything else passes through so
    /// Cmd-Tab / Cmd-Q etc. keep working while searching (as with Spotlight).
    private func handleSearchKey(_ event: CGEvent, keyCode: Int, flags: CGEventFlags) -> Unmanaged<CGEvent>? {
        switch keyCode {
        case Key.escape:
            emit(.searchKey(text: nil, keyCode: keyCode, command: false))
            return nil
        case Key.return:
            emit(.searchKey(text: nil, keyCode: keyCode, command: flags.contains(.maskCommand)))
            return nil
        case Key.upArrow, Key.downArrow, Key.delete, Key.forwardDelete:
            if !flags.contains(.maskCommand), !flags.contains(.maskControl) {
                emit(.searchKey(text: nil, keyCode: keyCode, command: false))
                return nil
            }
        default:
            if !flags.contains(.maskCommand), !flags.contains(.maskControl),
               let text = Self.printableText(from: event) {
                emit(.searchKey(text: text, keyCode: keyCode, command: false))
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// The character string a keyDown would insert, read from the event so
    /// keyboard layout and Option-composed characters are respected. Returns
    /// nil for keys that only produce control characters (Tab etc.), which
    /// the caller then lets pass through to the frontmost app.
    private static func printableText(from event: CGEvent) -> String? {
        var buffer = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: length)
        let printable = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        return printable ? text : nil
    }
}

enum Key {
    static let tab = 48
    static let backtick = 50
    static let escape = 53
    static let `return` = 36
    static let space = 49
    static let delete = 51
    static let forwardDelete = 117
    static let upArrow = 126
    static let downArrow = 125
}
