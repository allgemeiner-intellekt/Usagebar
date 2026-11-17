import Foundation

/// Reset inventory is separate from purchased credits and ordinary usage windows.
nonisolated struct BankedResets: Equatable {
    enum Expiration: Hashable {
        case at(Date)
        case doesNotExpire
        case unknown
    }

    /// A Claude reset grant. One grant can hold several resets.
    struct Grant: Equatable {
        enum Kind: Equatable {
            case session, weekly, full, fable, unknown

            var title: String {
                switch self {
                case .session: return "5-hour reset"
                case .weekly: return "Weekly reset"
                case .full: return "Full reset"
                case .fable: return "Fable reset"
                case .unknown: return "Reset"
                }
            }
        }

        let id: String
        let kind: Kind
        let label: String
        let left: Int
        let total: Int
        let expiration: Expiration
    }

    let availableCount: Int
    /// Codex: one expiration per available reset. Nil means only the usage endpoint's count was available.
    var expirations: [Expiration]?
    /// Claude: grants with resets left, sorted by expiration.
    var grants: [Grant]?

    struct ExpirationGroup: Identifiable {
        let expiration: Expiration
        let count: Int
        var id: Expiration { expiration }
    }

    var expirationGroups: [ExpirationGroup] {
        Dictionary(grouping: expirations ?? [], by: { $0 }).map {
            ExpirationGroup(expiration: $0.key, count: $0.value.count)
        }.sorted { Self.precedes($0.expiration, $1.expiration) }
    }

    /// One popover or summary row: a Codex expiration group or a Claude grant.
    struct Entry: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let count: Int
        let expiration: Expiration
    }

    /// Nil when only a count is known and details are unavailable.
    var entries: [Entry]? {
        if let grants {
            return grants.map { grant in
                Entry(id: grant.id,
                      title: grant.label.isEmpty ? grant.kind.title : "\(grant.kind.title) · \(grant.label)",
                      detail: "\(grant.left) / \(grant.total) left",
                      count: grant.left, expiration: grant.expiration)
            }
        }
        guard expirations != nil else { return nil }
        return expirationGroups.enumerated().map { index, group in
            Entry(id: "group-\(index)", title: "\(group.count) \(group.count == 1 ? "reset" : "resets")",
                  detail: nil, count: group.count, expiration: group.expiration)
        }
    }

    private static func precedes(_ lhs: Expiration, _ rhs: Expiration) -> Bool {
        switch (lhs, rhs) {
        case let (.at(left), .at(right)): return left < right
        case (.at, _), (.doesNotExpire, .unknown): return true
        default: return false
        }
    }

    static func parse(_ data: Data) throws -> BankedResets {
        let count = try JSONDecoder().decode(CountPayload.self, from: data).availableCount
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], count >= 0,
              let credits = json["credits"] as? [[String: Any]] else {
            throw NSError(domain: "Codex", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid reset inventory"])
        }
        let expirations: [Expiration] = credits.compactMap { credit in
            guard credit["status"] as? String == "available" else { return nil }
            if credit["expires_at"] is NSNull { return .doesNotExpire }
            if let timestamp = credit["expires_at"] as? String,
               let date = ISO8601Timestamp.date(from: timestamp) {
                return .at(date)
            }
            return .unknown
        }
        // The server's count is authoritative. Incomplete details must not invent
        // expiry dates or show historical resets as currently available.
        return BankedResets(availableCount: count,
                            expirations: expirations.count == count ? expirations : nil)
    }

    private struct CountPayload: Decodable {
        let availableCount: Int
        enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
    }

    // MARK: - Claude reset grants

    /// Parses the `cedar_ember` block of `/api/oauth/usage?cedar_ember=1`.
    /// The block is undocumented, so validation follows the CPA management panel:
    /// one malformed grant, a duplicate id, or a bad timestamp rejects the whole block.
    static func parseClaude(_ data: Data, now: Date = Date()) throws -> BankedResets {
        let invalid = NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid reset grants"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["cedar_ember"] as? [String: Any],
              let eligible = strictBool(block["eligible"]) else { throw invalid }
        let rawList: [Any]
        switch block["grants"] {
        case nil, is NSNull: rawList = []
        case let list as [Any]: rawList = list
        default: throw invalid
        }
        let reason = block["ineligible_reason"]
        guard reason == nil || reason is NSNull || reason is String,
              optionalBool(block["at_limit"]) != nil,
              optionalTimestamp(block["weekly_resets_at"]) != nil,
              optionalTimestamp(block["cooldown_until"]) != nil else { throw invalid }

        var grants: [Grant] = []
        var seen: Set<String> = []
        for raw in rawList {
            guard let grant = raw as? [String: Any],
                  let id = grant["id"] as? String, id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  seen.insert(id).inserted,
                  let total = count(grant["resets_total"]), let left = count(grant["resets_left"]), left <= total,
                  optionalTimestamp(grant["starts_at"]) != nil,
                  let ends = optionalTimestamp(grant["ends_at"]),
                  grant["clears"] == nil || grant["clears"] is NSNull || grant["clears"] is [Any],
                  optionalBool(grant["paused"]) != nil,
                  optionalBool(grant["usable_now"]) != nil,
                  optionalBool(grant["use_requires_limit"]) != nil,
                  let fable = optionalBool(grant["gives_back_weekly"]) else { throw invalid }
            // An expired grant is never useful; a missing end date is unknown, not permanent.
            if case .at(let date) = ends, date <= now { continue }
            guard left > 0 else { continue }
            let kind: Grant.Kind
            if fable == true { kind = .fable }
            else {
                switch grant["type"] as? String {
                case "session": kind = .session
                case "weekly": kind = .weekly
                case "full": kind = .full
                default: kind = .unknown
                }
            }
            grants.append(Grant(id: id, kind: kind, label: safeLabel(grant["label"]),
                                left: left, total: total, expiration: ends))
        }
        guard eligible else { return BankedResets(availableCount: 0, grants: []) }
        grants.sort { precedes($0.expiration, $1.expiration) }
        return BankedResets(availableCount: grants.reduce(0) { $0 + $1.left }, grants: grants)
    }

    private static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        isBool(value) ? (value as? Bool) : nil
    }

    /// Absent or null is accepted. The outer nil means the field is malformed.
    private static func optionalBool(_ value: Any?) -> Bool?? {
        if value == nil || value is NSNull { return .some(nil) }
        return strictBool(value).map { .some($0) }
    }

    private static func count(_ value: Any?) -> Int? {
        guard !isBool(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double >= 0, double <= 1_000_000, double == double.rounded() else { return nil }
        return Int(double)
    }

    /// Absent or null is unknown. Nil means the value is present but unparsable.
    private static func optionalTimestamp(_ value: Any?) -> Expiration? {
        if value == nil || value is NSNull { return .unknown }
        guard let text = value as? String, let date = ISO8601Timestamp.date(from: text) else { return nil }
        return .at(date)
    }

    /// Server display text, stripped of control characters and bounded.
    private static func safeLabel(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        return String(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
    }
}
