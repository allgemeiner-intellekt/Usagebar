import AppKit
import SwiftUI

// The runner joins this file with the two controllers so these test extensions can
// inspect private state without adding test-only accessors to the shipped app.
extension UsageViewModel {
    fileprivate func useRenderingFixtures(_ providers: Set<DisplayProvider>) {
        availableProviders = providers
        claudeAuthSource = .oauth
        for provider in providers {
            refreshStates[provider, default: .init()].succeeded(at: Date())
        }
    }
}

extension AppDelegate {
    fileprivate func verifyRendering(output: URL?) throws {
        setupStatusItem()
        settingsNavigation.loadCPAConnection = { nil }
        settingsNavigation.loadClaudeCredentials = { ("", "") }
        defer {
            panel.close()
            settingsWindow?.close()
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        viewModel.stopAutoRefresh()
        viewModel.showClaude = true
        viewModel.showCodex = true
        viewModel.showCursor = false
        viewModel.showKimi = false
        viewModel.showZai = false
        viewModel.showXai = false
        viewModel.usageData = UsageData(fiveHourUsed: 23, weeklyUsed: 67)
        viewModel.codexUsageData = CodexUsageData(primaryUsedPercent: 34, secondaryUsedPercent: 72)

        let button = statusItem.button!
        let icon = button.image!
        precondition(icon.isTemplate, "Status icon must follow the menu bar appearance")
        precondition(statusItem.length == NSStatusItem.squareLength, "Status item must use a standard square slot")
        precondition(button.imagePosition == .imageOnly && button.title.isEmpty, "Status item contains usage text")
        precondition(button.accessibilityLabel() == "Usagebar", "Status icon lost its accessible name")
        let clickMask = NSEvent.EventTypeMask(rawValue: UInt64(button.sendAction(on: [.leftMouseUp, .rightMouseUp])))
        precondition(clickMask.contains(.leftMouseUp) && clickMask.contains(.rightMouseUp), "Both clicks must open the panel")

        for providers: Set<DisplayProvider> in [[], [.claude], [.codex], [.claude, .codex]] {
            viewModel.useRenderingFixtures(providers)

            // Exercise the real button target/action, including setup and multi-provider states.
            button.performClick(nil)
            precondition(isPanelOpen && panel.isVisible, "Single click did not open the panel")
            precondition(panelModel.needsSetup == providers.isEmpty, "Panel setup state is incorrect")
            precondition(viewModel.scheduledRefreshInterval == viewModel.effectiveRefreshInterval)
            precondition(panelModel.cards.map(\.provider) == [.claude, .codex], "Provider card order changed")
            button.performClick(nil)
            precondition(!isPanelOpen && !panel.isVisible, "Second click did not close the panel")
            precondition(viewModel.scheduledRefreshInterval == viewModel.effectiveRefreshInterval * 5)
            precondition(button.image === icon, "Provider availability changed the fixed icon")
        }

        viewModel.useRenderingFixtures([.claude, .codex])
        // Opening Settings from the panel (gear icon or Cmd+,) closes the panel,
        // presents the unified Settings window, and keeps the visible cadence until closed.
        button.performClick(nil)
        precondition(isPanelOpen && panel.isVisible)
        panel.onOpenSettings()
        precondition(!isPanelOpen && !panel.isVisible, "Opening Settings did not close the panel")
        precondition(isSettingsOpen && settingsWindow?.isVisible == true, "Settings window did not open")
        precondition(viewModel.scheduledRefreshInterval == viewModel.effectiveRefreshInterval,
                     "Open Settings window did not preserve visible refresh cadence")

        showSettings(section: .dataSource)
        precondition(settingsNavigation.selectedSection == .dataSource, "Deep-linking to Data Source failed")
        showSettings(section: .providers, setupSheet: .kimi)
        precondition(settingsNavigation.selectedSection == .providers && settingsNavigation.activeSetupSheet == .kimi,
                     "Deep-linking to Providers setup sheet failed")
        settingsNavigation.activeSetupSheet = nil

        // Render every Settings section in both light and dark appearances without credential I/O.
        for section in SettingsSection.allCases {
            settingsNavigation.selectedSection = section
            for scheme: ColorScheme in [.light, .dark] {
                let host = NSHostingView(
                    rootView: SettingsView(viewModel: viewModel, navigation: settingsNavigation)
                        .frame(width: 660, height: 480)
                        .environment(\.colorScheme, scheme)
                )
                host.setFrameSize(NSSize(width: 660, height: 480))
                host.layoutSubtreeIfNeeded()
                precondition(host.bounds.width >= 580 && host.bounds.height >= 400,
                             "Settings section \(section.rawValue) failed to lay out")
            }
        }
        settingsNavigation.selectedSection = .general

        settingsWindow?.close()
        precondition(!isSettingsOpen && viewModel.scheduledRefreshInterval == viewModel.effectiveRefreshInterval * 5,
                     "Closing Settings did not restore hidden refresh cadence")

        viewModel.usageData.fiveHourUsed = 99
        viewModel.codexUsageData.primaryUsedPercent = 100
        availableUpdateVersion = "99.0"
        usageDataChanged()
        precondition(settingsNavigation.availableUpdateVersion == "99.0",
                     "Settings navigation did not sync available update version")
        precondition(button.image === icon && statusItem.length == NSStatusItem.squareLength,
                     "Usage, errors, or updates changed the fixed icon")
        availableUpdateVersion = nil
        viewModel.usageData.fiveHourUsed = 23
        viewModel.codexUsageData.primaryUsedPercent = 34

        // Keep the last authenticated provider enabled when using the Provider switches.
        viewModel.setProviderShown(false, for: .claude)
        precondition(!viewModel.showClaude && viewModel.showCodex)
        precondition(viewModel.isLastVisibleAvailableProvider(.codex), "Last visible provider was not flagged")
        viewModel.setProviderShown(false, for: .codex)
        precondition(viewModel.showCodex, "Provider switches hid every authenticated provider")
        viewModel.setProviderShown(true, for: .claude)

        let expiry = ISO8601Timestamp.date(from: "2026-11-06T15:59:00Z")!
        let later = ISO8601Timestamp.date(from: "2026-11-30T15:59:00Z")!
        let inventory = BankedResets(availableCount: 3, expirations: [.at(later), .at(expiry), .at(expiry)])
        viewModel.codexUsageData = CodexUsageData(
            planType: "pro", primaryUsedPercent: 34, primaryWindowSeconds: 604800,
            bankedResets: inventory
        )
        let codexCard = panelCards().first { $0.provider == .codex }!
        let claudeCard = panelCards().first { $0.provider == .claude }!
        precondition(codexCard.bankedResets == inventory && codexCard.showsBankedResets)
        precondition(codexCard.rows.count == 1, "Weekly primary must not duplicate its secondary window")
        func cardHeight(_ card: UsagePanelCard) -> CGFloat {
            let hosting = NSHostingView(rootView: UsagePanelCardView(card: card, model: panelModel).frame(width: 324))
            return hosting.fittingSize.height
        }
        precondition(abs(cardHeight(codexCard) - cardHeight(claudeCard)) < 4,
                     "Banked reset summary should occupy the same height as a second usage row")
        var emptyCard = codexCard
        emptyCard.bankedResets = BankedResets(availableCount: 0, expirations: [])
        precondition(!emptyCard.showsBankedResets && !emptyCard.resetInventoryUnavailable)
        precondition(cardHeight(emptyCard) < cardHeight(codexCard) - 10, "Zero resets must leave no blank summary row")
        var unavailableCard = codexCard
        unavailableCard.bankedResets = nil
        precondition(!unavailableCard.showsBankedResets && unavailableCard.resetInventoryUnavailable,
                     "Failed inventory must remain distinct from zero resets")
        precondition(!claudeCard.tracksBankedResets && !claudeCard.resetInventoryUnavailable,
                     "Direct Claude does not read reset grants and must not show them as unavailable")
        let claudeGrants = BankedResets(availableCount: 2, grants: [
            BankedResets.Grant(id: "nov", kind: .full, label: "", left: 1, total: 1, expiration: .at(expiry)),
            BankedResets.Grant(id: "refill", kind: .fable, label: "", left: 1, total: 1, expiration: .unknown)
        ])
        let cpaClaudeCard = UsagePanelCard(provider: .claude, detail: "", rows: Array(claudeCard.rows.prefix(1)),
                                           bankedResets: claudeGrants, tracksBankedResets: true)
        precondition(cpaClaudeCard.showsBankedResets && claudeGrants.entries?.map(\.title) == ["Full reset", "Fable reset"])
        precondition(abs(cardHeight(cpaClaudeCard) - cardHeight(codexCard)) < 4,
                     "Claude reset summary should match the Codex card height")

        guard let output else { return }
        let sheet = NSImage(size: NSSize(width: 720, height: 460))
        for (column, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let dark = column == 1
            let originX = CGFloat(column) * 360
            let theme = NSAppearance(named: appearance)!
            button.appearance = theme
            precondition(button.image === icon, "Appearance change rebuilt the fixed icon")
            isPanelOpen = true
            updatePanel()
            let hosting = NSHostingView(rootView: UsagePanelView(model: panelModel)
                .environment(\.colorScheme, dark ? .dark : .light))
            hosting.appearance = theme
            hosting.setFrameSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let panelImage = NSImage(size: hosting.bounds.size)
            panelImage.addRepresentation(bitmap)

            let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            iconView.appearance = theme
            iconView.image = icon
            iconView.contentTintColor = dark ? .white : .black
            let iconBitmap = iconView.bitmapImageRepForCachingDisplay(in: iconView.bounds)!
            iconView.cacheDisplay(in: iconView.bounds, to: iconBitmap)
            let iconImage = NSImage(size: iconView.bounds.size)
            iconImage.addRepresentation(iconBitmap)

            sheet.lockFocus()
            (dark ? NSColor(white: 0.12, alpha: 1) : .white).setFill()
            NSRect(x: originX, y: 0, width: 360, height: 460).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: dark ? NSColor.white : NSColor.black
            ]
            NSAttributedString(string: dark ? "Dark appearance" : "Light appearance", attributes: attrs)
                .draw(at: NSPoint(x: originX + 44, y: 420))
            iconImage.draw(at: NSPoint(x: originX + 12, y: 414), from: .zero, operation: .sourceOver, fraction: 1)
            panelImage.draw(at: NSPoint(x: originX + 10, y: 405 - panelImage.size.height), from: .zero, operation: .sourceOver, fraction: 1)
            sheet.unlockFocus()
        }
        if let tiff = sheet.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: output)
        }
        // Render the real detail view in both appearances, using fixture dates only.
        let detailSheet = NSImage(size: NSSize(width: 660, height: 320))
        for (column, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let dark = column == 1
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                BankedResetDetailsView(resets: inventory)
                BankedResetDetailsView(resets: claudeGrants)
            }
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: appearance)!
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let preview = NSImage(size: host.bounds.size)
            preview.addRepresentation(bitmap)
            detailSheet.lockFocus()
            (dark ? NSColor(white: 0.16, alpha: 1) : .white).setFill()
            NSRect(x: CGFloat(column) * 330, y: 0, width: 330, height: 320).fill()
            preview.draw(at: NSPoint(x: CGFloat(column) * 330 + 10, y: 310 - preview.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
            detailSheet.unlockFocus()
        }
        if let tiff = detailSheet.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: output.deletingLastPathComponent().appendingPathComponent("banked-reset-details-preview.png"))
        }
    }
}

@main
struct StatusRenderingTests {
    @MainActor static func main() async throws {
        guard Bundle.main.bundleIdentifier == "dev.usagebar.performance-tests" else {
            fatalError("Tests require their isolated preferences domain")
        }
        UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests")
        defer { UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests") }
        // Legacy display preferences must not hide the icon or enable rotation.
        UserDefaults.standard.set(false, forKey: "showIcon")
        UserDefaults.standard.set(0.01, forKey: "animationInterval")
        UserDefaults.standard.set(true, forKey: "followActiveApp")
        UserDefaults.standard.set("codex", forKey: "preferredDisplayProvider")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try await testCPAStorage()
        try await CodexAPIService.verifyBankedResets()
        let model = UsageViewModel(startAutomatically: false)
        let output = ProcessInfo.processInfo.environment["USAGEBAR_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let delegate = AppDelegate(viewModel: model)
        try delegate.verifyRendering(output: output)
        delegate.verifyCPARendering()
        print("PASS: setup/Claude/Codex panels, single-click toggle, fixed template icon, unified settings window, provider switches, visibility cadence")
    }
}

extension UsageViewModel {
    fileprivate func useCPAAccountFixtures(_ accounts: [CPAAccount]) {
        source = .cpa
        cpaAccounts = accounts
        availableProviders = Set(accounts.map(\.provider))
    }
}

extension AppDelegate {
    fileprivate func verifyCPARendering() {
        viewModel.stopAutoRefresh()
        let reading = CPAReading(plan: "plus", windows: [CPAWindow(label: "5h", percent: 27, reset: nil)])
        let accounts = (0..<20).map {
            CPAAccount(id: "fixture-\($0)", provider: .codex, identity: "Account \($0)", disabled: false, expired: false, reading: reading)
        }
        viewModel.useCPAAccountFixtures(accounts)
        let cards = panelCards()
        precondition(cards.count == 1 && cards[0].accounts.count == 20, "Accounts are not grouped in one provider card")
        precondition(cards[0].rows.isEmpty && cards[0].detail.isEmpty, "Multi-account quota was aggregated")
        viewModel.useCPAAccountFixtures([accounts[0]])
        let compact = panelCards()[0]
        precondition(compact.accounts.isEmpty && compact.rows.count == 1, "Single account lost compact style")
        viewModel.useCPAAccountFixtures(accounts)
        isPanelOpen = true
        updatePanel()
        precondition(!panelModel.needsSetup && panelModel.emptyMessage == nil, "CPA panel gained source/setup clutter")
        for scheme: ColorScheme in [.light, .dark] {
            let host = NSHostingView(rootView: UsagePanelView(model: panelModel).environment(\.colorScheme, scheme))
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.height <= panelModel.maximumContentHeight + 120, "Multi-account panel exceeded screen cap")
        }
        // Shrinking content must shrink the open panel window, not leave a blank gap.
        // SwiftUI applies model changes on a later run-loop pass, so let it run.
        panel.setFrame(NSRect(x: 0, y: 0, width: 340, height: 300), display: false)
        panel.orderFrontRegardless()
        panel.fitContent()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let tallHeight = panel.frame.height
        viewModel.useCPAAccountFixtures([accounts[0]])
        updatePanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let freshHeight = NSHostingView(rootView: UsagePanelView(model: panelModel)).fittingSize.height
        precondition(panel.frame.height < tallHeight - 100, "Panel kept its taller height after content shrank")
        precondition(abs(panel.frame.height - freshHeight) < 1, "Panel height depends on earlier content")

        // Antigravity CPA rendering, card ordering, pool submenu filtering, and all-pools-hidden state.
        let agReading = CPAReading(plan: "Pro", windows: [], poolGroups: [
            CPAPoolGroup(id: "gemini-models", label: "Gemini Models", description: "Models: Gemini Flash, Gemini Pro, Gemini Argon", windows: [
                CPAWindow(id: "gemini-5h", label: "5h", percent: 15, reset: Date().addingTimeInterval(3600)),
                CPAWindow(id: "gemini-weekly", label: "7d", percent: 40, reset: Date().addingTimeInterval(86400))
            ]),
            CPAPoolGroup(id: "claude-and-gpt-models", label: "Claude and GPT models", description: "Models: Claude Opus, GPT-OSS", windows: [
                CPAWindow(id: "3p-5h", label: "5h", percent: 0, reset: Date().addingTimeInterval(3600),
                          blockedByOuterLimit: true, detail: "Blocked because this pool's weekly limit is exhausted."),
                CPAWindow(id: "3p-weekly", label: "7d", percent: 100, reset: Date().addingTimeInterval(86400))
            ])
        ])
        let agAccount1 = CPAAccount(id: "ag-1", provider: .antigravity, identity: "ag1@example.invalid",
                                    disabled: false, expired: false, projectID: "proj-1", reading: agReading)
        let agAccount2 = CPAAccount(id: "ag-2", provider: .antigravity, identity: "ag2@example.invalid",
                                    disabled: false, expired: false, projectID: "proj-2", reading: agReading)
        let claudeAccount = CPAAccount(id: "cl-1", provider: .claude, identity: "cl@example.invalid",
                                       disabled: false, expired: false, reading: reading)
        viewModel.showClaude = true
        viewModel.showCodex = true
        viewModel.showAntigravity = true
        viewModel.showAllAntigravityPools()
        viewModel.useCPAAccountFixtures([claudeAccount, accounts[0], agAccount1])
        let ordered = panelCards()
        precondition(ordered.map(\.provider) == [.claude, .codex, .antigravity], "Antigravity card order mismatch")
        let agCard = ordered[2]
        precondition(agCard.detail == "Pro" && agCard.poolGroups.count == 2 && !agCard.allPoolsHidden, "Single Antigravity card lost pools or plan")
        precondition(agCard.poolGroups[1].rows[0].dimmed, "Weekly-exhausted 5h row must be dimmed")

        // Verify Antigravity pool discovery and toggles update panel cards.
        precondition(viewModel.discoveredAntigravityPools.map(\.id) == ["gemini-models", "claude-and-gpt-models"],
                     "Missing discovered Antigravity pools in CPA mode")
        precondition(viewModel.isAntigravityPoolVisible("gemini-models") && viewModel.isAntigravityPoolVisible("claude-and-gpt-models"),
                     "Pools should be visible by default")

        viewModel.toggleAntigravityPool("gemini-models")
        let filteredCard = panelCards().first { $0.provider == .antigravity }!
        precondition(filteredCard.poolGroups.map(\.id) == ["claude-and-gpt-models"] && !filteredCard.allPoolsHidden, "Hiding one pool failed")

        viewModel.toggleAntigravityPool("claude-and-gpt-models")
        let hiddenAllCard = panelCards().first { $0.provider == .antigravity }!
        precondition(hiddenAllCard.poolGroups.isEmpty && hiddenAllCard.allPoolsHidden, "All-pools-hidden state not reflected")

        viewModel.showAllAntigravityPools()
        viewModel.useCPAAccountFixtures([agAccount1, agAccount2])
        updatePanel()
        let multiAG = panelCards().first { $0.provider == .antigravity }!
        precondition(multiAG.accounts.count == 2 && multiAG.poolGroups.isEmpty, "Multi-account Antigravity must render per account")
        for scheme: ColorScheme in [.light, .dark] {
            let host = NSHostingView(rootView: UsagePanelView(model: panelModel).environment(\.colorScheme, scheme))
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.height <= panelModel.maximumContentHeight + 120, "Antigravity panel exceeded screen cap")
        }
        panel.close()
    }
}
