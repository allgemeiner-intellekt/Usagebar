//
//  UsageViewModel.swift
//  JustaUsageBar
//

import Foundation
import Combine
import SwiftUI
import ServiceManagement

@MainActor
final class UsageViewModel: ObservableObject {
    static let shared = UsageViewModel()

    @Published private(set) var isCPAConfigured: Bool?
    @Published private(set) var cpaAccounts: [CPAAccount] = []
    @Published private(set) var cpaError: String?
    private var cpaClient: CPAClient?
    private let makeCPAClient: @ProviderActor (CPAConnection) -> CPAClient
    private var discoveryState = ProviderRefreshState()
    private var connectionGeneration = UUID()
    private var configurationGeneration = UUID()
    private var isSavingConnection = false

    // MARK: - General

    nonisolated static let defaultRefreshInterval: TimeInterval = 120
    nonisolated static let supportedRefreshIntervals: [TimeInterval] = [60, 120, 300, 600]
    nonisolated private static let refreshIntervalDefaultsKey = "refreshInterval"

    @Published var isLoading: Bool = false
    @Published var lastUpdated: Date?
    @Published var refreshInterval: TimeInterval = {
        if let saved = UserDefaults.standard.object(forKey: "refreshInterval") as? Double {
            return max(30, min(600, saved))
        }
        return 120
    }()

    // MARK: - Display Settings (persisted)

    @AppStorage("showClaude") var showClaude: Bool = true
    @AppStorage("showCodex") var showCodex: Bool = true
    @AppStorage("showAntigravity") var showAntigravity: Bool = true
    @AppStorage("showCursor") var showCursor: Bool = true
    @AppStorage("showZai") var showZai: Bool = true
    @AppStorage("showXai") var showXai: Bool = true
    @AppStorage("showKimi") var showKimi: Bool = true
    @AppStorage("autoUpdate") var autoUpdate: Bool = true

    nonisolated private static let hiddenAntigravityPoolsDefaultsKey = "hiddenAntigravityPoolIDs"
    @Published private(set) var hiddenAntigravityPoolIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "hiddenAntigravityPoolIDs") ?? []
    )

    @Published private(set) var globalHotkey: GlobalHotkey? = GlobalHotkey.load(from: .standard)

    func setGlobalHotkey(_ hotkey: GlobalHotkey?) {
        globalHotkey = hotkey
        GlobalHotkey.save(hotkey, to: .standard)
    }

    // Launch at login using SMAppService (macOS 13+)
    var launchAtStartup: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            objectWillChange.send()
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to \(newValue ? "enable" : "disable") launch at login: \(error)")
                }
            }
        }
    }

    // MARK: - Refresh scheduling

    @Published private(set) var availableProviders: Set<DisplayProvider> = []
    @Published private(set) var isBackgroundSuspended = false

    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh = false
    private var pendingManualRefresh = false
    private var autoRefreshEnabled = true
    private var displayAsleep = false
    private var systemAsleep = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var isUsageVisible = false

    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false

    init(startAutomatically: Bool = true, makeCPAClient: @escaping @ProviderActor (CPAConnection) -> CPAClient = { CPAClient(connection: $0) }) {
        self.makeCPAClient = makeCPAClient
        guard startAutomatically else { return }
        observePowerState()
        Task { await requestRefresh() }
        if !hasLaunchedBefore {
            hasLaunchedBefore = true
            launchAtStartup = true
        }
    }

    var effectiveRefreshInterval: TimeInterval {
        UsageRefreshPolicy.interval(base: refreshInterval, lowPower: lowPowerMode)
    }

    /// Only the panel and settings window show usage; the status icon is fixed.
    var scheduledRefreshInterval: TimeInterval {
        UsageRefreshPolicy.interval(base: effectiveRefreshInterval, visible: isUsageVisible)
    }

    func isProviderShown(_ provider: DisplayProvider) -> Bool {
        switch provider {
        case .claude: showClaude
        case .codex: showCodex
        case .antigravity: showAntigravity
        case .cursor: showCursor
        case .kimi: showKimi
        case .zai: showZai
        case .xai: showXai
        }
    }

    var hasAnyShownAvailableProvider: Bool {
        DisplayProvider.displayOrder.contains { provider in
            isProviderShown(provider) && availableProviders.contains(provider)
        }
    }

    /// True when turning off `provider` would hide the last authenticated/available provider.
    func isLastVisibleAvailableProvider(_ provider: DisplayProvider) -> Bool {
        guard isProviderShown(provider), availableProviders.contains(provider) else { return false }
        return !DisplayProvider.displayOrder.contains { other in
            other != provider && isProviderShown(other) && availableProviders.contains(other)
        }
    }

    /// Updates a provider's visibility switch while ensuring at least one
    /// available provider remains shown.
    func setProviderShown(_ shown: Bool, for provider: DisplayProvider) {
        objectWillChange.send()
        assignProviderShown(shown, for: provider)
        if !shown, !availableProviders.isEmpty, !hasAnyShownAvailableProvider {
            assignProviderShown(true, for: provider)
        }
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    private func assignProviderShown(_ shown: Bool, for provider: DisplayProvider) {
        switch provider {
        case .claude: showClaude = shown
        case .codex: showCodex = shown
        case .antigravity: showAntigravity = shown
        case .cursor: showCursor = shown
        case .kimi: showKimi = shown
        case .zai: showZai = shown
        case .xai: showXai = shown
        }
    }

    private var enabledProviders: Set<DisplayProvider> {
        Set(DisplayProvider.displayOrder.filter { isProviderShown($0) })
    }

    var hasAntigravityAccounts: Bool {
        cpaAccounts.contains { $0.provider == .antigravity }
    }

    /// Unique Antigravity pools discovered across loaded CPA accounts, in encounter order.
    var discoveredAntigravityPools: [AntigravityPoolOption] {
        var seen: Set<String> = []
        var options: [AntigravityPoolOption] = []
        for account in cpaAccounts where account.provider == .antigravity {
            for group in account.reading?.poolGroups ?? [] {
                if seen.insert(group.id).inserted {
                    options.append(AntigravityPoolOption(id: group.id, label: group.label))
                }
            }
        }
        return options
    }

    func isAntigravityPoolVisible(_ poolID: String) -> Bool {
        !hiddenAntigravityPoolIDs.contains(poolID)
    }

    func toggleAntigravityPool(_ poolID: String) {
        if hiddenAntigravityPoolIDs.contains(poolID) {
            hiddenAntigravityPoolIDs.remove(poolID)
        } else {
            hiddenAntigravityPoolIDs.insert(poolID)
        }
        persistHiddenAntigravityPools()
    }

    func showAllAntigravityPools() {
        guard !hiddenAntigravityPoolIDs.isEmpty else { return }
        hiddenAntigravityPoolIDs.removeAll()
        persistHiddenAntigravityPools()
    }

    private func persistHiddenAntigravityPools() {
        UserDefaults.standard.set(hiddenAntigravityPoolIDs.sorted(), forKey: Self.hiddenAntigravityPoolsDefaultsKey)
        NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
    }

    func usageVisibilityChanged(isVisible: Bool) {
        guard isVisible != isUsageVisible else { return }
        isUsageVisible = isVisible
        providerSettingsChanged()
    }

    func providerSettingsChanged() {
        Task { await requestRefresh() }
    }

    func refresh() async {
        await requestRefresh(manual: true)
    }

    /// Own every refresh task, including timer-triggered work, so suspension can cancel it.
    private func requestRefresh(manual: Bool = false) async {
        pendingRefresh = true
        pendingManualRefresh = pendingManualRefresh || manual
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard autoRefreshEnabled, !isBackgroundSuspended else { return }
        timer?.invalidate()
        timer = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshTask = nil
                scheduleNextRefresh()
            }
            while pendingRefresh && !Task.isCancelled && !isBackgroundSuspended && autoRefreshEnabled {
                let manual = pendingManualRefresh
                pendingRefresh = false
                pendingManualRefresh = false
                await performRefresh(manual: manual)
            }
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(manual: Bool) async {
        isLoading = true
        NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
        defer {
            isLoading = false
            NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
        }
        await refreshCPA(manual: manual)
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        timer = nil
        guard autoRefreshEnabled, !isBackgroundSuspended, refreshTask == nil, isCPAConfigured == true else { return }
        var dates = [discoveryState.nextRefresh(interval: scheduledRefreshInterval)]
        if cpaError == nil {
            dates += cpaAccounts.filter {
                !$0.disabled && !$0.expired && enabledProviders.contains($0.provider)
            }.map { $0.refresh.nextRefresh(interval: scheduledRefreshInterval) }
        }
        let delay = max(1, (dates.min() ?? Date()).timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.requestRefresh() }
        }
        timer?.tolerance = min(delay * 0.1, effectiveRefreshInterval * 0.1)
    }

    func startAutoRefresh() {
        autoRefreshEnabled = true
        Task { await requestRefresh() }
    }

    func stopAutoRefresh() {
        autoRefreshEnabled = false
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        let clamped = max(30, min(600, interval))
        refreshInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.refreshIntervalDefaultsKey)
        scheduleNextRefresh()
    }

    private func observePowerState() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping, isDisplay) in [
            (NSWorkspace.screensDidSleepNotification, true, true),
            (NSWorkspace.screensDidWakeNotification, false, true),
            (NSWorkspace.willSleepNotification, true, false),
            (NSWorkspace.didWakeNotification, false, false)
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isDisplay { self.setDisplayAsleep(sleeping) } else { self.setSystemAsleep(sleeping) }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.powerModeChanged(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        })
    }

    func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        updatePowerState()
    }

    func setSystemAsleep(_ asleep: Bool) {
        systemAsleep = asleep
        updatePowerState()
    }

    func powerModeChanged(lowPower: Bool) {
        lowPowerMode = lowPower
        updatePowerState()
    }

    private func updatePowerState() {
        let suspended = displayAsleep || systemAsleep
        let wasSuspended = isBackgroundSuspended
        isBackgroundSuspended = suspended
        if suspended {
            timer?.invalidate()
            timer = nil
            refreshTask?.cancel()
        } else if wasSuspended {
            Task {
                if let refreshTask { await refreshTask.value }
                await requestRefresh() // Only stale providers are due on wake.
            }
        } else {
            scheduleNextRefresh()
        }
    }

    func testAndSaveCPA(address: String, key: String) async throws {
        let operation = UUID()
        configurationGeneration = operation
        let connection = try CPAConnection(address: address, key: key)
        let client = await makeCPAClient(connection)
        _ = try await client.accounts() // An authenticated empty instance is valid.
        try Task.checkCancellation()
        guard configurationGeneration == operation else { throw CancellationError() }
        try await saveCPAConnection(connection, client: client)
    }

    func clearCPAConfiguration() async throws {
        configurationGeneration = UUID()
        try await saveCPAConnection(nil, client: nil)
    }

    private func saveCPAConnection(_ connection: CPAConnection?, client: CPAClient?) async throws {
        guard !isSavingConnection else { throw CPAError.message("A connection change is already in progress.") }
        isSavingConnection = true
        defer { isSavingConnection = false }
        try await CredentialStorage.shared.saveCPAConnection(connection)
        await replaceCPAClient(with: client)
    }

    private func replaceCPAClient(with client: CPAClient?) async {
        let generation = UUID()
        connectionGeneration = generation
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        cpaClient = client
        isCPAConfigured = client != nil
        cpaAccounts = []
        cpaError = nil
        discoveryState = .init()
        availableProviders = []
        lastUpdated = nil
        NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
        if let refreshTask { await refreshTask.value }
        guard generation == connectionGeneration else { return }
        if client != nil { await requestRefresh(manual: true) }
    }

    private func refreshCPA(manual: Bool) async {
        let generation = connectionGeneration
        if isCPAConfigured == nil {
            let connection = await CredentialStorage.shared.cpaConnection
            let client: CPAClient?
            if let connection {
                client = await makeCPAClient(connection)
            } else {
                client = nil
            }
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            cpaClient = client
            isCPAConfigured = client != nil
        }
        guard let client = cpaClient else { return }
        if discoveryState.isDue(at: Date(), interval: scheduledRefreshInterval, manual: manual) {
            let previousAttempt = discoveryState.lastAttempt
            discoveryState.lastAttempt = Date()
            defer {
                if Task.isCancelled && generation == connectionGeneration {
                    discoveryState.lastAttempt = previousAttempt
                }
            }
            do {
                let discovered = try await client.accounts()
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                let previous = Dictionary(uniqueKeysWithValues: cpaAccounts.map { ($0.id, $0) })
                cpaAccounts = discovered.map { account in
                    var account = account
                    if let old = previous[account.id], old.provider == account.provider, old.identity == account.identity, old.variant == account.variant, old.chatGPTAccountID == account.chatGPTAccountID, old.projectID == account.projectID {
                        account.reading = old.reading
                        account.refresh = old.refresh
                        account.error = old.error
                    }
                    return account
                }
                availableProviders = Set(cpaAccounts.map(\.provider))
                cpaError = nil
                discoveryState.succeeded(at: Date())
            } catch {
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                cpaError = (error as? CPAError)?.errorDescription ?? "Could not connect to CPA. Check its address and transport settings."
                discoveryState.failed(at: Date(), interval: effectiveRefreshInterval, serverRetryAt: (error as? CPAError)?.retryAfter)
                // Rejected management credentials must not be resubmitted per account.
                return
            }
        }
        guard cpaError == nil else { return }
        let due = cpaAccounts.filter {
            !$0.disabled && !$0.expired && enabledProviders.contains($0.provider) &&
            $0.refresh.isDue(at: Date(), interval: scheduledRefreshInterval, manual: manual)
        }
        await withTaskGroup(of: (String, CPAReading?, String?, Date?).self) { group in
            for account in due {
                if let index = cpaAccounts.firstIndex(where: { $0.id == account.id }) { cpaAccounts[index].refresh.lastAttempt = Date() }
                group.addTask {
                    do { return (account.id, try await client.usage(for: account), nil, nil) }
                    catch { return (account.id, nil, (error as? CPAError)?.errorDescription ?? "Could not query this account.", (error as? CPAError)?.retryAfter) }
                }
            }
            for await (id, reading, error, retry) in group {
                guard !Task.isCancelled, generation == connectionGeneration,
                      let index = cpaAccounts.firstIndex(where: { $0.id == id }) else { continue }
                if let reading {
                    cpaAccounts[index].reading = reading
                    cpaAccounts[index].error = nil
                    cpaAccounts[index].refresh.succeeded(at: Date())
                } else {
                    cpaAccounts[index].error = error
                    cpaAccounts[index].refresh.failed(at: Date(), interval: effectiveRefreshInterval, serverRetryAt: retry)
                }
            }
        }
        guard generation == connectionGeneration else { return }
        if Task.isCancelled {
            for account in due {
                if let index = cpaAccounts.firstIndex(where: { $0.id == account.id }) {
                    cpaAccounts[index].refresh.lastAttempt = nil
                }
            }
            return
        }
        lastUpdated = cpaAccounts.compactMap { $0.refresh.lastSuccess }.max()
    }
}
