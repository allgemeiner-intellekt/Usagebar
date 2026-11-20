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
        check(kimiReading.windows.map(\.label) == ["5h", "7d"], "Kimi windows must list 5h before 7d, like Claude")
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

/// Calls happen one at a time, serialized by the awaits in the test.
nonisolated final class ClaudeGrantFixture: @unchecked Sendable {
    var calls: [[String: Any]] = []
    var inventory: (Int, String) = (200, "")
}

nonisolated final class AntigravityFixture: @unchecked Sendable {
    var files: [[String: Any]] = []
    var calls: [[String: Any]] = []
    var paths: [String] = []
    var quotaResponses: [(Int, [String: [String]], String)] = []
    var codeAssistResponse: (Int, [String: [String]], String) = (
        200, [:], #"{"paidTier":{"id":"g1-pro-tier","name":"Pro"}}"#
    )
}

extension PerformanceRegressionTests {
    /// Fixture payloads follow the CPA management panel's `cedar_ember` contract.
    @MainActor static func testClaudeBankedResets() async throws {
        let now = ISO8601Timestamp.date(from: "2026-11-17T00:00:00Z")!
        func block(_ json: String) -> Data { Data("{\"cedar_ember\":\(json)}".utf8) }
        let grants = block(#"""
        {"eligible":true,"ineligible_reason":null,"at_limit":false,"cooldown_until":null,"weekly_resets_at":"2026-11-20T00:00:00Z",
         "next_grant_id":"nov","grants":[
          {"id":"later","type":"session","resets_total":2,"resets_left":2,"ends_at":"2026-12-20T00:00:00Z","clears":["five_hour"]},
          {"id":"nov","type":"full","label":" Fable\u0007 5.2\n launch ","resets_total":1,"resets_left":1,"starts_at":"2026-11-10T21:59:00Z",
           "ends_at":"2026-12-10T22:00:00Z","clears":["five_hour","seven_day"],"paused":false,"usable_now":true,"use_requires_limit":true},
          {"id":"refill","type":"weekly","resets_total":1,"resets_left":1,"gives_back_weekly":true},
          {"id":"spent","type":"weekly","resets_total":1,"resets_left":0,"ends_at":"2026-12-01T00:00:00Z"},
          {"id":"gone","type":"weekly","resets_total":1,"resets_left":1,"ends_at":"2026-10-22T16:00:00Z"}
        ]}
        """#)
        let parsed = try BankedResets.parseClaude(grants, now: now)
        check(parsed.availableCount == 4, "Claude count must sum unexpired resets left")
        check(parsed.grants?.map(\.id) == ["nov", "later", "refill"], "Grants must sort by expiry with unknown dates last")
        check(parsed.grants?.first?.label == "Fable 5.2 launch", "Grant label was not sanitized")
        check(parsed.grants?.map(\.kind) == [.full, .session, .fable], "Grant kind changed")
        check(parsed.grants?.last?.expiration == .unknown, "Missing end date must be unknown, not permanent")
        let entries = parsed.entries!
        check(entries.first?.title == "Full reset · Fable 5.2 launch" && entries.first?.detail == "1 / 1 left", "Grant row text changed")
        check(entries.map(\.count) == [1, 2, 1], "Grant rows must count resets left")

        let ineligible = try BankedResets.parseClaude(block(#"{"eligible":false,"ineligible_reason":"tier","grants":[{"id":"a","resets_total":1,"resets_left":1}]}"#), now: now)
        check(ineligible.availableCount == 0, "Ineligible accounts must hide resets")
        let none = try BankedResets.parseClaude(block(#"{"eligible":true}"#), now: now)
        check(none.availableCount == 0 && none.entries?.isEmpty == true, "Missing grants must mean zero")
        for invalid in [
            #"{"five_hour":{"utilization":1}}"#,
            #"{"cedar_ember":{"eligible":1}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":{}}}"#,
            #"{"cedar_ember":{"eligible":true,"cooldown_until":"soon"}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_total":1,"resets_left":2}]}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_total":1,"resets_left":true}]}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_total":1.5,"resets_left":1}]}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"A b","resets_total":1,"resets_left":1}]}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_total":1,"resets_left":1},{"id":"a","resets_total":1,"resets_left":1}]}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_total":1,"resets_left":1,"ends_at":"never"}]}}"#,
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_total":1,"resets_left":1,"paused":"no"}]}}"#
        ] {
            do {
                _ = try BankedResets.parseClaude(Data(invalid.utf8), now: now)
                preconditionFailure("Malformed reset grants must be unavailable, not zero: \(invalid)")
            } catch {}
        }

        // CPA transport: account-pinned GET with Claude Code identity, failure keeps usage, own cooldown.
        let usage = #"{"five_hour":{"utilization":40,"resets_at":"2026-11-17T03:00:00Z"},"seven_day":{"utilization":10}}"#
        let box = ClaudeGrantFixture()
        box.inventory = (200, String(data: grants, encoding: .utf8)!)
        let connection = try CPAConnection(address: "https://example.invalid", key: "fixture-key")
        let client = await CPAClient(connection: connection, send: { request in
            let response: [String: Any]
            if let body = request.httpBody {
                let call = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                box.calls.append(call)
                precondition(call["method"] as? String == "GET", "Reset grants must only be read")
                if (call["url"] as? String)?.contains("cedar_ember") == true {
                    response = ["status_code": box.inventory.0, "header": ["Retry-After": ["600"]], "body": box.inventory.1]
                } else {
                    response = ["status_code": 200, "body": usage]
                }
            } else {
                response = ["files": [["auth_index": "claude-a", "provider": "claude", "email": "a@example.invalid"]]]
            }
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let account = try await client.accounts()[0]
        let reading = try await client.usage(for: account)
        check(reading.windows.map(\.percent) == [40, 10], "Reset grants changed Claude usage")
        check(reading.bankedResets?.grants?.first?.id == "nov", "CPA Claude reading lost reset grants")
        let call = box.calls.last!
        let headers = call["header"] as? [String: String] ?? [:]
        check(call["url"] as? String == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1", "Reset grant endpoint changed")
        check(call["auth_index"] as? String == "claude-a" && headers["Authorization"] == "Bearer $TOKEN$", "Reset grants lost account context")
        check(headers["anthropic-beta"] == "oauth-2025-04-20" && headers["User-Agent"]?.hasPrefix("claude-cli/") == true, "Reset grants lost Claude Code headers")
        check(!box.calls.contains { ($0["url"] as? String)?.contains("reset_rate_limits") == true }, "Reset grants must never be redeemed")

        box.inventory = (200, #"{"cedar_ember":{"eligible":"yes"}}"#)
        let malformed = try await client.usage(for: account)
        check(malformed.windows.count == 2 && malformed.bankedResets == nil, "Malformed grants must keep usage and show unavailable")
        box.inventory = (429, "{}")
        let limited = try await client.usage(for: account)
        check(limited.windows.count == 2 && limited.bankedResets == nil, "Grant rate limit discarded usage")
        let before = box.calls.count
        _ = try await client.usage(for: account)
        check(box.calls.count == before + 1, "Reset grants ignored server cooldown or blocked usage")
        var row = account
        row.reading = malformed
        check(row.resetInventoryUnavailable, "Multi-account rows must distinguish failed grant reads from zero")
        row.reading = reading
        check(!row.resetInventoryUnavailable, "Grant reads were reported as unavailable")
        row.reading = nil
        check(!row.resetInventoryUnavailable, "Accounts without usage must not report reset failures")
        let kimiRow = CPAAccount(id: "k", provider: .kimi, identity: "k", disabled: false, expired: false,
                                 reading: CPAReading(windows: []))
        check(!kimiRow.resetInventoryUnavailable, "Providers without resets must not report them unavailable")
        print("PASS: Claude reset grants, validation, CPA transport, usage fallback and cooldown")
    }

    @MainActor static func testAntigravityCPA() async throws {
        let box = AntigravityFixture()
        box.files = [
            ["auth_index": "ag-1", "provider": "antigravity", "email": "ag1@example.invalid", "project_id": "proj-1"],
            ["auth_index": "ag-meta", "type": "antigravity", "name": "ag2.json", "metadata": ["project_id": "proj-2"]],
            ["auth_index": "ag-noproj", "provider": "antigravity", "email": "ag3@example.invalid"]
        ]

        let connection = try CPAConnection(address: "https://example.invalid", key: "fixture-key")
        let client = await CPAClient(connection: connection, send: { request in
            let path = request.url!.path
            box.paths.append(path)
            let response: [String: Any]
            if let body = request.httpBody {
                let call = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                box.calls.append(call)
                let url = call["url"] as? String ?? ""
                precondition(call["method"] as? String == "POST", "Antigravity calls must use POST")
                let headers = call["header"] as? [String: String] ?? [:]
                precondition(headers["Authorization"] == "Bearer $TOKEN$", "Missing token placeholder")
                precondition(headers["User-Agent"] == "antigravity/hub/2.23.0 darwin/arm64", "Unexpected Antigravity User-Agent")
                if url.hasSuffix(":loadCodeAssist") {
                    precondition(call["data"] as? String == #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#, "Unexpected loadCodeAssist body")
                    let item = box.codeAssistResponse
                    response = ["status_code": item.0, "header": item.1, "body": item.2]
                } else {
                    let item = box.quotaResponses.isEmpty ? (200, [:], #"{"groups":[]}"#) : box.quotaResponses.removeFirst()
                    response = ["status_code": item.0, "header": item.1, "body": item.2]
                }
            } else {
                response = ["files": box.files]
            }
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let accounts = try await client.accounts()
        check(accounts.count == 3 && accounts.allSatisfy { $0.provider == .antigravity }, "Antigravity accounts not discovered")
        let ag1 = accounts.first { $0.id == "ag-1" }!
        let agMeta = accounts.first { $0.id == "ag-meta" }!
        let agNoProj = accounts.first { $0.id == "ag-noproj" }!
        check(ag1.projectID == "proj-1" && agMeta.projectID == "proj-2" && agNoProj.projectID == nil, "project_id extraction failed")

        // 1) Partial daily response falls back to sandbox and prod, preserves earlier bucket values,
        // merges missing buckets, sorts 5h before 7d, converts to Used %, and flags 5h blocked when weekly is exhausted.
        let futureReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        box.quotaResponses = [
            (200, [:], """
            {"groups":[{"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, GPT-OSS","buckets":[
              {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.0,"resetTime":"\(futureReset)"}
            ]}]}
            """),
            (403, [:], "{}"),
            (200, [:], """
            {"groups":[
              {"displayName":"Claude and GPT models","buckets":[
                {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.4,"resetTime":"\(futureReset)"},
                {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1.0,"resetTime":"\(futureReset)"}
              ]},
              {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
                {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.6,"resetTime":"\(futureReset)"},
                {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.85,"resetTime":"\(futureReset)"}
              ]}
            ]}
            """)
        ]

        let merged = try await client.usage(for: ag1)
        check(merged.plan == "Pro", "Expected Pro plan from loadCodeAssist")
        check(merged.windows.isEmpty && merged.poolGroups.count == 2, "Antigravity must populate poolGroups")
        check(merged.poolGroups.map(\.id) == ["claude-and-gpt-models", "gemini-models"], "Pool encounter order changed")
        let claudePool = merged.poolGroups[0]
        check(claudePool.windows.map(\.label) == ["5h", "7d"], "Buckets must sort 5h before 7d")
        check(claudePool.windows.map(\.percent) == [0, 100], "Must convert remainingFraction to Used % and keep first endpoint value")
        check(claudePool.windows[0].blockedByOuterLimit && !claudePool.windows[1].blockedByOuterLimit, "Exhausted weekly must flag 5h as blocked")
        let geminiPool = merged.poolGroups[1]
        check(geminiPool.description == "Models: Gemini Flash, Gemini Pro, Gemini Argon", "Gemini pool model tooltip mismatch")
        check(geminiPool.windows.map(\.percent) == [15, 40], "Gemini remainingFraction -> Used % mismatch")
        check(geminiPool.windows.allSatisfy { !$0.blockedByOuterLimit }, "Non-exhausted weekly must not dim 5h")
        let quotaURLsHit = box.calls.compactMap { $0["url"] as? String }.filter { $0.contains("retrieveUserQuotaSummary") }
        check(quotaURLsHit.count == 3, "Partial daily summary must probe fallback endpoints until Gemini is present")

        // 2) Early stop when first endpoint already includes Gemini, plus server Date offset adjustment.
        box.calls.removeAll()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let serverAhead = formatter.string(from: Date().addingTimeInterval(3600))
        let resetTwoHoursFromLocal = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        box.quotaResponses = [
            (200, ["Date": [serverAhead]], """
            {"groups":[{"displayName":"Gemini Models","buckets":[
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"resetTime":"\(resetTwoHoursFromLocal)"}
            ]}]}
            """)
        ]
        let fast = try await client.usage(for: agMeta)
        let fastQuotaCalls = box.calls.filter { ($0["url"] as? String)?.contains("retrieveUserQuotaSummary") == true }
        check(fastQuotaCalls.count == 1, "Must stop probing fallback URLs once Gemini pool is present")
        if let adjusted = fast.poolGroups.first?.windows.first?.reset {
            // Server is +1h ahead and reset is +2h from local => ~1h remaining relative to local clock.
            let remaining = adjusted.timeIntervalSinceNow
            check(remaining > 3400 && remaining < 3800, "Server Date header offset was not applied to reset time")
        } else {
            preconditionFailure("Expected parsed reset timestamp")
        }

        // 3) Missing project_id recovers via read-only loadCodeAssist (never downloads auth file), and respects 429 cooldown.
        box.calls.removeAll()
        box.paths.removeAll()
        box.codeAssistResponse = (200, [:], #"{"paidTier":{"id":"g1-ultra-tier"},"cloudaicompanionProject":"recovered-proj"}"#)
        box.quotaResponses = [
            (200, [:], #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.75}]}]}"#)
        ]
        let recovered = try await client.usage(for: agNoProj)
        check(recovered.plan == "Ultra" && recovered.poolGroups.first?.windows.first?.percent == 25, "loadCodeAssist project_id fallback failed")
        check(box.paths.allSatisfy { !$0.contains("download") }, "Usagebar must never download auth files")
        let recoveredQuotaBody = box.calls.last?["data"] as? String ?? ""
        check(recoveredQuotaBody.contains("recovered-proj"), "Recovered project_id was not sent to quota endpoint")

        // 4) loadCodeAssist 429 degrades silently without blocking quota and respects independent cooldown.
        box.calls.removeAll()
        box.codeAssistResponse = (429, ["Retry-After": ["600"]], "{}")
        box.quotaResponses = [
            (200, [:], #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.2}]}]}"#),
            (200, [:], #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.3}]}]}"#)
        ]
        let degraded1 = try await client.usage(for: ag1)
        check(degraded1.plan.isEmpty && degraded1.poolGroups.first?.windows.first?.percent == 80, "loadCodeAssist 429 broke quota")
        let codeAssistCalls1 = box.calls.filter { ($0["url"] as? String)?.contains("loadCodeAssist") == true }.count
        let degraded2 = try await client.usage(for: ag1)
        check(degraded2.poolGroups.first?.windows.first?.percent == 70, "Second quota fetch failed under loadCodeAssist cooldown")
        let codeAssistCalls2 = box.calls.filter { ($0["url"] as? String)?.contains("loadCodeAssist") == true }.count
        check(codeAssistCalls1 == 1 && codeAssistCalls2 == 1, "loadCodeAssist ignored 429 cooldown")

        // 5) Empty/malformed groups across all endpoints errors instead of showing zero.
        box.quotaResponses = [
            (200, [:], #"{"groups":[]}"#),
            (200, [:], #"{"groups":[{"displayName":"Bad","buckets":[{"bucketId":"x","remainingFraction":true}]}]}"#),
            (200, [:], #"{}"#)
        ]
        do {
            _ = try await client.usage(for: ag1)
            preconditionFailure("Empty Antigravity groups must throw an error")
        } catch {}

        // 6) ViewModel global hide-list persistence and Direct mode silence.
        let vm = UsageViewModel(startAutomatically: false, makeCPAClient: { _ in client })
        await FakeProviders.reset()
        await vm.refresh()
        check(!vm.availableProviders.contains(.antigravity), "Direct mode must stay silent for Antigravity")

        box.codeAssistResponse = (200, [:], #"{"currentTier":{"id":"free-tier"}}"#)
        box.files = [
            ["auth_index": "ag-1", "provider": "antigravity", "email": "ag1@example.invalid", "project_id": "proj-1"]
        ]
        box.quotaResponses = [
            (200, [:], """
            {"groups":[
              {"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9}]},
              {"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":0.5}]}
            ]}
            """)
        ]
        try await vm.testAndEnableCPA(address: connection.address, key: connection.key)
        check(vm.discoveredAntigravityPools.map(\.id) == ["gemini-models", "claude-and-gpt-models"], "Discovered pools mismatch")
        check(vm.isAntigravityPoolVisible("gemini-models") && vm.isAntigravityPoolVisible("claude-and-gpt-models"), "New pools must be visible by default")
        vm.toggleAntigravityPool("gemini-models")
        check(!vm.isAntigravityPoolVisible("gemini-models") && vm.isAntigravityPoolVisible("claude-and-gpt-models"), "Pool toggle failed")
        // Verify persistence in UserDefaults across a fresh ViewModel instance.
        let reloaded = UsageViewModel(startAutomatically: false, makeCPAClient: { _ in client })
        check(!reloaded.isAntigravityPoolVisible("gemini-models") && reloaded.isAntigravityPoolVisible("argon"), "Hidden pool must persist while unseen upstream pools stay visible")
        vm.showAllAntigravityPools()
        check(vm.hiddenAntigravityPoolIDs.isEmpty, "Show All Pools did not clear hidden set")
        try await vm.clearCPAConfiguration()
        vm.stopAutoRefresh()
        reloaded.stopAutoRefresh()
        print("PASS: Antigravity CPA fallback/merge, Used %, weekly-exhausted 5h, loadCodeAssist cooldown, and pool hide-list")
    }
}

extension UsageViewModel {
    fileprivate func refreshIfStaleForCPA() async { await requestRefresh() }
}
