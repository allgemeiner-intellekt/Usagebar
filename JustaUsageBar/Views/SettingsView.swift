//
//  SettingsView.swift
//  JustaUsageBar
//

import AppKit
import Combine
import SwiftUI

nonisolated enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case providers
    case connection
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .connection: "Connection"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.grid.2x2"
        case .connection: "cylinder.split.1x2"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedSection: SettingsSection = .general
    @Published var availableUpdateVersion: String?
    @Published var installedVersion: String = ""
    @Published var installedBuild: String = ""
    @Published var globalHotkeyError: String?

    var onRefresh: () -> Void = {}
    var onOpenGitHub: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onGlobalHotkeyChange: (GlobalHotkey?) -> Void = { _ in }
    var onGlobalHotkeyRecordingChanged: (Bool) -> Void = { _ in }
    var loadCPAConnection: () async -> CPAConnection? = { await CredentialStorage.shared.cpaConnection }
}

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var navigation: SettingsNavigationModel

    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { navigation.selectedSection },
            set: { if let section = $0 { navigation.selectedSection = section } }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: selectionBinding) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 210)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch navigation.selectedSection {
                case .general:
                    GeneralSettingsPane(viewModel: viewModel, navigation: navigation)
                case .providers:
                    ProvidersSettingsPane(viewModel: viewModel)
                case .connection:
                    ConnectionSettingsPane(viewModel: viewModel, navigation: navigation)
                case .about:
                    AboutSettingsPane(navigation: navigation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 580, minHeight: 400)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if !navigation.installedVersion.isEmpty {
                    Text("v\(navigation.installedVersion)")
                }
                Spacer()
                Text("CLIProxyAPI")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var navigation: SettingsNavigationModel
    @State private var shortcutValidationError: String?

    private var refreshOptions: [TimeInterval] {
        var values = UsageViewModel.supportedRefreshIntervals
        if !values.contains(viewModel.refreshInterval) {
            values.append(viewModel.refreshInterval)
            values.sort()
        }
        return values
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(isOn: Binding(
                    get: { viewModel.launchAtStartup },
                    set: { viewModel.launchAtStartup = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Start Usagebar automatically when you sign in to macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent {
                    GlobalHotkeyRecorderView(
                        hotkey: viewModel.globalHotkey,
                        onChange: { hotkey in
                            shortcutValidationError = nil
                            navigation.onGlobalHotkeyChange(hotkey)
                        },
                        onValidationError: { message in
                            shortcutValidationError = message
                        },
                        onRecordingChange: { recording in
                            if recording {
                                shortcutValidationError = nil
                                navigation.globalHotkeyError = nil
                            }
                            navigation.onGlobalHotkeyRecordingChanged(recording)
                        }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toggle Panel")
                        Text("Open or close the Usagebar panel from any app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                if let error = shortcutValidationError ?? navigation.globalHotkeyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Requires at least one modifier key (⌘, ⌃, or ⌥). Works without Accessibility permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Refresh Interval", selection: Binding(
                    get: { viewModel.refreshInterval },
                    set: { viewModel.updateRefreshInterval($0) }
                )) {
                    ForEach(refreshOptions, id: \.self) { seconds in
                        Text(intervalOptionLabel(seconds)).tag(seconds)
                    }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        if viewModel.isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Button("Refresh Now") {
                            navigation.onRefresh()
                        }
                        .disabled(viewModel.isLoading)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manual Refresh")
                        Text(lastUpdatedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Refresh")
            } footer: {
                let openCadence = formatInterval(viewModel.effectiveRefreshInterval)
                let hiddenCadence = formatInterval(viewModel.effectiveRefreshInterval * 5)
                Text("Polls every \(openCadence) while the panel or settings are open, and every \(hiddenCadence) when closed. Low Power Mode uses at least 5 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                LabeledContent {
                    Button("Configure…") {
                        navigation.selectedSection = .connection
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CLIProxyAPI")
                        Text(viewModel.isCPAConfigured == true ? "Configuration saved" : "Set up a connection")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastUpdatedSummary: String {
        guard let date = viewModel.lastUpdated else { return "Not updated yet" }
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        return minutes < 1 ? "Updated just now" : "Updated \(minutes)m ago"
    }

    private func intervalOptionLabel(_ seconds: TimeInterval) -> String {
        let base = formatInterval(seconds)
        return seconds == UsageViewModel.defaultRefreshInterval ? "\(base) (Default)" : base
    }

    private func formatInterval(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        if rounded % 60 == 0 {
            let minutes = rounded / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(rounded) seconds"
    }
}

private struct GlobalHotkeyRecorderView: View {
    let hotkey: GlobalHotkey?
    let onChange: (GlobalHotkey?) -> Void
    let onValidationError: (String?) -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var pendingModifiers: GlobalHotkey.Modifiers = []
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(buttonLabel)
                    .font(hotkey != nil && !isRecording ? .system(size: 12, weight: .medium, design: .rounded) : .system(size: 12))
                    .foregroundStyle(isRecording ? Color.accentColor : (hotkey != nil ? Color.primary : Color.secondary))
                    .frame(minWidth: 118)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: isRecording ? 1.5 : 1)
                    )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press a shortcut, Escape to cancel, or Delete to clear" : "Click to record a global shortcut")

            if hotkey != nil && !isRecording {
                Button {
                    onValidationError(nil)
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording {
                stopRecording()
            }
        }
        .onDisappear {
            if isRecording {
                stopRecording()
            }
        }
    }

    private var buttonLabel: String {
        if isRecording {
            let mods = pendingModifiers.displayString
            return mods.isEmpty ? "Type shortcut…" : "\(mods)…"
        }
        return hotkey?.displayString ?? "Record Shortcut"
    }

    private func startRecording() {
        isRecording = true
        pendingModifiers = []
        onRecordingChange(true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
        }
    }

    private func stopRecording() {
        isRecording = false
        pendingModifiers = []
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        onRecordingChange(false)
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        if event.type == .flagsChanged {
            pendingModifiers = GlobalHotkey.Modifiers(nsEventFlags: event.modifierFlags)
            return nil
        }

        guard event.type == .keyDown else { return event }

        let keyCode = UInt32(event.keyCode)
        let modifiers = GlobalHotkey.Modifiers(nsEventFlags: event.modifierFlags)

        if keyCode == GlobalHotkey.escapeKeyCode && modifiers.isEmpty {
            onValidationError(nil)
            stopRecording()
            return nil
        }

        if (keyCode == GlobalHotkey.deleteKeyCode || keyCode == GlobalHotkey.forwardDeleteKeyCode) && modifiers.isEmpty {
            onValidationError(nil)
            stopRecording()
            onChange(nil)
            return nil
        }

        let candidate = GlobalHotkey(keyCode: keyCode, modifiers: modifiers)
        if let error = candidate.validate() {
            NSSound.beep()
            onValidationError(error.localizedDescription)
            return nil
        }

        onValidationError(nil)
        stopRecording()
        onChange(candidate)
        return nil
    }
}

// MARK: - Providers

private struct ProvidersSettingsPane: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        Form {
            Section {
                ForEach(DisplayProvider.displayOrder, id: \.self) { provider in
                    providerRow(for: provider)
                }
            } header: {
                Text("Visible Providers")
            }

            if viewModel.hasAntigravityAccounts || !viewModel.hiddenAntigravityPoolIDs.isEmpty {
                antigravityPoolsSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func providerRow(for provider: DisplayProvider) -> some View {
        HStack(spacing: 10) {
            ProviderMarkView(provider: provider)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.panelTitle)
                    .fontWeight(.medium)
                Text(statusText(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            let isLocked = viewModel.isLastVisibleAvailableProvider(provider)
            Toggle("", isOn: Binding(
                get: { viewModel.isProviderShown(provider) },
                set: { viewModel.setProviderShown($0, for: provider) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isLocked)
            .help(isLocked ? "At least one active provider must remain visible." : "Show \(provider.panelTitle) in the panel")
        }
        .padding(.vertical, 2)
    }

    private var antigravityPoolsSection: some View {
        let pools = viewModel.discoveredAntigravityPools
        return Section {
            if pools.isEmpty {
                Text("No pools loaded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pools) { pool in
                    Toggle(pool.label, isOn: Binding(
                        get: { viewModel.isAntigravityPoolVisible(pool.id) },
                        set: { visible in
                            if viewModel.isAntigravityPoolVisible(pool.id) != visible {
                                viewModel.toggleAntigravityPool(pool.id)
                            }
                        }
                    ))
                }
            }
            HStack {
                Spacer()
                Button("Show All Pools") {
                    viewModel.showAllAntigravityPools()
                }
                .controlSize(.small)
                .disabled(viewModel.hiddenAntigravityPoolIDs.isEmpty)
            }
        } header: {
            Text("Antigravity Pools")
        } footer: {
            Text("Newly discovered Antigravity model pools are shown by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(for provider: DisplayProvider) -> String {
        let accounts = viewModel.cpaAccounts.filter { $0.provider == provider }
        if viewModel.isCPAConfigured == false { return "Connect to CLIProxyAPI in Connection settings" }
        if accounts.isEmpty && viewModel.cpaError != nil { return "Account list unavailable" }
        guard !accounts.isEmpty else { return "No accounts discovered" }
        let countLabel = accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
        var parts = [countLabel]
        if provider == .antigravity {
            let poolCount = viewModel.discoveredAntigravityPools.count
            if poolCount > 0 {
                parts.append(poolCount == 1 ? "1 pool" : "\(poolCount) pools")
            }
        }
        if let lastSuccess = accounts.compactMap(\.refresh.lastSuccess).max() {
            let minutes = max(0, Int(Date().timeIntervalSince(lastSuccess) / 60))
            parts.append(minutes == 0 ? "Updated just now" : "Updated \(minutes)m ago")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProviderMarkView: View {
    let provider: DisplayProvider

    var body: some View {
        let accent = Color(nsColor: provider.panelAccent)
        Group {
            if let image = NSImage(named: provider.panelMarkName), image.size.height > 0 {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(accent)
            } else {
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Connection

private struct ConnectionSettingsPane: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var navigation: SettingsNavigationModel

    @State private var address = ""
    @State private var key = ""
    @State private var hasSavedCPA = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var busy = false

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Base Address")
                        .font(.caption)
                        .fontWeight(.medium)
                    TextField("", text: $address, prompt: Text("https://localhost:8317"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Management Key")
                        .font(.caption)
                        .fontWeight(.medium)
                    PasswordField(prompt: "Enter management key", text: $key)
                }

                HStack(spacing: 8) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let connectionError = viewModel.cpaError {
                        Text(connectionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if hasSavedCPA {
                        Text("Configuration saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button("Clear Saved", role: .destructive) {
                        run {
                            try await viewModel.clearCPAConfiguration()
                            address = ""
                            key = ""
                            hasSavedCPA = false
                            statusMessage = "CPA configuration removed."
                            statusIsError = false
                        }
                    }
                    .disabled(!hasSavedCPA)

                    Button("Test & Save") {
                        run {
                            try await viewModel.testAndSaveCPA(address: trimmedAddress, key: trimmedKey)
                            hasSavedCPA = true
                            statusMessage = "Connection verified and saved."
                            statusIsError = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedAddress.isEmpty || trimmedKey.isEmpty)
                }
            } header: {
                Text("CLIProxyAPI Connection")
            } footer: {
                Text("Remote connections should use HTTPS. HTTP sends the management key in plaintext. CPA must allow remote management for remote access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .task {
            let saved = await navigation.loadCPAConnection()
            address = saved?.address ?? ""
            key = saved?.key ?? ""
            hasSavedCPA = saved != nil
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        statusMessage = nil
        statusIsError = false
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                statusIsError = true
                statusMessage = (error as? CPAError)?.errorDescription
                    ?? "Could not save or connect. Check the address, key, and network."
            }
        }
    }
}

private struct PasswordField: View {
    let prompt: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField("", text: $text, prompt: Text(prompt))
                } else {
                    SecureField("", text: $text, prompt: Text(prompt))
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide secret" : "Show secret")
            .accessibilityLabel(isRevealed ? "Hide secret" : "Show secret")
        }
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    @ObservedObject var navigation: SettingsNavigationModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("PanelIcon")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Usagebar")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(versionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Native macOS menu-bar usage monitor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Updates & Links") {
                LabeledContent {
                    if let updateVersion = navigation.availableUpdateVersion {
                        Button("Update to v\(updateVersion)") {
                            navigation.onCheckForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Download Personal Build…") {
                            navigation.onCheckForUpdates()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personal Builds")
                        Text(navigation.availableUpdateVersion != nil
                             ? "A newer release is available."
                             : "Download latest artifacts from GitHub Actions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Review GitHub Repo") {
                        navigation.onOpenGitHub()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Source Code")
                        Text("View repository, issues, and documentation on GitHub.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Privacy") {
                Text("Usagebar has no project-operated backend and collects no telemetry. Managed credentials are encrypted locally on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Not affiliated with Anthropic, OpenAI, Cursor, Moonshot AI, Z.ai, xAI, or Google.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var versionSummary: String {
        if navigation.installedVersion.isEmpty {
            return "Personal Build"
        }
        return "Version \(navigation.installedVersion) (\(navigation.installedBuild))"
    }
}

#Preview {
    SettingsView(viewModel: UsageViewModel.shared, navigation: SettingsNavigationModel())
}
