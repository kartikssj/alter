import ServiceManagement
import SwiftUI

/// Settings window, reachable via the Dock icon (app reopen), the app menu's
/// Settings… item (Cmd-,), or the menu-bar icon. Split into tabs to keep the
/// window compact.
struct SettingsView: View {
    let settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            WindowSettingsTab(settings: settings)
                .tabItem { Label("Windows", systemImage: "macwindow") }
            SearchSettingsTab(settings: settings)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            PermissionSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 400)
    }
}

private struct GeneralSettingsTab: View {
    let settings: SettingsStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var themes: [ThemeStore.Theme] = []

    private var triggerBinding: Binding<SettingsStore.TriggerModifier> {
        Binding(
            get: { settings.triggerModifier },
            set: { settings.setTriggerModifier($0) }
        )
    }

    private var themeBinding: Binding<String?> {
        Binding(
            get: { settings.themeID },
            set: { settings.setTheme($0) }
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
            Section("Appearance") {
                Picker("Switcher theme", selection: themeBinding) {
                    Text("Built-in (default)").tag(String?.none)
                    ForEach(themes) { theme in
                        Text(theme.name).tag(String?.some(theme.id))
                    }
                }
                Button("Reveal Themes Folder…") {
                    ThemeStore.shared.revealInFinder()
                }
                Text("Custom themes are HTML/CSS/JS bundles (an index.html plus a theme.json manifest) that render the switcher; themes shipping a search.html style the search panel too. Themed panels appear on every display, in sync.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                LabeledContent("Window switcher") { Text(settings.triggerModifier.tabHint) }
                LabeledContent("Current app's windows") { Text(settings.triggerModifier.backtickHint) }
                Text("Hold the modifier and tap the shortcut to move through the list; release to switch. Esc cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            themes = ThemeStore.shared.availableThemes()
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

private struct WindowSettingsTab: View {
    let settings: SettingsStore

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

    private var previewsBinding: Binding<Bool> {
        Binding(
            get: { settings.showWindowPreviews },
            set: { settings.setShowWindowPreviews($0) }
        )
    }

    private var previewSizeBinding: Binding<SettingsStore.PreviewSize> {
        Binding(
            get: { settings.previewSize },
            set: { settings.setPreviewSize($0) }
        )
    }

    var body: some View {
        Form {
            Section("Window list") {
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
            Section("Preview") {
                Toggle("Show window preview", isOn: previewsBinding)
                if settings.showWindowPreviews {
                    Picker("Preview size", selection: previewSizeBinding) {
                        ForEach(SettingsStore.PreviewSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Text("Shows a live screenshot of the highlighted window next to the list. Requires Screen Recording permission.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SearchSettingsTab: View {
    let settings: SettingsStore

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.searchEnabled },
            set: { settings.setSearchEnabled($0) }
        )
    }

    private var modifierBinding: Binding<SettingsStore.TriggerModifier> {
        Binding(
            get: { settings.searchTriggerModifier },
            set: { settings.setSearchTriggerModifier($0) }
        )
    }

    private var applicationsBinding: Binding<Bool> {
        Binding(
            get: { settings.searchShowApplications },
            set: { settings.setSearchShowApplications($0) }
        )
    }

    private var foldersBinding: Binding<Bool> {
        Binding(
            get: { settings.searchShowFolders },
            set: { settings.setSearchShowFolders($0) }
        )
    }

    private var filesBinding: Binding<Bool> {
        Binding(
            get: { settings.searchShowFiles },
            set: { settings.setSearchShowFiles($0) }
        )
    }

    var body: some View {
        Form {
            Section("Spotlight-style search") {
                Toggle("Enable search", isOn: enabledBinding)
                if settings.searchEnabled {
                    Picker("Summon with", selection: modifierBinding) {
                        ForEach(SettingsStore.TriggerModifier.allCases) { modifier in
                            Text(modifier.title).tag(modifier)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    LabeledContent("Shortcut") { Text("\(settings.searchTriggerModifier.spaceHint)") }
                    Text("Type to search using the system Spotlight index. Return opens the selected result, ⌘↩ reveals it in Finder, Esc closes. The search panel shows on the pointer's display.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if settings.searchEnabled {
                Section("Show in results") {
                    Toggle("Applications", isOn: applicationsBinding)
                    Toggle("Folders", isOn: foldersBinding)
                    Toggle("Files (documents, images, media)", isOn: filesBinding)
                    if !settings.searchShowApplications && !settings.searchShowFolders && !settings.searchShowFiles {
                        Text("All categories are off — search will return no results.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettingsTab: View {
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted
    @State private var screenRecordingGranted = Permissions.hasScreenRecording

    // Permissions can change in System Settings while this window is open.
    private let permissionPoller = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    granted: accessibilityTrusted,
                    action: Permissions.openAccessibilitySettings
                )
                Text("Required. Lets Alter intercept the hotkeys and focus windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                permissionRow(
                    title: "Screen Recording",
                    granted: screenRecordingGranted,
                    action: Permissions.openScreenRecordingSettings
                )
                Text("Optional. Enables other apps' window titles and the preview pane.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
}
