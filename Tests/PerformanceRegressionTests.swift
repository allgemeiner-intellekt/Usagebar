import Foundation

@main
struct PerformanceRegressionTests {
    @MainActor static func main() async throws {
        guard Bundle.main.bundleIdentifier == "dev.usagebar.performance-tests" else {
            fatalError("Tests require their isolated preferences domain")
        }
        // A run that trapped leaves its preferences behind.
        UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests")
        defer { UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests") }
        try await testCPA()
        try await testClaudeBankedResets()
        try await testAntigravityCPA()
        testRefreshPolicy()
        testRetryAfter()
        try testCodexBankedResetParsing()
        await testProviderHTTP()
        print("PASS: refresh cadence, retry headers, reset inventory parsing, and request sessions")
    }

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func testRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        check(UsageRefreshPolicy.interval(base: 120, lowPower: false) == 120, "Normal cadence changed")
        check(UsageRefreshPolicy.interval(base: 120, lowPower: true) == 300, "Low Power Mode must reduce polls")
        check(UsageRefreshPolicy.interval(base: 600, lowPower: true) == 600, "Respect slower user cadence")
        check(UsageRefreshPolicy.interval(base: 120, visible: true) == 120, "Visible reading slowed down")
        check(UsageRefreshPolicy.interval(base: 120, visible: false) == 600, "Hidden reading kept the visible cadence")
        var state = ProviderRefreshState()
        check(state.isDue(at: now, interval: 120, manual: false), "Initial data must fetch")
        state.lastAttempt = now
        state.succeeded(at: now)
        check(!state.isDue(at: now.addingTimeInterval(119), interval: 120, manual: false), "Refetched fresh usage")
        check(state.isDue(at: now.addingTimeInterval(120), interval: 120, manual: false), "Missed stale usage")
        let hidden = UsageRefreshPolicy.interval(base: 120, visible: false)
        check(!state.isDue(at: now.addingTimeInterval(130), interval: hidden, manual: false), "Hidden reading kept the visible cadence")
        check(state.isDue(at: now.addingTimeInterval(130), interval: 120, manual: false), "Reading stayed stale once shown")
        state.failed(at: now, interval: 120, serverRetryAt: nil)
        check(state.retryAt == now.addingTimeInterval(120), "First retry delay")
        state.failed(at: now, interval: 120, serverRetryAt: nil)
        check(state.retryAt == now.addingTimeInterval(240), "Repeated failure did not back off")
        check(state.isDue(at: now, interval: 120, manual: true), "Manual refresh cannot bypass local delay")
        state.failed(at: now, interval: 120, serverRetryAt: now.addingTimeInterval(3600))
        check(!state.isDue(at: now.addingTimeInterval(3599), interval: 120, manual: true), "Manual refresh ignored server cooldown")
        check(state.isDue(at: now.addingTimeInterval(3600), interval: 120, manual: true), "Server cooldown never expires")
        for _ in 0..<20 { state.failed(at: now, interval: 120, serverRetryAt: nil) }
        check(state.retryAt == now.addingTimeInterval(1800), "Unbounded local backoff")
        state.succeeded(at: now)
        check(state.retryAt == nil && state.consecutiveFailures == 0, "Success did not clear failures")
    }

    static func testRetryAfter() {
        let now = Date(timeIntervalSince1970: 0)
        func response(_ value: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value])!
        }
        check(HTTPRetryAfter.date(from: response("300"), now: now) == now.addingTimeInterval(300), "Numeric Retry-After")
        check(HTTPRetryAfter.date(from: response("Thu, 01 Jan 1970 00:05:00 GMT"), now: now) == now.addingTimeInterval(300), "Date Retry-After")
        check(HTTPRetryAfter.date(from: response("Thu, 01 Jan 1970 00:00:00 GMT"), now: now.addingTimeInterval(60)) == now.addingTimeInterval(60), "Past retry date")
        for value in ["garbage", "-1", "nan", "inf"] {
            check(HTTPRetryAfter.date(from: response(value), now: now) == nil, "Invalid retry value accepted: \(value)")
        }
        check(ISO8601Timestamp.date(from: "1970-01-01T00:05:00Z") == now.addingTimeInterval(300), "Plain timestamp")
        check(ISO8601Timestamp.date(from: "1970-01-01T00:05:00.500Z") == now.addingTimeInterval(300.5), "Fractional timestamp")
        check(ISO8601Timestamp.date(from: "soon") == nil, "Invalid timestamp accepted")
    }

    /// Overlapping and repeated requests must never reach a session that was already closed.
    static func testProviderHTTP() async {
        // Nothing listens on this port, so every request fails without leaving the Mac.
        let request = URLRequest(url: URL(string: "https://127.0.0.1:9/")!)
        for _ in 0..<2 {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<4 {
                    group.addTask { (try? await ProviderHTTP.data(for: request, timeout: 2)) == nil }
                }
                for await failed in group {
                    check(failed, "Reached a server that should not exist")
                }
            }
        }
    }
}
