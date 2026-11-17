import Foundation

nonisolated enum UsageSource: String, CaseIterable { case direct, cpa }

nonisolated struct CPAConnection: Codable, Equatable {
    let address: String
    let key: String

    init(address: String, key: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CPAError.message("Enter an HTTP or HTTPS base address and management key.")
        }
        self.address = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct CPAWindow: Identifiable {
    let label: String
    let percent: Int
    let reset: Date?
    var id: String { label }
    var resetText: String {
        guard let reset else { return "--" }
        let interval = reset.timeIntervalSinceNow / 60
        guard interval.isFinite, abs(interval) < 10_000_000 else { return "--" }
        let minutes = max(0, Int(interval))
        if minutes == 0 { return "Now" }
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

nonisolated struct CPAReading {
    var plan = ""
    var windows: [CPAWindow]
    var bankedResets: BankedResets?
}

nonisolated struct CPAAccount: Identifiable {
    let id: String
    let provider: DisplayProvider
    let identity: String
    let disabled: Bool
    let expired: Bool
    var variant: String = ""
    var chatGPTAccountID: String?
    var reading: CPAReading?
    var error: String?
    var refresh = ProviderRefreshState()
}

nonisolated enum CPAError: LocalizedError {
    case message(String)
    case http(Int, Date?)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .http(let code, _):
            if code == 401 || code == 403 { return "Authentication rejected. Check the management key or renew this account in CPA." }
            return "Request failed (HTTP \(code))."
        }
    }
    var retryAfter: Date? { if case .http(_, let date) = self { return date }; return nil }
}
