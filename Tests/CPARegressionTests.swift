import Foundation

@ProviderActor enum CPAFixture {
    static var requests: [URLRequest] = []
    static var legacy = false
    static var reject = false
    static var empty = false
    static var failDiscovery = false
    static var failQuota = false
    static var delay: UInt64 = 0
    static var quotaDelay: UInt64 = 0
    static var quotaEntered = false
    static var quotaWaiter: CheckedContinuation<Void, Never>?
    static var inventoryLimited = false

    static func waitForQuota() async {
        if quotaEntered { return }
        await withCheckedContinuation { quotaWaiter = $0 }
    }
    static var files: [[String: Any]] = [
        ["auth_index": "b", "name": "second", "provider": "codex"],
        ["auth_index": "a", "name": "first", "provider": "codex", "id_token": ["chatgpt_account_id": "workspace-a"]],
        ["auth_index": "disabled", "name": "disabled", "provider": "kimi", "disabled": true],
        ["auth_index": "expired", "name": "expired", "provider": "xai", "status": "expired"]
    ]
    static func reset() {
        requests = []; legacy = false; reject = false; empty = false
        failDiscovery = false; failQuota = false; delay = 0; quotaDelay = 0; quotaEntered = false; inventoryLimited = false
    }
    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        let path = request.url!.path
        let status: Int
        let body: [String: Any]
        if reject { status = 401; body = [:] }
        else if legacy && path.hasPrefix("/v8") { status = 404; body = [:] }
        else if path.hasSuffix("credentials") || path.hasSuffix("auth-files") {
            status = failDiscovery ? 503 : 200
            body = ["files": empty ? [] : files]
        } else {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if quotaDelay > 0 {
                quotaEntered = true
                quotaWaiter?.resume(); quotaWaiter = nil
                try? await Task.sleep(nanoseconds: quotaDelay)
            }
            precondition(payload["method"] as? String == "GET")
            precondition(["a", "b"].contains(payload["auth_index"] as? String ?? ""), "Queried disabled or expired account")
            let bad = failQuota && payload["auth_index"] as? String == "a"
            status = 200
            let inventory = (payload["url"] as? String)?.hasSuffix("rate-limit-reset-credits") == true
            if payload["auth_index"] as? String == "a" {
                precondition((payload["header"] as? [String: String])?["ChatGPT-Account-Id"] == "workspace-a", "Lost account context")
            }
            if inventory, inventoryLimited {
                body = ["status_code": 429, "header": ["Retry-After": ["600"]], "body": "{}"]
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if inventory {
                body = ["status_code": 200, "body": "{\"available_count\":1,\"credits\":[{\"status\":\"available\",\"expires_at\":null}]}"]
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            body = ["status_code": bad ? 429 : 200, "header": ["Retry-After": ["600"]], "body": bad ? "{}" : "{\"plan_type\":\"plus\",\"rate_limit_reset_credits\":{\"available_count\":3},\"rate_limit\":{\"primary_window\":{\"used_percent\":0,\"limit_window_seconds\":18000,\"reset_at\":2000000000}}}"]
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

extension PerformanceRegressionTests {
    @MainActor static func testCPA() async throws {
        await CPAFixture.reset()
        let connection = try CPAConnection(address: "https://example.invalid", key: "fixture-key")
        let client = await CPAClient(connection: connection, send: CPAFixture.send)
        let accounts = try await client.accounts()
        check(accounts.count == 4, "Discovery lost accounts")
        check(accounts.map(\.identity) == ["disabled", "expired", "first", "second"], "Account order changed")
        let reading = try await client.usage(for: accounts.first { $0.id == "a" }!)
        check(reading.bankedResets?.availableCount == 1, "Missing reset inventory")
        check(reading.windows.first?.percent == 0, "Zero usage is valid data")
        check(reading.windows.first?.label == "5h", "Window was invented")
        let requests = await CPAFixture.requests
        check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" }, "Missing management authentication")
        let outbound = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        check((outbound["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$", "Did not ask CPA for account credential")
        await setInventoryLimited()
        let fallback = try await client.usage(for: accounts.first { $0.id == "a" }!)
        check(fallback.bankedResets?.availableCount == 3 && fallback.bankedResets?.expirations == nil, "Inventory failure lost usage reset count")
        let beforeCooldown = await CPAFixture.requests.count
        _ = try await client.usage(for: accounts.first { $0.id == "a" }!)
        check(await CPAFixture.requests.count == beforeCooldown + 1, "Inventory ignored server cooldown or blocked ordinary usage")
        let other = try await client.usage(for: accounts.first { $0.id == "b" }!)
        check(other.windows.count == 1, "Inventory cooldown blocked another account")
        await CPAFixture.reset()
        await setLegacy()
        let oldClient = await CPAClient(connection: connection, send: CPAFixture.send)
        _ = try await oldClient.accounts()
        _ = try await oldClient.accounts()
        check(await CPAFixture.requests.filter { $0.url!.path.hasPrefix("/v8") }.count == 1, "Repeated version probing")
        await CPAFixture.reset()
        await setReject()
        let rejected = await CPAClient(connection: connection, send: CPAFixture.send)
        do { _ = try await rejected.accounts(); fatalError("Rejected key passed") } catch {}
        check(await CPAFixture.requests.count == 1, "Rejected key triggered legacy probe")
        await CPAFixture.reset()
        do { _ = try await CPAClient.parse(Data("{}".utf8), provider: .codex); fatalError("Incomplete quota became zero") } catch {}

        let huge = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":0,\"limit_window_seconds\":1e100}}}".utf8)
        do { _ = try await CPAClient.parse(huge, provider: .codex); fatalError("Oversized duration accepted") } catch {}
        let kimi = Data("{\"usage\":{\"used\":1,\"limit\":10},\"limits\":[{\"window\":{\"duration\":300,\"timeUnit\":\"TIME_UNIT_MINUTE\"},\"detail\":{\"used\":2,\"limit\":10}}]}".utf8)
        let kimiReading = try await CPAClient.parse(kimi, provider: .kimi)
        check(kimiReading.windows.last?.label == "5h", "Kimi minute duration was not normalized")
        check(CPAWindow(label: "x", percent: 0, reset: Date(timeIntervalSince1970: 1e100)).resetText == "--", "Unbounded reset")

        let regional = await CPAClient(connection: connection, send: { request in
            let response: [String: Any]
            if let body = request.httpBody {
                let call = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                precondition(call["url"] as? String == "https://api.kimi.ai/coding/v1/usages", "Kimi regional endpoint was lost")
                response = ["status_code": 200, "body": "{\"usage\":{\"limit\":10,\"used\":2}}"]
            } else {
                response = ["files": [["auth_index": "regional", "provider": "kimi-ai", "name": "regional"]]]
            }
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let regionalAccounts = try await regional.accounts()
        let regionalReading = try await regional.usage(for: regionalAccounts[0])
        check(regionalReading.windows.first?.percent == 20, "Regional Kimi usage failed")

        let vm = UsageViewModel(startAutomatically: false, makeCPAClient: { CPAClient(connection: $0, send: CPAFixture.send) })
        vm.showCodex = true; vm.showKimi = true; vm.showXai = true
        await FakeProviders.reset()
        try await vm.testAndEnableCPA(address: connection.address, key: connection.key)
        check(vm.source == .cpa && vm.cpaAccounts.count == 4, "CPA source not enabled")
        check(await FakeProviders.probes == 0, "CPA discovered local credentials")
        let success = vm.cpaAccounts.first { $0.id == "a" }!.refresh.lastSuccess
        await setFailQuota()
        await vm.refresh()
        let stale = vm.cpaAccounts.first { $0.id == "a" }!
        check(stale.reading != nil && stale.error != nil && stale.refresh.lastSuccess == success, "Failure erased or advanced stale reading")
        check(vm.cpaAccounts.first { $0.id == "b" }!.error == nil, "One account blocked another")
        let count = await CPAFixture.requests.count
        await vm.refresh()
        let newRequests = await CPAFixture.requests.dropFirst(count)
        check(!newRequests.contains { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("\"a\"") == true }, "Manual refresh ignored account cooldown")
        await setFailDiscovery()
        await vm.refresh()
        check(vm.cpaAccounts.count == 4 && vm.cpaError != nil, "Failed discovery erased accounts")
        await setReject()
        do { try await vm.testAndEnableCPA(address: "https://other.invalid", key: "bad"); fatalError("Failed setup enabled") } catch {}
        check(vm.source == .cpa && vm.cpaAccounts.count == 4, "Failed setup replaced working source")
        await CPAFixture.reset()
        await setEmpty()
        try await vm.testAndEnableCPA(address: "https://empty.invalid", key: "key")
        check(vm.source == .cpa && vm.cpaAccounts.isEmpty, "Empty authenticated instance must pass")
        await CPAFixture.reset()
        try await vm.testAndEnableCPA(address: connection.address, key: connection.key)
        let steady = await CPAFixture.requests.count
        await vm.refreshIfStaleForCPA()
        check(await CPAFixture.requests.count == steady, "CPA refreshed fresh data")
        let originalFiles = await CPAFixture.files
        await replaceFiles([originalFiles.first { $0["auth_index"] as? String == "b" }!])
        await vm.refresh()
        check(vm.cpaAccounts.map(\.id) == ["b"], "Successful discovery did not remove accounts")
        await replaceFiles(originalFiles)
        await vm.refresh()
        check(vm.cpaAccounts.count == 4, "Successful discovery did not add accounts")
        vm.powerModeChanged(lowPower: true)
        check(vm.scheduledRefreshInterval == 1500, "CPA ignored hidden Low Power cadence")
        vm.usageVisibilityChanged(isVisible: true)
        check(vm.scheduledRefreshInterval == 300, "CPA ignored visible Low Power cadence")
        vm.powerModeChanged(lowPower: false)
        check(vm.scheduledRefreshInterval == 120, "CPA visible cadence changed")
        vm.usageVisibilityChanged(isVisible: false)
        await setDelay()
        let late = Task { await vm.refresh() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await vm.useDirectSource()
        await late.value
        check(vm.source == .direct && vm.cpaAccounts.isEmpty, "Late CPA response leaked into direct source")
        await CPAFixture.reset()
        try await vm.testAndEnableCPA(address: connection.address, key: connection.key)
        await setQuotaDelay()
        let waitForQuota = Task { await CPAFixture.waitForQuota() }
        await Task.yield()
        let quotaRefresh = Task { await vm.refresh() }
        await waitForQuota.value
        await vm.useDirectSource()
        await quotaRefresh.value
        check(vm.source == .direct && vm.cpaAccounts.isEmpty, "Late quota response leaked after source switch")
        await CPAFixture.reset()
        try await vm.testAndEnableCPA(address: connection.address, key: connection.key)
        await setDelay()
        let sleeping = Task { await vm.refresh() }
        try await Task.sleep(nanoseconds: 20_000_000)
        vm.setSystemAsleep(true)
        await sleeping.value
        check(vm.cpaAccounts.allSatisfy { $0.refresh.consecutiveFailures == 0 }, "Sleep became an account failure")
        vm.setSystemAsleep(false)
        await CPAFixture.reset()
        await vm.useDirectSource()
        check(vm.source == .direct && vm.cpaAccounts.isEmpty, "Direct switch retained CPA state")
        check(await CredentialStorage.shared.cpaConnection?.address == connection.address, "Switch deleted configuration")
        try await vm.clearCPAConfiguration()
        check(await CredentialStorage.shared.cpaConnection == nil, "Clear kept CPA key")
        vm.stopAutoRefresh()
        print("PASS: CPA discovery, negotiation, authentication, quota normalization, source isolation, stale data, cooldowns and empty setup")
    }
    @ProviderActor private static func setQuotaDelay() { CPAFixture.quotaDelay = 100_000_000 }
    @ProviderActor private static func setInventoryLimited() { CPAFixture.inventoryLimited = true }
    @ProviderActor private static func replaceFiles(_ value: [[String: Any]]) { CPAFixture.files = value }
    @ProviderActor private static func setDelay() { CPAFixture.delay = 100_000_000 }
    @ProviderActor private static func setLegacy() { CPAFixture.legacy = true }
    @ProviderActor private static func setReject() { CPAFixture.reject = true }
    @ProviderActor private static func setEmpty() { CPAFixture.empty = true }
    @ProviderActor private static func setFailQuota() { CPAFixture.failQuota = true }
    @ProviderActor private static func setFailDiscovery() { CPAFixture.failDiscovery = true }
}

extension UsageViewModel {
    fileprivate func refreshIfStaleForCPA() async { await requestRefresh() }
}
