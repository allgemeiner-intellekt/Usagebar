import Foundation

extension PerformanceRegressionTests {
    static func testCodexBankedResetParsing() throws {
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
        let parsed = try BankedResets.parse(inventory)
        precondition(parsed.availableCount == 4 && parsed.expirations?.count == 4)
        let groups = parsed.expirationGroups
        precondition(groups.map(\.count) == [2, 1, 1], "Available resets must group and sort by expiry")
        precondition(groups.last?.expiration == .doesNotExpire, "Explicit null means no expiration")
        let unknown = try BankedResets.parse(Data(#"{"available_count":2,"credits":[{"status":"available","expires_at":"invalid"},{"status":"available"}]}"#.utf8))
        precondition(unknown.expirations == [.unknown, .unknown], "Missing or malformed dates must not mean no expiry")
        let incomplete = try BankedResets.parse(Data(#"{"available_count":3,"credits":[]}"#.utf8))
        precondition(incomplete.availableCount == 3 && incomplete.expirations == nil)
        let empty = try BankedResets.parse(Data(#"{"available_count":0,"credits":[]}"#.utf8))
        precondition(empty.availableCount == 0 && empty.expirations == [])
        for invalid in [#"{"available_count":-1,"credits":[]}"#, #"{"available_count":true,"credits":[]}"#, #"{}"#] {
            do {
                _ = try BankedResets.parse(Data(invalid.utf8))
                preconditionFailure("Invalid reset counts must fail instead of becoming zero")
            } catch {}
        }
    }
}
