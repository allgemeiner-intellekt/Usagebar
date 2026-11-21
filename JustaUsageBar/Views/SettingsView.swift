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
    case dataSource
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .dataSource: "Data Source"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.grid.2x2"
        case .dataSource: "cylinder.split.1x2"
        case .about: "info.circle"
        }
    }
}

nonisolated enum ProviderSetupSheet: String, Identifiable, Equatable, Sendable {
    case claude
    case codex
    case kimi

    var id: Self { self }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedSection: SettingsSection = .general
    @Published var activeSetupSheet: ProviderSetupSheet?
    @Published var availableUpdateVersion: String?
    @Published var installedVersion: String = ""
    @Published var installedBuild: String = ""

    var onRefresh: () -> Void = {}
    var onOpenGitHub: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var loadCPAConnection: () async -> CPAConnection? = { await CredentialStorage.shared.cpaConnection }
    var loadClaudeCredentials: () async -> (sessionKey: String, organizationId: String) = {
        let sessionKey = await CredentialStorage.shared.sessionKey ?? ""
        let organizationId = await CredentialStorage.shared.organizationId ?? ""
        return (sessionKey, organizationId)
    }
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
                    ProvidersSettingsPane(viewModel: viewModel, navigation: navigation)
                case .dataSource:
                    DataSourceSettingsPane(viewModel: viewModel, navigation: navigation)
                case .about:
                    AboutSettingsPane(navigation: navigation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 580, minHeight: 400)
        .sheet(item: $navigation.activeSetupSheet) { sheet in
            switch sheet {
            case .claude:
                ClaudeSetupSheet(viewModel: viewModel, navigation: navigation)
            case .codex:
                CodexSetupSheet(navigation: navigation)
            case .kimi:
                KimiSetupSheet(viewModel: viewModel)
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if !navigation.installedVersion.isEmpty {
                    Text("v\(navigation.installedVersion)")
                }
                Spacer()
                Text(viewModel.source == .cpa ? "CPA" : "Direct")
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

            Section("Data Source") {
                LabeledContent {
                    Button("Configure…") {
                        navigation.selectedSection = .dataSource
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Source")
                        Text(viewModel.source == .cpa
                             ? "CLIProxyAPI (remote accounts)"
                             : "Direct (local CLI and saved credentials)")
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

// MARK: - Providers

private struct ProvidersSettingsPane: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var navigation: SettingsNavigationModel

    private var displayedProviders: [DisplayProvider] {
        if viewModel.source == .cpa {
            return DisplayProvider.displayOrder
        }
        return DisplayProvider.displayOrder.filter { $0 != .antigravity }
    }

    var body: some View {
        Form {
            Section {
                ForEach(displayedProviders, id: \.self) { provider in
                    providerRow(for: provider)
                }
            } header: {
                Text(viewModel.source == .cpa ? "Visible Providers (CLIProxyAPI)" : "Providers & Accounts (Direct)")
            } footer: {
                if viewModel.source == .direct {
                    Text("Usagebar automatically detects local credentials from Claude Code, Codex, Cursor, Kimi Code, Z.ai, and Grok Build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.source == .cpa,
               viewModel.hasAntigravityAccounts || !viewModel.hiddenAntigravityPoolIDs.isEmpty {
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

            if viewModel.source == .direct {
                directActionControls(for: provider)
            }

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

    @ViewBuilder
    private func directActionControls(for provider: DisplayProvider) -> some View {
        switch provider {
        case .claude:
            if viewModel.hasClaudeCredentials {
                if viewModel.claudeError != nil {
                    Button("Set Up…") {
                        navigation.activeSetupSheet = .claude
                    }
                    .controlSize(.small)
                }
                Button("Sign Out") {
                    viewModel.clearClaudeCredentials()
                }
                .controlSize(.small)
            } else {
                Button("Set Up…") {
                    navigation.activeSetupSheet = .claude
                }
                .controlSize(.small)
            }
        case .codex:
            if viewModel.hasCodexCredentials {
                Button("Sign Out") {
                    viewModel.clearCodexCredentials()
                }
                .controlSize(.small)
            } else {
                Button("Set Up…") {
                    navigation.activeSetupSheet = .codex
                }
                .controlSize(.small)
            }
        case .kimi:
            if viewModel.hasSavedKimiCredential {
                Button("Forget Key") {
                    viewModel.clearKimiCredential()
                }
                .controlSize(.small)
            } else if !viewModel.hasKimiCredentials {
                Button("Set Up…") {
                    navigation.activeSetupSheet = .kimi
                }
                .controlSize(.small)
            }
        case .antigravity, .cursor, .zai, .xai:
            EmptyView()
        }
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
        if viewModel.source == .cpa {
            let accounts = viewModel.cpaAccounts.filter { $0.provider == provider }
            guard !accounts.isEmpty else { return "No accounts in CPA" }
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

        let isAvailable = viewModel.availableProviders.contains(provider)
        guard isAvailable else {
            switch provider {
            case .claude: return "Not signed in — run `claude` in Terminal or set up manually"
            case .codex: return "Not signed in — run `codex login` in Terminal"
            case .kimi: return "Not configured — run `kimi login` or paste a credential"
            case .cursor, .zai, .xai: return "Not detected on this Mac"
            case .antigravity: return "CLIProxyAPI only"
            }
        }

        let freshness = viewModel.freshnessText(for: provider)
        switch provider {
        case .claude:
            let auth: String = switch viewModel.claudeAuthSource {
            case .oauth: "OAuth"
            case .webSession: "Browser session"
            case .none: "Connected"
            }
            return "\(auth) · \(freshness)"
        case .codex:
            return "CLI · \(freshness)"
        case .kimi:
            let auth = viewModel.kimiAuthSource.displayName
            return auth.isEmpty ? freshness : "\(auth) · \(freshness)"
        case .cursor, .zai, .xai, .antigravity:
            return "Detected · \(freshness)"
        }
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

// MARK: - Provider Setup Sheets

private struct ClaudeSetupSheet: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var navigation: SettingsNavigationModel
    @Environment(\.dismiss) private var dismiss

    @State private var organizationId = ""
    @State private var sessionKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Claude")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended: Claude Code CLI")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Open Terminal, run `claude`, and log in when prompted. Then click Refresh in Usagebar. Re-logging in from Terminal also fixes expired sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh Credentials") {
                    navigation.onRefresh()
                    dismiss()
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Manual Browser Session (Advanced)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization ID")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("From URL: claude.ai/chat → copy UUID after /organizations/")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("263e9fcb-52b9-4372-8842-…", text: $organizationId)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Key")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("From DevTools → Application → Cookies → sessionKey")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    PasswordField(prompt: "sk-ant-sid01-…", text: $sessionKey)
                }

                Text("Credentials are encrypted locally on this Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    viewModel.saveCredentials(
                        sessionKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                        organizationId: organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    organizationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            let existing = await navigation.loadClaudeCredentials()
            if sessionKey.isEmpty { sessionKey = existing.sessionKey }
            if organizationId.isEmpty { organizationId = existing.organizationId }
        }
    }
}

private struct CodexSetupSheet: View {
    @ObservedObject var navigation: SettingsNavigationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Codex")
                .font(.headline)

            Text("Run `codex login` in Terminal, then click Refresh in Usagebar. Usagebar reads Codex CLI's local credentials without modifying them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Refresh Now") {
                    navigation.onRefresh()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct KimiSetupSheet: View {
    @ObservedObject var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var credential = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up KimiCode")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended: Kimi Code CLI")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Run `kimi login` in Terminal, then click Refresh in Usagebar. Usagebar reads Kimi Code CLI's local OAuth credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open KimiCode Console") {
                    if let url = URL(string: "https://www.kimi.com/code/console") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key or Web Token")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Paste a Kimi Code API key or the `kimi-auth` token from the Kimi Code console. It is encrypted locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PasswordField(prompt: "API key or kimi-auth token", text: $credential)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.saveKimiCredential(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Data Source

private struct DataSourceSettingsPane: View {
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
            Section("Source Mode") {
                HStack(spacing: 10) {
                    SourceOptionCard(
                        title: "Direct",
                        subtitle: "Read local CLI & saved credentials on this Mac",
                        selected: viewModel.source == .direct
                    ) {
                        guard viewModel.source != .direct else { return }
                        run {
                            await viewModel.useDirectSource()
                            statusMessage = "Switched to Direct source."
                            statusIsError = false
                        }
                    }

                    SourceOptionCard(
                        title: "CLIProxyAPI",
                        subtitle: "Query accounts through a CPA management server",
                        selected: viewModel.source == .cpa
                    ) {
                        guard viewModel.source != .cpa else { return }
                        if !trimmedAddress.isEmpty && !trimmedKey.isEmpty {
                            run {
                                try await viewModel.testAndEnableCPA(address: trimmedAddress, key: trimmedKey)
                                hasSavedCPA = true
                                statusMessage = "CLIProxyAPI connection enabled."
                                statusIsError = false
                            }
                        } else if hasSavedCPA {
                            run {
                                try await viewModel.useSavedCPA()
                                statusMessage = "CLIProxyAPI connection enabled."
                                statusIsError = false
                            }
                        } else {
                            statusMessage = "Enter a CPA base address and management key below, then click Test & Enable."
                            statusIsError = false
                        }
                    }
                }
                .padding(.vertical, 2)
            }

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
                    } else if viewModel.source == .cpa {
                        let count = viewModel.cpaAccounts.count
                        Text("Connected · \(count) \(count == 1 ? "account" : "accounts") discovered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if hasSavedCPA {
                        Text("Saved CPA configuration is kept while using Direct.")
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
                    .disabled(!hasSavedCPA && trimmedAddress.isEmpty && trimmedKey.isEmpty)

                    Button("Test & Enable") {
                        run {
                            try await viewModel.testAndEnableCPA(address: trimmedAddress, key: trimmedKey)
                            hasSavedCPA = true
                            statusMessage = "Connection verified and enabled."
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

private struct SourceOptionCard: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
