import Foundation

// Joined with CodexAPIService by the runner. All transport and credentials are
// fixtures; these checks cannot read a real credential or contact a provider.
extension CodexAPIService {
    static func verifyBankedResets() async throws {
        let inventory = Data(#"""
        {"available_count":4,"credits":[
          {"status":"available","expires_at":"2026-12-01T00:00:00Z"},
          {"status":"redeemed","expires_at":"2026-01-01T00:00:00Z"},
          {"status":"available","expires_at":"2026-11-06T15:59:00.000Z"},
          {"status":"available","expires_at":"2026-11-06T15:59:00Z"},
          {"status":"available","expires_at":null},
          {"status":"expired","expires_at":"2026-01-01T00:00:00Z"}
        ]}
        """#.utf8)
        let parsed = try CodexBankedResets.parse(inventory)
        precondition(parsed.availableCount == 4 && parsed.expirations?.count == 4)
        let groups = parsed.expirationGroups
        precondition(groups.map(\.count) == [2, 1, 1], "Available resets must group and sort by expiry")
        precondition(groups.last?.expiration == .doesNotExpire, "Explicit null means no expiration")
        let unknown = try CodexBankedResets.parse(Data(#"{"available_count":2,"credits":[{"status":"available","expires_at":"invalid"},{"status":"available"}]}"#.utf8))
        precondition(unknown.expirations == [.unknown, .unknown], "Missing or malformed dates must not mean no expiry")
        let incomplete = try CodexBankedResets.parse(Data(#"{"available_count":3,"credits":[]}"#.utf8))
        precondition(incomplete.availableCount == 3 && incomplete.expirations == nil)
        let empty = try CodexBankedResets.parse(Data(#"{"available_count":0,"credits":[]}"#.utf8))
        precondition(empty.availableCount == 0 && empty.expirations == [])
        for invalid in [#"{"available_count":-1,"credits":[]}"#, #"{"available_count":true,"credits":[]}"#, #"{}"#] {
            do {
                _ = try CodexBankedResets.parse(Data(invalid.utf8))
                preconditionFailure("Invalid reset counts must fail instead of becoming zero")
            } catch {}
        }

        let usagePayload = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":34,"limit_window_seconds":604800}},"rate_limit_reset_credits":{"available_count":3}}"#.utf8)
        for path in ["/backend-api/wham/usage", "/api/codex/usage"] {
            let service = CodexAPIService(sendRequest: { request in
                precondition(request.httpMethod == "GET", "Inventory must only be read")
                precondition(request.url?.path == path.replacingOccurrences(of: "/usage", with: "/rate-limit-reset-credits"))
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
                precondition(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture-account")
                return (inventory, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            var request = URLRequest(url: URL(string: "https://example.test\(path)")!)
            request.httpMethod = "GET"
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            request.setValue("fixture-account", forHTTPHeaderField: "ChatGPT-Account-Id")
            let usage = try service.parseCodexUsageResponse(usagePayload)
            let result = try await service.fetchResetInventory(usage: usage, request: request)
            precondition(result.primaryUsedPercent == 34 && result.primaryIsWeekly)
            precondition(result.bankedResets == parsed, "Detailed inventory must override the usage summary")
        }

        let request = URLRequest(url: URL(string: "https://example.test/backend-api/wham/usage")!)
        for status in [401, 403, 404, 500] {
            let service = CodexAPIService(sendRequest: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            let result = try await service.fetchResetInventory(usage: service.parseCodexUsageResponse(usagePayload), request: request)
            precondition(result.primaryUsedPercent == 34 && result.bankedResets?.availableCount == 3)
            precondition(result.bankedResets?.expirations == nil, "Failed inventory must not fabricate expiry dates")
        }
        var attempts = 0
        let throttled = CodexAPIService(sendRequest: { request in
            attempts += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "3600"])!)
        })
        let usage = try throttled.parseCodexUsageResponse(usagePayload)
        _ = try await throttled.fetchResetInventory(usage: usage, request: request)
        _ = try await throttled.fetchResetInventory(usage: usage, request: request)
        throttled.clearCache()
        _ = try await throttled.fetchResetInventory(usage: usage, request: request)
        precondition(attempts == 1, "Manual refresh must preserve inventory server cooldown")
        let malformed = CodexAPIService(sendRequest: { request in
            (Data(#"{"available_count":3}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let fallback = try await malformed.fetchResetInventory(usage: usage, request: request)
        precondition(fallback.bankedResets?.availableCount == 3 && fallback.bankedResets?.expirations == nil)
        let unavailable = CodexAPIService(sendRequest: { _ in throw URLError(.notConnectedToInternet) })
        let noSummary = CodexUsageData(primaryUsedPercent: 34)
        let unknownResult = try await unavailable.fetchResetInventory(usage: noSummary, request: request)
        precondition(unknownResult.primaryUsedPercent == 34 && unknownResult.bankedResets == nil)
        let cancelled = CodexAPIService(sendRequest: { _ in throw CancellationError() })
        do {
            _ = try await cancelled.fetchResetInventory(usage: usage, request: request)
            preconditionFailure("Inventory cancellation must propagate")
        } catch is CancellationError {}
        print("PASS: banked reset inventory, grouping, malformed fields, GET-only transport, usage fallback, cooldown, cancellation")
    }
}
