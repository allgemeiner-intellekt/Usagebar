import Foundation

/// Reset inventory is separate from purchased credits and ordinary usage windows.
nonisolated struct CodexBankedResets: Equatable {
    enum Expiration: Hashable {
        case at(Date)
        case doesNotExpire
        case unknown
    }

    let availableCount: Int
    /// Nil means only the usage endpoint's count was available.
    var expirations: [Expiration]?

    struct ExpirationGroup: Identifiable {
        let expiration: Expiration
        let count: Int
        var id: Expiration { expiration }
    }

    var expirationGroups: [ExpirationGroup] {
        Dictionary(grouping: expirations ?? [], by: { $0 }).map {
            ExpirationGroup(expiration: $0.key, count: $0.value.count)
        }.sorted { lhs, rhs in
            switch (lhs.expiration, rhs.expiration) {
            case let (.at(left), .at(right)): return left < right
            case (.at, _), (.doesNotExpire, .unknown): return true
            default: return false
            }
        }
    }

    static func parse(_ data: Data) throws -> CodexBankedResets {
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
        return CodexBankedResets(availableCount: count,
                                expirations: expirations.count == count ? expirations : nil)
    }

    private struct CountPayload: Decodable {
        let availableCount: Int
        enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
    }
}

// MARK: - Codex API Service

