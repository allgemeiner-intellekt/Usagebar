import Foundation

@ProviderActor enum CPAFixture {
    static var requests: [URLRequest] = []
    static var legacy = false
    static var reject = false
    static var empty = false
    static var failDiscovery = false
    static var failQuota = false
    static var delay: UInt64 = 0
    static let files: [[String: Any]] = [
        ["auth_index": "b", "name": "second", "provider": "codex"],
        ["auth_index": "a", "name": "first", "provider": "codex"],
        ["auth_index": "disabled", "name": "disabled", "provider": "kimi", "disabled": true],
        ["auth_index": "expired", "name": "expired", "provider": "xai", "status": "expired"]
    ]
    static func reset() {
        requests = []; legacy = false; reject = false; empty = false
        failDiscovery = false; failQuota = false; delay = 0
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
            precondition(payload["method"] as? String == "GET")
            precondition(["a", "b"].contains(payload["auth_index"] as? String ?? ""), "Queried disabled or expired account")
            let bad = failQuota && payload["auth_index"] as? String == "a"
            status = 200
            body = ["status_code": bad ? 429 : 200, "header": ["Retry-After": ["600"]], "body": bad ? "{}" : "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":0,\"limit_window_seconds\":18000,\"reset_at\":2000000000}}}"]
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
        check(reading.windows.first?.percent == 0, "Zero usage is valid data")
        check(reading.windows.first?.label == "5h", "Window was invented")
        let requests = await CPAFixture.requests
        check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" }, "Missing management authentication")
        let outbound = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        check((outbound["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$", "Did not ask CPA for account credential")
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
        await vm.useDirectSource()
        check(vm.source == .direct && vm.cpaAccounts.isEmpty, "Direct switch retained CPA state")
        check(await CredentialStorage.shared.cpaConnection?.address == "https://empty.invalid", "Switch deleted configuration")
        try await vm.clearCPAConfiguration()
        check(await CredentialStorage.shared.cpaConnection == nil, "Clear kept CPA key")
        vm.stopAutoRefresh()
        print("PASS: CPA discovery, negotiation, authentication, quota normalization, source isolation, stale data, cooldowns and empty setup")
    }
    @ProviderActor private static func setLegacy() { CPAFixture.legacy = true }
    @ProviderActor private static func setReject() { CPAFixture.reject = true }
    @ProviderActor private static func setEmpty() { CPAFixture.empty = true }
    @ProviderActor private static func setFailQuota() { CPAFixture.failQuota = true }
    @ProviderActor private static func setFailDiscovery() { CPAFixture.failDiscovery = true }
}
