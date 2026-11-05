import ServiceManagement
import SwiftUI

/// Basic settings, reachable via the Dock icon (app reopen), the app menu's
/// Settings… item (Cmd-,), or the menu-bar icon.
struct SettingsView: View {
    let settings: SettingsStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted
    @State private var screenRecordingGranted = Permissions.hasScreenRecording

    // Permissions can change in System Settings while this window is open.
    private let permissionPoller = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var triggerBinding: Binding<SettingsStore.TriggerModifier> {
        Binding(
            get: { settings.triggerModifier },
            set: { settings.setTriggerModifier($0) }
        )
    }

    private var windowScopeBinding: Binding<SettingsStore.WindowScope> {
        Binding(
            get: { settings.windowScope },
            set: { settings.setWindowScope($0) }
        )
    }

    private var frontAppScopeBinding: Binding<SettingsStore.FrontAppScope> {
        Binding(
            get: { settings.frontAppScope },
            set: { settings.setFrontAppScope($0) }
        )
    }

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("Hold and tap with", selection: triggerBinding) {
                    ForEach(SettingsStore.TriggerModifier.allCases) { modifier in
                        Text(modifier.title).tag(modifier)
                    }
                }
                .pickerStyle(.radioGroup)
                if settings.triggerModifier == .command {
                    Text("While Alter runs, the native app switcher and per-app window cycling are replaced. Quitting Alter restores them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Shortcuts") {
                LabeledContent("Window switcher") { Text(settings.triggerModifier.tabHint) }
                LabeledContent("Current app's windows") { Text(settings.triggerModifier.backtickHint) }
                Text("Hold the modifier and tap the shortcut to move through the list; release to switch. Esc cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Windows") {
                Picker("Show windows from", selection: windowScopeBinding) {
                    ForEach(SettingsStore.WindowScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Active display is the one with the mouse pointer. Minimized windows stay listed on the display they were minimized from.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("\(settings.triggerModifier.backtickHint) cycles", selection: frontAppScopeBinding) {
                    ForEach(SettingsStore.FrontAppScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Some apps run one process per window — “all of the app's windows” cycles them together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    granted: accessibilityTrusted,
                    action: Permissions.openAccessibilitySettings
                )
                permissionRow(
                    title: "Screen Recording (for window titles)",
                    granted: screenRecordingGranted,
                    action: Permissions.openScreenRecordingSettings
                )
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(permissionPoller) { _ in
            accessibilityTrusted = Permissions.isAccessibilityTrusted
            screenRecordingGranted = Permissions.hasScreenRecording
        }
    }

    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(granted ? "Granted" : "Not granted")
                    .foregroundStyle(.secondary)
                if !granted {
                    Button("Open Settings…", action: action)
                }
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle to the real status (e.g. requires approval).
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
