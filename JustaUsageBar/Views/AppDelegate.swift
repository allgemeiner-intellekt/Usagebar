//
//  AppDelegate.swift
//  JustaUsageBar
//

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    nonisolated private static let lastLaunchedAppDescriptorDefaultsKey = "lastLaunchedAppDescriptor"
    nonisolated private static let lastUpdateCheckAtDefaultsKey = "lastUpdateCheckAt"
    nonisolated private static let lastInstalledUpdateAtDefaultsKey = "lastInstalledUpdateAt"
    nonisolated private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/allgemeiner-intellekt/Usagebar/releases/latest")!
    nonisolated private static let repositoryURL = URL(string: "https://github.com/allgemeiner-intellekt/Usagebar")!
    // Personal builds are replaced manually from the fork's Actions artifacts.
    nonisolated private static let manualUpdatesOnly = true
    nonisolated private static let personalBuildsURL = URL(string: "https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml")!
    nonisolated private static let updateFailureFileName = "update-failure.txt"

    private var statusItem: NSStatusItem!
    private let panelModel = UsagePanelModel()
    private let globalHotkeyManager = GlobalHotkeyManager()
    private var previousAppBeforeHotkeyPanel: NSRunningApplication?
    private lazy var panel: UsagePanel = {
        let panel = UsagePanel(rootView: UsagePanelView(model: panelModel))
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.isPanelOpen = false
            if let previousApp = self.previousAppBeforeHotkeyPanel {
                self.previousAppBeforeHotkeyPanel = nil
                previousApp.activate()
            }
        }
        panel.onOutsideClick = { [weak self] in
            self?.previousAppBeforeHotkeyPanel = nil
        }
        panel.onOpenSettings = { [weak self] in
            self?.previousAppBeforeHotkeyPanel = nil
            self?.showSettings()
        }
        panel.onRefresh = { [weak self] in
            self?.panelModel.isRefreshing = true
            self?.refreshData()
        }
        panel.onQuit = { NSApp.terminate(nil) }
        return panel
    }()
    /// While the panel or settings window is open every provider refreshes at the on-screen rate.
    private var isPanelOpen = false {
        didSet { viewModel.usageVisibilityChanged(isVisible: isPanelOpen || isSettingsOpen) }
    }
    private var isSettingsOpen = false {
        didSet { viewModel.usageVisibilityChanged(isVisible: isPanelOpen || isSettingsOpen) }
    }
    private let viewModel: UsageViewModel

    override convenience init() {
        self.init(viewModel: .shared)
    }

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    private let settingsNavigation = SettingsNavigationModel()
    private var settingsWindow: NSWindow?

    // Update availability state
    private var availableUpdateVersion: String? {
        didSet { settingsNavigation.availableUpdateVersion = availableUpdateVersion }
    }
    private var lastReleaseCheckAt: Date?
    private var isUpdateRunning = false
    nonisolated private static let releaseCheckInterval: TimeInterval = 6 * 3600
    nonisolated private static let lastAutoUpdateVersionDefaultsKey = "lastAutoUpdateAttemptedVersion"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.hasAnotherRunningInstance else {
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        configureSettingsNavigation()
        setupGlobalHotkey()
        observeChanges()
        recordInstalledAppVersionIfNeeded()

        NSApp.setActivationPolicy(.accessory)
        presentPendingUpdateFailureIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotkeyManager.unregister()
    }

    private func setupGlobalHotkey() {
        globalHotkeyManager.onTrigger = { [weak self] in
            self?.togglePanel(activatedByHotkey: true)
        }
        if let saved = viewModel.globalHotkey {
            if globalHotkeyManager.register(saved) {
                settingsNavigation.globalHotkeyError = nil
            } else {
                settingsNavigation.globalHotkeyError = "Could not register \(saved.displayString). It may already be in use."
            }
        }
    }

    private func applyGlobalHotkey(_ hotkey: GlobalHotkey?) {
        guard let hotkey else {
            globalHotkeyManager.unregister()
            viewModel.setGlobalHotkey(nil)
            settingsNavigation.globalHotkeyError = nil
            return
        }

        if let validationError = hotkey.validate() {
            settingsNavigation.globalHotkeyError = validationError.localizedDescription
            if let existing = viewModel.globalHotkey {
                _ = globalHotkeyManager.register(existing)
            }
            return
        }

        if globalHotkeyManager.register(hotkey) {
            viewModel.setGlobalHotkey(hotkey)
            settingsNavigation.globalHotkeyError = nil
        } else {
            if let existing = viewModel.globalHotkey {
                _ = globalHotkeyManager.register(existing)
            }
            settingsNavigation.globalHotkeyError = "Could not register \(hotkey.displayString). It may already be in use."
        }
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: NSNotification.Name("SettingsChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDataChanged),
            name: NSNotification.Name("UsageDataChanged"),
            object: nil
        )
    }

    @objc private func settingsChanged() {
        viewModel.providerSettingsChanged()
        updatePanel()
    }

    @objc private func usageDataChanged() {
        updatePanel()
        maybeCheckForUpdateInBackground()
    }

    // MARK: - Background Update Check

    /// Piggybacks on the regular refresh cycle: at most one release lookup
    /// every `releaseCheckInterval`, a single HTTPS request, no timers.
    private func maybeCheckForUpdateInBackground() {
        guard !Self.manualUpdatesOnly else { return }
        let last = lastReleaseCheckAt
            ?? UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtDefaultsKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.releaseCheckInterval {
            return
        }
        lastReleaseCheckAt = Date()

        Task { [weak self] in
            guard let release = try? await Self.fetchLatestRelease() else { return }
            self?.handleDiscoveredRelease(release)
        }
    }

    private func handleDiscoveredRelease(_ release: ReleaseInfo) {
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckAtDefaultsKey)

        let installedVersion = Self.installedAppInfo().version
        guard release.version.compare(installedVersion, options: .numeric) == .orderedDescending else {
            if availableUpdateVersion != nil {
                availableUpdateVersion = nil
                updatePanel()
            }
            return
        }

        let isNewDiscovery = availableUpdateVersion != release.version
        availableUpdateVersion = release.version
        if isNewDiscovery {
            updatePanel()

            let defaults = UserDefaults.standard
            let lastAttempted = defaults.string(forKey: Self.lastAutoUpdateVersionDefaultsKey)
            if viewModel.autoUpdate && lastAttempted != release.version {
                defaults.set(release.version, forKey: Self.lastAutoUpdateVersionDefaultsKey)
                runUpdate(interactive: false)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Usagebar")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Usagebar")
            button.toolTip = "Usagebar"
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: - Usage Panel

    private func togglePanel(activatedByHotkey: Bool = false) {
        if panel.isVisible {
            panel.close()
            return
        }
        guard let button = statusItem.button else { return }
        if activatedByHotkey {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousAppBeforeHotkeyPanel = (frontmost != NSRunningApplication.current) ? frontmost : nil
            NSApp.activate(ignoringOtherApps: true)
        } else {
            previousAppBeforeHotkeyPanel = nil
        }
        configurePanelActions()
        isPanelOpen = true
        updatePanel()
        panel.show(below: button)
    }

    /// Fills the panel from the normalized usage models while it is open.
    private func updatePanel() {
        guard isPanelOpen else { return }
        panelModel.maximumContentHeight = max(100, (statusItem.button?.window?.screen?.visibleFrame.height ?? 768) - 120)
        panelModel.needsSetup = viewModel.source == .direct && !viewModel.hasCredentials
        panelModel.emptyMessage = viewModel.source == .cpa ? (viewModel.cpaError ?? (viewModel.cpaAccounts.isEmpty ? "No supported accounts. Add accounts in CPA, then refresh." : nil)) : nil
        panelModel.cards = panelCards()
        panelModel.updateVersion = availableUpdateVersion
        panelModel.isRefreshing = viewModel.isLoading
        panelModel.updatedText = updatedText(viewModel.lastUpdated)
    }

    private func updatedText(_ date: Date?) -> String {
        guard let date else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes)m ago"
    }

    private func panelCards() -> [UsagePanelCard] {
        if viewModel.source == .cpa {
            return DisplayProvider.displayOrder.compactMap { provider in
                let shown: Bool = switch provider {
                case .claude: viewModel.showClaude
                case .codex: viewModel.showCodex
                case .antigravity: viewModel.showAntigravity
                case .cursor: viewModel.showCursor
                case .kimi: viewModel.showKimi
                case .zai: viewModel.showZai
                case .xai: viewModel.showXai
                }
                let accounts = viewModel.cpaAccounts.filter { $0.provider == provider }
                guard shown, !accounts.isEmpty else { return nil }
                let hiddenPoolIDs = provider == .antigravity ? viewModel.hiddenAntigravityPoolIDs : []
                if accounts.count == 1, let account = accounts.first {
                    let allPools = account.reading?.poolGroups ?? []
                    let visiblePools = allPools.filter { !hiddenPoolIDs.contains($0.id) }.map { group in
                        UsagePanelPoolGroup(
                            id: group.id,
                            label: group.label,
                            description: group.description,
                            rows: group.windows.map {
                                UsagePanelRow(id: $0.id, label: $0.label, percent: $0.percent, resetText: $0.resetText,
                                              dimmed: $0.blockedByOuterLimit, helpText: $0.detail)
                            }
                        )
                    }
                    return UsagePanelCard(provider: provider, detail: account.reading?.plan ?? "", rows: (account.reading?.windows ?? []).map {
                        UsagePanelRow(id: $0.id, label: $0.label, percent: $0.percent, resetText: $0.resetText,
                                      dimmed: $0.blockedByOuterLimit, helpText: $0.detail)
                    }, poolGroups: visiblePools, message: cpaAccountMessage(account),
                    hiddenPoolIDs: hiddenPoolIDs, allPoolsHidden: !allPools.isEmpty && visiblePools.isEmpty,
                    bankedResets: account.reading?.bankedResets,
                    tracksBankedResets: account.provider == .codex || account.provider == .claude)
                }
                return UsagePanelCard(provider: provider, detail: "", rows: [], accounts: accounts, hiddenPoolIDs: hiddenPoolIDs)
            }
        }
        var cards: [UsagePanelCard] = []

        if viewModel.showClaude {
            let usage = viewModel.usageData
            let detail = usage.planName
            if viewModel.hasClaudeCredentials {
                var rows = [
                    UsagePanelRow(label: "5h", percent: usage.fiveHourUsed, resetText: usage.timeUntilFiveHourReset),
                    UsagePanelRow(label: "7d", percent: usage.weeklyUsed, resetText: usage.timeUntilWeeklyReset)
                ]
                if usage.hasFableData {
                    rows.append(UsagePanelRow(label: "Fable", percent: usage.fableUsed ?? 0, resetText: usage.timeUntilFableReset))
                }
                let error = viewModel.claudeError
                cards.append(UsagePanelCard(
                    provider: .claude, detail: detail, rows: rows, message: error,
                    actionTitle: error != nil && shouldPromptClaudeAuthentication ? "How to authenticate Claude" : nil
                ))
            } else {
                cards.append(UsagePanelCard(
                    provider: .claude, detail: detail, rows: [],
                    message: "Not authenticated", actionTitle: "How to authenticate Claude"
                ))
            }
        }

        if viewModel.showCodex {
            let codex = viewModel.codexUsageData
            let detail = PlanNames.codex(codex.planType)
            if viewModel.hasCodexCredentials {
                var rows = [UsagePanelRow(
                    label: codex.primaryIsWeekly ? "7d" : codex.primaryWindowLabel,
                    percent: codex.primaryUsedPercent,
                    resetText: codex.timeUntilPrimaryReset
                )]
                if !codex.primaryIsWeekly, codex.secondaryUsedPercent > 0 || codex.secondaryResetAt != nil {
                    rows.append(UsagePanelRow(label: "7d", percent: codex.secondaryUsedPercent, resetText: codex.timeUntilSecondaryReset))
                }
                let error = viewModel.codexError
                cards.append(UsagePanelCard(
                    provider: .codex, detail: detail, rows: rows, message: error,
                    actionTitle: error != nil && shouldPromptCodexAuthentication ? "How to authenticate Codex" : nil,
                    bankedResets: codex.bankedResets,
                    tracksBankedResets: true
                ))
            } else {
                cards.append(UsagePanelCard(
                    provider: .codex, detail: detail, rows: [],
                    message: "Not authenticated", actionTitle: "How to authenticate Codex"
                ))
            }
        }

        if viewModel.hasCursorCredentials && viewModel.showCursor {
            let cursor = viewModel.cursorUsageData
            cards.append(UsagePanelCard(
                provider: .cursor,
                detail: cursor.planName != "unknown" ? cursor.planName.capitalized : "",
                rows: [UsagePanelRow(label: cursor.windowLabel, percent: cursor.usedPercent, resetText: cursor.timeUntilReset)],
                message: viewModel.cursorError
            ))
        }

        if viewModel.hasKimiCredentials && viewModel.showKimi {
            let kimi = viewModel.kimiUsageData
            var rows: [UsagePanelRow] = []
            if let fiveHour = kimi.fiveHourUsedPercent {
                rows.append(UsagePanelRow(label: "5h", percent: fiveHour, resetText: kimi.timeUntilFiveHourReset))
            }
            rows.append(UsagePanelRow(label: "7d", percent: kimi.weeklyUsedPercent, resetText: kimi.timeUntilWeeklyReset))
            let error = viewModel.kimiError
            cards.append(UsagePanelCard(
                provider: .kimi, detail: "", rows: rows,
                message: error, actionTitle: error != nil ? "Kimi Code Setup…" : nil
            ))
        }

        if viewModel.hasZaiCredentials && viewModel.showZai {
            let zai = viewModel.zaiUsageData
            cards.append(UsagePanelCard(
                provider: .zai,
                detail: zai.planName != "unknown" ? zai.planName.capitalized : "",
                rows: [UsagePanelRow(label: zai.windowLabel, percent: zai.usedPercent, resetText: zai.timeUntilReset)],
                message: viewModel.zaiError
            ))
        }

        if viewModel.hasXaiCredentials && viewModel.showXai {
            let xai = viewModel.xaiUsageData
            cards.append(UsagePanelCard(
                provider: .xai,
                detail: xai.planName != "unknown" ? xai.planName : "",
                rows: [UsagePanelRow(label: "7d", percent: xai.primaryUsedPercent, resetText: xai.timeUntilWeeklyReset)],
                message: viewModel.xaiError
            ))
        }
        return cards
    }

    private func configurePanelActions() {
        panelModel.onResize = { [weak self] in
            DispatchQueue.main.async { self?.panel.fitContent() }
        }
        panelModel.onAction = { [weak self] provider in
            switch provider {
            case .claude: self?.showSettings(section: .providers, setupSheet: .claude)
            case .codex: self?.showSettings(section: .providers, setupSheet: .codex)
            case .kimi: self?.showSettings(section: .providers, setupSheet: .kimi)
            case .antigravity, .cursor, .zai, .xai: break
            }
        }
        panelModel.onRefresh = { [weak self] in
            self?.panelModel.isRefreshing = true
            self?.refreshData()
        }
        panelModel.onSettings = { [weak self] in
            self?.showSettings()
        }
        panelModel.onUpdate = { [weak self] in self?.checkForUpdates() }
        panelModel.onSetup = { [weak self] in
            self?.showSettings(section: .providers)
        }
        panelModel.onSetUpKimi = { [weak self] in
            self?.showSettings(section: .providers, setupSheet: .kimi)
        }
        panelModel.onQuit = { NSApp.terminate(nil) }
    }

    private func configureSettingsNavigation() {
        let info = Self.installedAppInfo()
        settingsNavigation.installedVersion = info.version
        settingsNavigation.installedBuild = info.build
        settingsNavigation.availableUpdateVersion = availableUpdateVersion
        settingsNavigation.onRefresh = { [weak self] in self?.refreshData() }
        settingsNavigation.onOpenGitHub = { [weak self] in self?.openGitHubRepository() }
        settingsNavigation.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        settingsNavigation.onGlobalHotkeyChange = { [weak self] hotkey in self?.applyGlobalHotkey(hotkey) }
        settingsNavigation.onGlobalHotkeyRecordingChanged = { [weak self] recording in
            self?.globalHotkeyManager.setSuspended(recording)
        }
    }

    @objc private func statusBarButtonClicked() {
        togglePanel()
    }

    func showSettings(section: SettingsSection? = nil, setupSheet: ProviderSetupSheet? = nil) {
        previousAppBeforeHotkeyPanel = nil
        if panel.isVisible {
            panel.close()
        }
        configureSettingsNavigation()
        if let section {
            settingsNavigation.selectedSection = section
        }
        settingsNavigation.activeSetupSheet = setupSheet

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Usagebar Settings"
            window.minSize = NSSize(width: 580, height: 400)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: SettingsView(viewModel: viewModel, navigation: settingsNavigation)
            )
            window.center()
            settingsWindow = window
        }

        isSettingsOpen = true
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true {
            settingsWindow?.deminiaturize(nil)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        isSettingsOpen = false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        isSettingsOpen = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        isSettingsOpen = true
    }

    @objc private func refreshData() {
        Task {
            await viewModel.rediscoverCredentialsAndRefresh()
        }
    }

    @objc private func checkForUpdates() {
        runUpdate(interactive: true)
    }

    private func runUpdate(interactive: Bool) {
        guard !Self.manualUpdatesOnly else {
            if interactive {
                NSWorkspace.shared.open(Self.personalBuildsURL)
            }
            return
        }
        guard !isUpdateRunning else { return }
        isUpdateRunning = true

        let appURL = Bundle.main.bundleURL

        Task {
            let updateResult = await Task.detached(priority: .userInitiated) {
                await Self.performUpdateCheck()
            }.value

            isUpdateRunning = false
            persistUpdateCheckMetadata(from: updateResult)

            switch updateResult {
            case .readyToInstall(_, let brewURL, let caskToken):
                installPreparedUpdate(
                    brewURL: brewURL,
                    caskToken: caskToken,
                    appURL: appURL,
                    interactive: interactive
                )
            case .alreadyUpToDate(let status):
                availableUpdateVersion = nil
                updatePanel()
                if interactive {
                    presentAlert(
                        title: "Already up to date",
                        message: alreadyUpToDateMessage(for: status),
                        style: .informational
                    )
                }
            case .stillRollingOut(let status):
                // The release exists but the Homebrew tap hasn't synced yet.
                // Not a failure: keep the update badge and retry on a later
                // background check.
                UserDefaults.standard.removeObject(forKey: Self.lastAutoUpdateVersionDefaultsKey)
                // Allow the next background check (and auto-retry) in ~10 minutes.
                lastReleaseCheckAt = Date().addingTimeInterval(-Self.releaseCheckInterval + 600)
                updatePanel()
                if interactive {
                    let version = status.latestRelease?.version ?? "the new version"
                    presentAlert(
                        title: "Update on its way",
                        message: "Usagebar \(version) was just published and is still rolling out. It will install automatically in a bit - nothing to do.",
                        style: .informational
                    )
                }
            case .failed(let status, let message):
                updatePanel()
                if interactive {
                    presentAlert(
                        title: "Update failed",
                        message: failureMessage(message, status: status),
                        style: .warning
                    )
                }
            }
        }
    }

    @objc private func openGitHubRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    private func installPreparedUpdate(
        brewURL: URL,
        caskToken: String,
        appURL: URL,
        interactive: Bool
    ) {
        guard let helperURL = Bundle.main.url(
            forResource: "install_update_and_relaunch",
            withExtension: "sh"
        ) else {
            handleUpdateHandoffFailure("The bundled update helper is missing.", interactive: interactive)
            return
        }

        let failureURL = Self.updateFailureURL
        do {
            try FileManager.default.createDirectory(
                at: failureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: failureURL)
            try? FileManager.default.removeItem(at: Self.updateLogURL)
        } catch {
            handleUpdateHandoffFailure(error.localizedDescription, interactive: interactive)
            return
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            helperURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            brewURL.path,
            caskToken,
            appURL.path,
            failureURL.path,
            interactive ? "failure-interactive" : "failure-background"
        ]

        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            handleUpdateHandoffFailure(error.localizedDescription, interactive: interactive)
        }
    }

    private func handleUpdateHandoffFailure(_ detail: String, interactive: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.lastAutoUpdateVersionDefaultsKey)
        guard interactive else { return }

        presentAlert(
            title: "Update failed",
            message: "Usagebar could not start the update helper.\n\(detail)",
            style: .warning
        )
    }

    private func presentPendingUpdateFailureIfNeeded() {
        let failureURL = Self.updateFailureURL
        try? FileManager.default.removeItem(at: Self.updateLogURL)
        guard let result = try? String(contentsOf: failureURL, encoding: .utf8) else {
            return
        }
        try? FileManager.default.removeItem(at: failureURL)

        var lines = result.components(separatedBy: .newlines)
        let failureKind = lines.isEmpty ? "" : lines.removeFirst()
        let detail = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if failureKind == "failure-background" {
            UserDefaults.standard.removeObject(forKey: Self.lastAutoUpdateVersionDefaultsKey)
            return
        }
        guard failureKind == "failure-interactive" else { return }

        NSApp.activate(ignoringOtherApps: true)
        presentAlert(
            title: "Update failed",
            message: detail.isEmpty ? "Homebrew could not install the update." : detail,
            style: .warning
        )
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private var installedAppDescriptor: String {
        let appInfo = Self.installedAppInfo()
        return "\(appInfo.version) (\(appInfo.build))"
    }

    private var installedAppUpdatedAt: Date? {
        Self.installedAppInfo().updatedAt
    }

    private var lastUpdateCheckAt: Date? {
        UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtDefaultsKey) as? Date
    }

    private func recordInstalledAppVersionIfNeeded() {
        let defaults = UserDefaults.standard
        let currentDescriptor = installedAppDescriptor
        let previousDescriptor = defaults.string(forKey: Self.lastLaunchedAppDescriptorDefaultsKey)

        guard previousDescriptor != currentDescriptor else {
            return
        }

        defaults.set(currentDescriptor, forKey: Self.lastLaunchedAppDescriptorDefaultsKey)
        defaults.set(Date(), forKey: Self.lastInstalledUpdateAtDefaultsKey)
    }

    private func persistUpdateCheckMetadata(from result: UpdateResult) {
        UserDefaults.standard.set(result.status.checkedAt, forKey: Self.lastUpdateCheckAtDefaultsKey)
    }

    private func alreadyUpToDateMessage(for status: UpdateStatus) -> String {
        var lines = [
            "Installed: Usagebar \(status.installedApp.version) (\(status.installedApp.build))"
        ]

        if let latestRelease = status.latestRelease {
            var latestLine = "Latest release: \(latestRelease.version)"
            if let publishedAt = latestRelease.publishedAt {
                latestLine += " • \(formatAlertTimestamp(publishedAt))"
            }
            lines.append(latestLine)
        } else {
            lines.append("Latest release: unavailable right now")
        }

        if let updatedAt = status.installedApp.updatedAt {
            lines.append("Updated: \(formatAlertTimestamp(updatedAt))")
        }

        lines.append("Checked: \(formatAlertTimestamp(status.checkedAt))")
        return lines.joined(separator: "\n")
    }

    private func failureMessage(_ message: String, status: UpdateStatus) -> String {
        "\(message)\n\n\(alreadyUpToDateMessage(for: status))"
    }

    private func formatAlertTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private enum UpdateResult {
        case readyToInstall(UpdateStatus, URL, String)
        case alreadyUpToDate(UpdateStatus)
        case stillRollingOut(UpdateStatus)
        case failed(UpdateStatus, String)

        var status: UpdateStatus {
            switch self {
            case .readyToInstall(let status, _, _),
                 .alreadyUpToDate(let status),
                 .stillRollingOut(let status),
                 .failed(let status, _):
                return status
            }
        }
    }

    private struct InstalledAppInfo {
        let version: String
        let build: String
        let updatedAt: Date?
    }

    private struct ReleaseInfo {
        let version: String
        let publishedAt: Date?
    }

    private struct UpdateStatus {
        let installedApp: InstalledAppInfo
        let latestRelease: ReleaseInfo?
        let checkedAt: Date
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    nonisolated private static let preferredCaskTokens = ["usagebar", "justausagebar"]

    nonisolated private static func performUpdateCheck() async -> UpdateResult {
        let status = UpdateStatus(
            installedApp: installedAppInfo(),
            latestRelease: try? await fetchLatestRelease(),
            checkedAt: Date()
        )

        if let latestRelease = status.latestRelease,
           latestRelease.version.compare(status.installedApp.version, options: .numeric) != .orderedDescending {
            return .alreadyUpToDate(status)
        }

        return prepareHomebrewUpdate(status: status)
    }

    nonisolated private static func prepareHomebrewUpdate(status: UpdateStatus) -> UpdateResult {
        guard let brewURL = brewExecutableURL() else {
            return .failed(status, """
            Homebrew was not found. Run in Terminal:
            brew update && brew upgrade --cask usagebar
            """)
        }

        do {
            let update = try runCommand(executableURL: brewURL, arguments: ["update", "--quiet"])
            guard update.status == 0 else {
                return .failed(status, """
                Homebrew update failed.
                \(summarizeCommandOutput(update.output))
                """)
            }

            guard let installedCaskToken = try installedCaskToken(brewURL: brewURL) else {
                return .failed(status, """
                This copy of Usagebar is not managed by Homebrew cask.
                Reinstall it with:
                brew install --cask betoxf/tap/usagebar
                """)
            }

            let outdated = try runCommand(
                executableURL: brewURL,
                arguments: ["outdated", "--cask", installedCaskToken],
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]
            )

            // Homebrew returns exit code 1 when `outdated` finds matching entries.
            guard outdated.status == 0 || outdated.status == 1 else {
                return .failed(status, """
                Could not check for updates.
                \(summarizeCommandOutput(outdated.output))
                """)
            }

            let isOutdated = outdated.output
                .split(whereSeparator: \.isNewline)
                .contains { line in
                    line.trimmingCharacters(in: .whitespacesAndNewlines) == installedCaskToken
                }

            guard isOutdated else {
                if let latestRelease = status.latestRelease,
                   latestRelease.version.compare(status.installedApp.version, options: .numeric) == .orderedDescending {
                    return .stillRollingOut(status)
                }
                return .alreadyUpToDate(status)
            }

            return .readyToInstall(status, brewURL, installedCaskToken)
        } catch {
            return .failed(status, """
            Homebrew update failed.
            \(error.localizedDescription)
            """)
        }
    }

    nonisolated private static func installedCaskToken(brewURL: URL) throws -> String? {
        for token in preferredCaskTokens {
            let result = try runCommand(
                executableURL: brewURL,
                arguments: ["list", "--cask", token]
            )
            if result.status == 0 {
                return token
            }
        }
        return nil
    }

    nonisolated private static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Usagebar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await ProviderHTTP.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String
        else {
            throw URLError(.cannotParseResponse)
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let publishedAt: Date?

        if let publishedAtString = json["published_at"] as? String {
            publishedAt = ISO8601DateFormatter().date(from: publishedAtString)
        } else {
            publishedAt = nil
        }

        return ReleaseInfo(version: version, publishedAt: publishedAt)
    }

    nonisolated private static func installedAppInfo() -> InstalledAppInfo {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let version = infoDictionary["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = infoDictionary["CFBundleVersion"] as? String ?? "?"
        let storedUpdatedAt = UserDefaults.standard.object(forKey: lastInstalledUpdateAtDefaultsKey) as? Date
        let bundleResourceValues = try? Bundle.main.bundleURL.resourceValues(forKeys: [.contentModificationDateKey])
        let bundleUpdatedAt = bundleResourceValues?.contentModificationDate

        return InstalledAppInfo(
            version: version,
            build: build,
            updatedAt: storedUpdatedAt ?? bundleUpdatedAt
        )
    }

    nonisolated private static var hasAnotherRunningInstance: Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { application in
                application.processIdentifier != currentPID && !application.isTerminated
            }
    }

    nonisolated private static var updateFailureURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustaUsageBar", isDirectory: true)
            .appendingPathComponent(updateFailureFileName)
    }

    nonisolated private static var updateLogURL: URL {
        URL(fileURLWithPath: updateFailureURL.path + ".log")
    }

    nonisolated private static func brewExecutableURL() -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]

        let fileManager = FileManager.default

        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    nonisolated private static func runCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }

    nonisolated private static func summarizeCommandOutput(_ output: String) -> String {
        let trimmedLines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedLines.isEmpty else {
            return "No additional details were returned by Homebrew."
        }

        return trimmedLines.prefix(6).joined(separator: "\n")
    }

    // MARK: - Helpers

    private var shouldPromptClaudeAuthentication: Bool {
        !viewModel.hasClaudeCredentials || viewModel.claudeError != nil
    }

    private var shouldPromptCodexAuthentication: Bool {
        !viewModel.hasCodexCredentials || viewModel.codexError == APIError.unauthorized.errorDescription
    }
}
