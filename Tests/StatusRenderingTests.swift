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
        setupMenu()
        defer {
            panel.close()
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
            menuWillOpen(menu)
            if providers.isEmpty {
                precondition(menu.items.contains { $0.title == "Setup Usage Tracking" })
            } else {
                precondition(menu.items.contains { $0.title == "Refresh" })
                let updates = menu.items.first { $0.title == "Last Updates" }?.submenu
                precondition(updates?.numberOfItems == providers.count)
                let display = menu.items.first { $0.title == "Display" }!.submenu!
                precondition(display.numberOfItems == providers.count, "Display must contain only provider switches")
                precondition(display.items.allSatisfy { $0.title == "Show Claude" || $0.title == "Show Codex" })
                precondition(!menu.items.contains { $0.title == "Show Icon" }, "Fixed icon can still be hidden")
            }
            menuDidClose(menu)
            let firstItem = menu.items.first
            rebuildMenu()
            precondition(menu.items.first === firstItem, "Closed menu rebuilt")

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
        // Closing the settings menu must keep the visible panel at the on-screen cadence.
        button.performClick(nil)
        menuWillOpen(menu)
        menuDidClose(menu)
        precondition(isPanelOpen && viewModel.scheduledRefreshInterval == viewModel.effectiveRefreshInterval)
        panel.close()
        precondition(!isPanelOpen && viewModel.scheduledRefreshInterval == viewModel.effectiveRefreshInterval * 5)

        viewModel.usageData.fiveHourUsed = 99
        viewModel.codexUsageData.primaryUsedPercent = 100
        availableUpdateVersion = "99.0"
        usageDataChanged()
        precondition(button.image === icon && statusItem.length == NSStatusItem.squareLength,
                     "Usage, errors, or updates changed the fixed icon")
        availableUpdateVersion = nil
        viewModel.usageData.fiveHourUsed = 23
        viewModel.codexUsageData.primaryUsedPercent = 34

        // Keep the last authenticated provider enabled when using the Display switches.
        toggleShowClaude()
        precondition(!viewModel.showClaude && viewModel.showCodex)
        toggleShowCodex()
        precondition(viewModel.showCodex, "Display switches hid every authenticated provider")
        viewModel.showClaude = true

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
        print("PASS: setup/Claude/Codex panels, single-click toggle, fixed template icon, provider switches, closed-menu reuse, visibility cadence")
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
        // Shrinking content must shrink the same live panel, not leave a blank gap.
        let liveHost = NSHostingView(rootView: UsagePanelView(model: panelModel))
        liveHost.setFrameSize(liveHost.fittingSize)
        liveHost.layoutSubtreeIfNeeded()
        let tallHeight = liveHost.fittingSize.height
        viewModel.useCPAAccountFixtures([accounts[0]])
        updatePanel()
        liveHost.layoutSubtreeIfNeeded()
        let freshHost = NSHostingView(rootView: UsagePanelView(model: panelModel))
        precondition(liveHost.fittingSize.height < tallHeight - 100, "Panel kept its taller height after content shrank")
        precondition(abs(liveHost.fittingSize.height - freshHost.fittingSize.height) < 1,
                     "Panel height depends on earlier content")
        panel.close()
    }
}
