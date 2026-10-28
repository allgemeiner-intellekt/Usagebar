//
//  AppDelegate.swift
//  JustaUsageBar
//

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var menu: NSMenu!
    private var isMenuOpen = false {
        didSet { viewModel.usageVisibilityChanged(isVisible: isMenuOpen || isPanelOpen) }
    }
    private let panelModel = UsagePanelModel()
    private lazy var panel: UsagePanel = {
        let panel = UsagePanel(rootView: UsagePanelView(model: panelModel))
        panel.onClose = { [weak self] in self?.isPanelOpen = false }
        return panel
    }()
    /// While the panel is open every provider refreshes at the on-screen rate.
    private var isPanelOpen = false {
        didSet { viewModel.usageVisibilityChanged(isVisible: isMenuOpen || isPanelOpen) }
    }
    private let viewModel: UsageViewModel

    override convenience init() {
        self.init(viewModel: .shared)
    }

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    private var credentialsWindow: NSWindow?

    // Update availability state
    private var availableUpdateVersion: String?
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
        setupMenu()
        observeChanges()
        recordInstalledAppVersionIfNeeded()

        NSApp.setActivationPolicy(.accessory)
        presentPendingUpdateFailureIfNeeded()
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
        rebuildMenu()
    }

    @objc private func usageDataChanged() {
        rebuildMenu()
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
                rebuildMenu()
            }
            return
        }

        let isNewDiscovery = availableUpdateVersion != release.version
        availableUpdateVersion = release.version
        if isNewDiscovery {
            rebuildMenu()

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

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self
        // Don't set statusItem.menu - we handle clicks manually
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !isMenuOpen else { return }
        isMenuOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func rebuildMenu() {
        updatePanel()
        // Countdown labels are recomputed on open. Closed menus need no work,
        // and replacing the items would close a submenu the pointer is in.
        guard isMenuOpen, menu.highlightedItem?.submenu == nil else { return }
        menu.removeAllItems()

        let hasClaude = viewModel.hasClaudeCredentials
        let hasCodex = viewModel.hasCodexCredentials
        let hasCursor = viewModel.hasCursorCredentials
        let hasZai = viewModel.hasZaiCredentials
        let hasXai = viewModel.hasXaiCredentials
        let hasKimi = viewModel.hasKimiCredentials

        if !hasClaude && !hasCodex && !hasCursor && !hasZai && !hasXai && !hasKimi {
            let setupItem = NSMenuItem(title: "Setup Usage Tracking", action: #selector(showCredentialsWindow), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)

            let kimiSetupItem = NSMenuItem(title: "Set Up KimiCode…", action: #selector(authenticateKimi), keyEquivalent: "")
            kimiSetupItem.target = self
            menu.addItem(kimiSetupItem)
        } else {
            // Refresh
            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            let updatesMenu = NSMenu()
            for provider in DisplayProvider.displayOrder where viewModel.refreshTargets.contains(provider) {
                let title: String = switch provider {
                case .claude: "Claude"
                case .codex: "Codex"
                case .cursor: "Cursor"
                case .kimi: "KimiCode"
                case .zai: "z.ai"
                case .xai: "XAI"
                }
                let item = NSMenuItem(title: "\(title): \(viewModel.freshnessText(for: provider))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                updatesMenu.addItem(item)
            }
            let updatesItem = NSMenuItem(title: "Last Updates", action: nil, keyEquivalent: "")
            updatesItem.submenu = updatesMenu
            menu.addItem(updatesItem)

            // Display submenu
            let displayMenu = NSMenu()

            // Provider toggles
            let authedProviderCount = [hasClaude, hasCodex, hasCursor, hasKimi, hasZai, hasXai].filter { $0 }.count
            if authedProviderCount > 0 {
                if hasClaude {
                    let claudeToggle = NSMenuItem(title: "Show Claude", action: #selector(toggleShowClaude), keyEquivalent: "")
                    claudeToggle.target = self
                    claudeToggle.state = viewModel.showClaude ? .on : .off
                    displayMenu.addItem(claudeToggle)
                }

                if hasCodex {
                    let codexToggle = NSMenuItem(title: "Show Codex", action: #selector(toggleShowCodex), keyEquivalent: "")
                    codexToggle.target = self
                    codexToggle.state = viewModel.showCodex ? .on : .off
                    displayMenu.addItem(codexToggle)
                }

                if hasCursor {
                    let cursorToggle = NSMenuItem(title: "Show Cursor", action: #selector(toggleShowCursor), keyEquivalent: "")
                    cursorToggle.target = self
                    cursorToggle.state = viewModel.showCursor ? .on : .off
                    displayMenu.addItem(cursorToggle)
                }

                if hasKimi {
                    let kimiToggle = NSMenuItem(title: "Show KimiCode", action: #selector(toggleShowKimi), keyEquivalent: "")
                    kimiToggle.target = self
                    kimiToggle.state = viewModel.showKimi ? .on : .off
                    displayMenu.addItem(kimiToggle)
                }

                if hasZai {
                    let zaiToggle = NSMenuItem(title: "Show z.ai", action: #selector(toggleShowZai), keyEquivalent: "")
                    zaiToggle.target = self
                    zaiToggle.state = viewModel.showZai ? .on : .off
                    displayMenu.addItem(zaiToggle)
                }

                if hasXai {
                    let xaiToggle = NSMenuItem(title: "Show XAI", action: #selector(toggleShowXai), keyEquivalent: "")
                    xaiToggle.target = self
                    xaiToggle.state = viewModel.showXai ? .on : .off
                    displayMenu.addItem(xaiToggle)
                }
            }

            let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)

            // Launch at login
            let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchItem.target = self
            launchItem.state = viewModel.launchAtStartup ? .on : .off
            menu.addItem(launchItem)

            menu.addItem(NSMenuItem.separator())

            // Sign out options
            if hasClaude {
                let signOutClaude = NSMenuItem(title: "Sign Out Claude", action: #selector(signOutClaude), keyEquivalent: "")
                signOutClaude.target = self
                menu.addItem(signOutClaude)
            }

            if hasCodex {
                let signOutCodex = NSMenuItem(title: "Sign Out Codex", action: #selector(signOutCodex), keyEquivalent: "")
                signOutCodex.target = self
                menu.addItem(signOutCodex)
            }

            if viewModel.hasSavedKimiCredential {
                let forgetKimi = NSMenuItem(title: "Forget Saved KimiCode Credential", action: #selector(clearKimiCredential), keyEquivalent: "")
                forgetKimi.target = self
                menu.addItem(forgetKimi)
            } else if !hasKimi {
                let setupKimi = NSMenuItem(title: "Set Up KimiCode…", action: #selector(authenticateKimi), keyEquivalent: "")
                setupKimi.target = self
                menu.addItem(setupKimi)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let reviewRepoItem = NSMenuItem(title: "Review GitHub Repo", action: #selector(openGitHubRepository), keyEquivalent: "")
        reviewRepoItem.target = self
        if let githubMark = NSImage(named: "GitHubMark") {
            githubMark.size = NSSize(width: 14, height: 14)
            reviewRepoItem.image = githubMark
        }
        menu.addItem(reviewRepoItem)

        // Check for Updates / update available badge
        if let updateVersion = availableUpdateVersion {
            let updateItem = NSMenuItem(title: "Update to v\(updateVersion) (1)", action: #selector(checkForUpdates), keyEquivalent: "u")
            updateItem.target = self
            updateItem.attributedTitle = NSAttributedString(
                string: "Update to v\(updateVersion)  (1)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: brandClaudeColor
                ]
            )
            menu.addItem(updateItem)
        } else {
            let updateItem = NSMenuItem(title: "Download Personal Build…", action: #selector(checkForUpdates), keyEquivalent: "u")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Usage Panel

    private func togglePanel() {
        if panel.isVisible {
            panel.close()
            return
        }
        guard let button = statusItem.button else { return }
        configurePanelActions()
        isPanelOpen = true
        updatePanel()
        panel.show(below: button)
    }

    /// Fills the panel from the normalized usage models. Runs whenever the
    /// open menu would be rebuilt.
    private func updatePanel() {
        guard isPanelOpen else { return }
        panelModel.needsSetup = !viewModel.hasCredentials
        panelModel.cards = panelCards()
        panelModel.updateVersion = availableUpdateVersion
        panelModel.isRefreshing = viewModel.isLoading
        panelModel.updatedText = updatedText(viewModel.lastUpdated)
        if panelModel.cursorMarks == nil {
            panelModel.cursorMarks = cursorPlanMarksImage(height: 12)
            var transform = AffineTransform.identity
            transform.scale(10.6)
            let zMark = zcodeMarkPath()
            zMark.transform(using: transform)
            panelModel.zcodeMark = templateImage(size: NSSize(width: 1.13 * 10.6, height: 10.6), paths: [zMark])
        }
        DispatchQueue.main.async { [weak self] in self?.panel.fitContent() }
    }

    private func updatedText(_ date: Date?) -> String {
        guard let date else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes)m ago"
    }

    private func panelCards() -> [UsagePanelCard] {
        var cards: [UsagePanelCard] = []

        if viewModel.showClaude {
            let detail: String = switch viewModel.claudeAuthSource {
            case .oauth: "via OAuth"
            case .webSession: "via Browser"
            case .none: ""
            }
            if viewModel.hasClaudeCredentials {
                let usage = viewModel.usageData
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
            let detail = codex.planType != "unknown" ? codex.planType.capitalized : ""
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
                    actionTitle: error != nil && shouldPromptCodexAuthentication ? "How to authenticate Codex" : nil
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
                provider: .kimi, detail: viewModel.kimiAuthSource.displayName, rows: rows,
                message: error, actionTitle: error != nil ? "KimiCode Setup…" : nil
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
        panelModel.onAction = { [weak self] provider in
            self?.panel.close()
            switch provider {
            case .claude: self?.authenticateClaude()
            case .codex: self?.authenticateCodex()
            case .kimi: self?.authenticateKimi()
            case .cursor, .zai, .xai: break
            }
        }
        panelModel.onRefresh = { [weak self] in
            self?.panelModel.isRefreshing = true
            self?.refreshData()
        }
        panelModel.onMore = { [weak self] anchor in
            guard let self else { return }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
        }
        panelModel.onUpdate = { [weak self] in self?.checkForUpdates() }
        panelModel.onSetup = { [weak self] in
            self?.panel.close()
            self?.showCredentialsWindow()
        }
        panelModel.onSetUpKimi = { [weak self] in
            self?.panel.close()
            self?.authenticateKimi()
        }
        panelModel.onQuit = { NSApp.terminate(nil) }
    }

    @objc private func statusBarButtonClicked() {
        togglePanel()
    }

    @objc private func showCredentialsWindow() {
        if credentialsWindow == nil {
            let contentView = CredentialsView(onSave: { [weak self] sessionKey, orgId in
                self?.viewModel.saveCredentials(sessionKey: sessionKey, organizationId: orgId)
                self?.credentialsWindow?.close()
                self?.credentialsWindow = nil
                self?.rebuildMenu()
            })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = ""
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            credentialsWindow = window
        }

        credentialsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshData() {
        Task {
            await viewModel.rediscoverCredentialsAndRefresh()
        }
    }

    @objc private func authenticateClaude() {
        let alert = NSAlert()
        alert.messageText = "Authenticate Claude"
        alert.informativeText = """
        Open Terminal, run `claude`, and log in when prompted.
        Then click Refresh in Usagebar and your usage will appear.

        This also fixes "Session expired": re-logging in from the \
        terminal renews the credentials Usagebar reads.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Manual Setup…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            showCredentialsWindow()
        }
    }

    @objc private func authenticateCodex() {
        presentAlert(
            title: "Authenticate Codex",
            message: "Run `codex login` in Terminal, then click Refresh in Usagebar.",
            style: .informational
        )
    }

    @objc private func authenticateKimi() {
        let alert = NSAlert()
        alert.messageText = "Set Up KimiCode"
        alert.informativeText = """
        Run `kimi login` in Terminal, then click Refresh in Usagebar.

        Usagebar reads Kimi Code CLI's local OAuth credential without changing it. You can also paste a Kimi Code API key or a `kimi-auth` web token.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Paste Credential…")
        alert.addButton(withTitle: "Open KimiCode Console")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            showKimiCredentialPrompt()
        case .alertThirdButtonReturn:
            if let url = URL(string: "https://www.kimi.com/code/console") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func showKimiCredentialPrompt() {
        let alert = NSAlert()
        alert.messageText = "KimiCode Credential"
        alert.informativeText = "Paste a Kimi Code API key or the `kimi-auth` token from the Kimi Code console. It is encrypted locally."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let credentialField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        credentialField.placeholderString = "API key or kimi-auth token"
        alert.accessoryView = credentialField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let credential = credentialField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { return }
        viewModel.saveKimiCredential(credential)
        rebuildMenu()
    }

    @objc private func toggleAutoUpdate() {
        viewModel.autoUpdate.toggle()
        rebuildMenu()
    }

    /// Re-enables the just-toggled provider if hiding it would leave no
    /// authenticated provider in the panel.
    private func ensureAProviderRemainsShown(fallback keyPath: ReferenceWritableKeyPath<UsageViewModel, Bool>) {
        let anyShown =
            (viewModel.showClaude && viewModel.hasClaudeCredentials) ||
            (viewModel.showCodex && viewModel.hasCodexCredentials) ||
            (viewModel.showCursor && viewModel.hasCursorCredentials) ||
            (viewModel.showKimi && viewModel.hasKimiCredentials) ||
            (viewModel.showZai && viewModel.hasZaiCredentials) ||
            (viewModel.showXai && viewModel.hasXaiCredentials)
        if !anyShown {
            viewModel[keyPath: keyPath] = true
        }
    }

    @objc private func toggleShowClaude() {
        viewModel.showClaude.toggle()
        ensureAProviderRemainsShown(fallback: \.showClaude)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowCodex() {
        viewModel.showCodex.toggle()
        ensureAProviderRemainsShown(fallback: \.showCodex)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowCursor() {
        viewModel.showCursor.toggle()
        ensureAProviderRemainsShown(fallback: \.showCursor)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowKimi() {
        viewModel.showKimi.toggle()
        ensureAProviderRemainsShown(fallback: \.showKimi)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowZai() {
        viewModel.showZai.toggle()
        ensureAProviderRemainsShown(fallback: \.showZai)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowXai() {
        viewModel.showXai.toggle()
        ensureAProviderRemainsShown(fallback: \.showXai)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        viewModel.launchAtStartup.toggle()
        rebuildMenu()
    }

    @objc private func signOutClaude() {
        viewModel.clearClaudeCredentials()
        rebuildMenu()
    }

    @objc private func signOutCodex() {
        viewModel.clearCodexCredentials()
        rebuildMenu()
    }

    @objc private func clearKimiCredential() {
        viewModel.clearKimiCredential()
        rebuildMenu()
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
                rebuildMenu()
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
                rebuildMenu()
                if interactive {
                    let version = status.latestRelease?.version ?? "the new version"
                    presentAlert(
                        title: "Update on its way",
                        message: "Usagebar \(version) was just published and is still rolling out. It will install automatically in a bit - nothing to do.",
                        style: .informational
                    )
                }
            case .failed(let status, let message):
                rebuildMenu()
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

    private func formatMenuTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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

    // MARK: - Panel Provider Marks

    /// The four marks laid out left to right from the origin, `height` tall.
    private func cursorPlanMarkPaths(height: CGFloat) -> (paths: [NSBezierPath], width: CGFloat) {
        let gap = height * 0.3125
        // (unit-space path, its unit width, size relative to `height`)
        let marks: [(path: NSBezierPath, unitWidth: CGFloat, scale: CGFloat)] = [
            (xMarkPath(), 1200 / 1227, 0.8),
            (grokMarkPath(), 1, 1),
            (cursorCubePath(), 0.88, 1),
            (grokBotMarkPath(), 1, 1)
        ]
        var x: CGFloat = 0
        var paths: [NSBezierPath] = []
        for mark in marks {
            let size = height * mark.scale
            var transform = AffineTransform(translationByX: x, byY: (height - size) / 2)
            transform.scale(size)
            mark.path.transform(using: transform)
            paths.append(mark.path)
            x += mark.unitWidth * size + gap
        }
        return (paths, x - gap)
    }

    private func cursorPlanMarksImage(height: CGFloat) -> NSImage {
        let marks = cursorPlanMarkPaths(height: height)
        return templateImage(size: NSSize(width: marks.width, height: height), paths: marks.paths)
    }

    /// Fills `paths` into a vector template image, so it renders sharp and
    /// takes the tint of the view that shows it.
    private func templateImage(size: NSSize, paths: [NSBezierPath]) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            paths.forEach { $0.fill() }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Builds a closed polygon in unit space.
    private func polygon(_ points: [NSPoint], into path: NSBezierPath) {
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
    }

    /// X (xAI) mark: a hollow thick stroke and a thin stroke, from the
    /// official 1200×1227 outline, flipped to y-up and scaled to unit height.
    private func xMarkPath() -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x / 1227, y: (1227 - y) / 1227) }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        polygon([
            p(714.163, 519.284), p(1160.89, 0), p(1055.03, 0), p(667.137, 450.887),
            p(357.328, 0), p(0, 0), p(468.492, 681.821), p(0, 1226.37), p(105.866, 1226.37),
            p(515.491, 750.218), p(842.672, 1226.37), p(1200, 1226.37)
        ], into: path)
        polygon([
            p(569.165, 687.828), p(521.697, 619.934), p(144.011, 79.6944), p(306.615, 79.6944),
            p(611.412, 515.685), p(658.88, 583.579), p(1055.08, 1150.3), p(892.476, 1150.3)
        ], into: path)
        return path
    }

    /// Grok mark: a ring broken by a diagonal needle that tapers past it.
    private func grokMarkPath() -> NSBezierPath {
        let center = NSPoint(x: 0.5, y: 0.5)
        let k: CGFloat = 0.5 / 1.36            // ring radius 1 in a unit box
        let path = NSBezierPath()
        for (start, end) in [(CGFloat(62), CGFloat(224)), (245, 405)] {
            let radians = start * .pi / 180
            path.move(to: NSPoint(x: center.x + k * cos(radians), y: center.y + k * sin(radians)))
            path.appendArc(withCenter: center, radius: k, startAngle: start, endAngle: end)
            path.appendArc(withCenter: center, radius: 0.7 * k, startAngle: end, endAngle: start, clockwise: true)
            path.close()
        }
        let u = NSPoint(x: cos(CGFloat.pi / 4) * k, y: sin(CGFloat.pi / 4) * k)
        func p(along a: CGFloat, across c: CGFloat) -> NSPoint {
            NSPoint(x: center.x + u.x * a - u.y * c, y: center.y + u.y * a + u.x * c)
        }
        polygon([
            p(along: 1.9, across: 0), p(along: 0.92, across: 0.09), p(along: 0, across: 0.035),
            p(along: -0.92, across: 0.09), p(along: -1.9, across: 0), p(along: -0.92, across: -0.09),
            p(along: 0, across: -0.035), p(along: 0.92, across: -0.09)
        ], into: path)
        return path
    }

    /// Cursor mark: a pointy-top hexagon with an arrow-shaped facet cut out.
    private func cursorCubePath() -> NSBezierPath {
        let r: CGFloat = 0.5
        let center = NSPoint(x: 0.44, y: 0.5)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: center.x + x * r, y: center.y + y * r) }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        polygon([p(0, 1), p(0.866, 0.5), p(0.866, -0.5), p(0, -1), p(-0.866, -0.5), p(-0.866, 0.5)], into: path)
        polygon([p(-0.74, 0.43), p(0.74, 0.43), p(0.01, -0.86), p(0.01, 0)], into: path)
        return path
    }

    /// Grok Bot mark: a ball with two tilted capsule eyes cut out.
    private func grokBotMarkPath() -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 1, height: 1))
        path.windingRule = .evenOdd
        for (eyeCenter, length, width) in [(NSPoint(x: 0.51, y: 0.61), CGFloat(0.21), CGFloat(0.12)),
                                           (NSPoint(x: 0.78, y: 0.72), 0.23, 0.11)] {
            let eye = NSBezierPath(
                roundedRect: NSRect(x: -width / 2, y: -length / 2, width: width, height: length),
                xRadius: width / 2, yRadius: width / 2
            )
            var transform = AffineTransform(translationByX: eyeCenter.x, byY: eyeCenter.y)
            transform.rotate(byDegrees: 30)
            eye.transform(using: transform)
            path.append(eye)
        }
        return path
    }

    /// ZCode mark: a top bar, a long diagonal and a bottom bar split by thin
    /// slanted gaps, in a unit-height box 1.13 wide.
    private func zcodeMarkPath() -> NSBezierPath {
        let path = NSBezierPath()
        polygon([NSPoint(x: 0, y: 1), NSPoint(x: 0.56, y: 1), NSPoint(x: 0.465, y: 0.86), NSPoint(x: 0, y: 0.86)], into: path)
        polygon([NSPoint(x: 0.64, y: 1), NSPoint(x: 1.13, y: 1), NSPoint(x: 0.46, y: 0), NSPoint(x: 0, y: 0)], into: path)
        polygon([NSPoint(x: 0.645, y: 0.16), NSPoint(x: 1.13, y: 0.16), NSPoint(x: 1.13, y: 0), NSPoint(x: 0.537, y: 0)], into: path)
        return path
    }

    // MARK: - Helpers

    private var brandClaudeColor: NSColor {
        NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)
    }

    private var shouldPromptClaudeAuthentication: Bool {
        !viewModel.hasClaudeCredentials || viewModel.claudeError != nil
    }

    private var shouldPromptCodexAuthentication: Bool {
        !viewModel.hasCodexCredentials || viewModel.codexError == APIError.unauthorized.errorDescription
    }
}

// MARK: - Credentials View (for setup window)

struct CredentialsView: View {
    let onSave: (String, String) -> Void
    @ObservedObject private var viewModel = UsageViewModel.shared

    @State private var showManualEntry = false
    @State private var sessionKey = ""
    @State private var organizationId = ""

    private let anthropicOrange = Color(red: 0.83, green: 0.53, blue: 0.30)

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 4) {
                Text("\u{2733}\u{FE0E}")
                    .foregroundColor(anthropicOrange)
                    .font(.title2)
                Text("Claude Usage")
                    .font(.headline)
            }
            .padding(.top, 8)

            // Auto-detected status
            VStack(spacing: 8) {
                if viewModel.hasClaudeCredentials {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Claude detected")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                if viewModel.hasCodexCredentials {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Codex detected")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }

            if viewModel.hasClaudeCredentials || viewModel.hasCodexCredentials {
                VStack(spacing: 10) {
                    if viewModel.hasClaudeCredentials {
                        Button(action: {
                            onSave("__oauth__", "__oauth__")
                        }) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Use Claude Detected Credentials")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(anthropicOrange)
                    }

                    if viewModel.hasCodexCredentials {
                        Button(action: {
                            onSave("__detected_codex__", "__detected_codex__")
                        }) {
                            HStack {
                                Image(systemName: "terminal")
                                Text("Use Codex Detected Credentials")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(anthropicOrange)
                    }
                }

                Divider()
                    .padding(.vertical, 4)
            }

            if !showManualEntry {
                Spacer()
                VStack(spacing: 16) {
                    Text("Manual Claude setup")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Divider()
                        .padding(.vertical, 4)

                    Button(action: { showManualEntry = true }) {
                        HStack {
                            Image(systemName: "keyboard")
                            Text("Manual Entry")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    Text("For advanced users")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                // Manual entry form
                VStack(alignment: .leading, spacing: 10) {
                    Text("Manual Credential Entry")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Organization ID")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("From URL: claude.ai/chat \u{2192} copy UUID after /organizations/")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        TextField("263e9fcb-52b9-4372-8842-...", text: $organizationId)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session Key")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("From DevTools \u{2192} Application \u{2192} Cookies \u{2192} sessionKey")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        SecureField("sk-ant-sid01-...", text: $sessionKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("\u{2190} Back") {
                            showManualEntry = false
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Save") {
                            onSave(sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                   organizationId.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(anthropicOrange)
                        .disabled(sessionKey.isEmpty || organizationId.isEmpty)
                    }
                }
            }

            Spacer()

            Text("Not affiliated with Anthropic or OpenAI.\nCredentials stored locally (encrypted).")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 300, height: 400)
    }
}
