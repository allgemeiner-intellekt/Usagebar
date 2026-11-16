import Foundation

/// Only lists accounts and sends read-only, account-pinned quota requests.
@ProviderActor
final class CPAClient {
    private let connection: CPAConnection
    private let send: @ProviderActor (URLRequest) async throws -> (Data, URLResponse)
    private var version: String?

    init(connection: CPAConnection, send: @escaping @ProviderActor (URLRequest) async throws -> (Data, URLResponse) = {
        try await ProviderHTTP.data(for: $0)
    }) {
        self.connection = connection
        self.send = send
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: connection.address + path) else { throw CPAError.message("Invalid CPA address.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(connection.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CPAError.message("Invalid management response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw CPAError.http(http.statusCode, HTTPRetryAfter.date(from: http))
        }
        return data
    }

    func accounts() async throws -> [CPAAccount] {
        let data: Data
        if let version {
            data = try await request(version == "v8" ? "/v8/management/credentials" : "/v0/management/auth-files")
        } else {
            do {
                data = try await request("/v8/management/credentials")
                version = "v8"
            } catch CPAError.http(let code, _) where code == 404 || code == 405 {
                data = try await request("/v0/management/auth-files")
                version = "v0"
            }
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            throw CPAError.message("Unsupported CPA account-list response.")
        }
        var accounts: [CPAAccount] = []
        var ids: Set<String> = []
        for file in files {
            let name = (file["provider"] as? String ?? file["type"] as? String ?? "").lowercased()
            let provider: DisplayProvider?
            switch name {
            case "claude": provider = .claude
            case "codex": provider = .codex
            case "xai", "grok": provider = .xai
            case "kimi", "kimi-ai": provider = .kimi
            case "cursor": provider = .cursor
            case "zai", "z.ai": provider = .zai
            default: provider = nil
            }
            guard let provider else { continue }
            guard let id = file["auth_index"] as? String, !id.isEmpty, ids.insert(id).inserted else {
                throw CPAError.message("CPA returned an account without a unique request identity.")
            }
            let identity = file["email"] as? String ?? file["name"] as? String ?? file["id"] as? String ?? id
            accounts.append(CPAAccount(id: id, provider: provider, identity: identity,
                disabled: file["disabled"] as? Bool ?? false,
                expired: (file["status"] as? String)?.lowercased() == "expired",
                variant: name, chatGPTAccountID: Self.accountID(file)))
        }
        return accounts.sorted { ($0.identity, $0.id) < ($1.identity, $1.id) }
    }

    func usage(for account: CPAAccount) async throws -> CPAReading {
        let url: String
        var headers = ["Authorization": "Bearer $TOKEN$", "Accept": "application/json"]
        switch account.provider {
        case .codex:
            url = "https://chatgpt.com/backend-api/wham/usage"
            if let id = account.chatGPTAccountID { headers["ChatGPT-Account-Id"] = id }
        case .kimi:
            url = account.variant == "kimi-ai" ? "https://api.kimi.ai/coding/v1/usages" : "https://api.kimi.com/coding/v1/usages"
            headers["X-Msh-Platform"] = "kimi_code_cli"
        case .xai:
            url = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
            headers["x-grok-client-mode"] = "cli"
        case .claude:
            url = "https://api.anthropic.com/api/oauth/usage"
            headers["anthropic-beta"] = "oauth-2025-04-20"
        case .cursor, .zai:
            throw CPAError.message("Quota queries are unsupported for this CPA account authentication.")
        }
        var reading = try Self.parse(await outbound(url: url, account: account, headers: headers), provider: account.provider)
        if account.provider == .codex {
            do {
                let data = try await outbound(url: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", account: account, headers: headers)
                reading.bankedResets = try CodexBankedResets.parse(data)
            } catch {
                try Task.checkCancellation()
                // Optional inventory failure must preserve the valid quota response.
            }
        }
        return reading
    }

    private func outbound(url: String, account: CPAAccount, headers: [String: String]) async throws -> Data {
        guard let version else { throw CPAError.message("Discover accounts before querying quota.") }
        let data = try await request(version == "v8" ? "/v8/management/requests/api-call" : "/v0/management/api-call", body: [
            "auth_index": account.id, "method": "GET", "url": url, "header": headers
        ])
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = envelope["status_code"] as? Int,
              let body = envelope["body"] as? String else { throw CPAError.message("Invalid CPA outbound response.") }
        if !(200..<300).contains(status) {
            let raw = envelope["header"] as? [String: Any] ?? [:]
            var fields: [String: String] = [:]
            for (key, value) in raw {
                fields[key] = (value as? [String])?.first ?? value as? String
            }
            let response = HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: fields)!
            throw CPAError.http(status, HTTPRetryAfter.date(from: response))
        }
        return Data(body.utf8)
    }

    private static func accountID(_ file: [String: Any]) -> String? {
        let containers = [file, file["metadata"] as? [String: Any] ?? [:], file["attributes"] as? [String: Any] ?? [:]]
        for container in containers {
            for key in ["chatgpt_account_id", "chatgptAccountId"] {
                if let id = container[key] as? String, !id.isEmpty { return id }
            }
        }
        for container in containers {
            var claims = container["id_token"] as? [String: Any]
            if let token = container["id_token"] as? String {
                let parts = token.split(separator: ".")
                if parts.count == 3 {
                    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    while payload.count % 4 != 0 { payload += "=" }
                    if let data = Data(base64Encoded: payload) { claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
                }
            }
            let auth = claims?["https://api.openai.com/auth"] as? [String: Any] ?? claims
            if let id = auth?["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    private static func durationLabel(seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1, seconds <= 366 * 86400 else { return nil }
        let value = Int(seconds)
        if value % 86400 == 0 { return "\(value / 86400)d" }
        if value % 3600 == 0 { return "\(value / 3600)h" }
        if value % 60 == 0 { return "\(value / 60)m" }
        return "\(value)s"
    }

    static func parse(_ data: Data, provider: DisplayProvider) throws -> CPAReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CPAError.message("Unsupported quota response.")
        }
        func number(_ value: Any?) -> Double? {
            let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return result.flatMap { $0.isFinite ? $0 : nil }
        }
        func date(_ value: Any?) -> Date? {
            if let text = value as? String { return ISO8601Timestamp.date(from: text) }
            return number(value).flatMap { abs($0) <= 253402300799 ? Date(timeIntervalSince1970: $0) : nil }
        }
        func window(_ label: String, _ percent: Double?, _ reset: Any?) -> CPAWindow? {
            guard let percent else { return nil }
            return CPAWindow(label: label, percent: Int(min(100, max(0, percent)).rounded()), reset: date(reset))
        }
        var windows: [CPAWindow] = []
        var plan = root["plan_type"] as? String ?? ""
        switch provider {
        case .codex:
            if let limits = root["rate_limit"] as? [String: Any] {
                for key in ["primary_window", "secondary_window"] {
                    guard let entry = limits[key] as? [String: Any],
                          let seconds = number(entry["limit_window_seconds"]),
                          let label = durationLabel(seconds: seconds) else { continue }
                    if let value = window(label, number(entry["used_percent"]), entry["reset_at"]) { windows.append(value) }
                }
            }
        case .kimi:
            func detail(_ label: String, _ object: [String: Any]) -> CPAWindow? {
                guard let limit = number(object["limit"]), limit > 0,
                      let used = number(object["used"]) ?? number(object["remaining"]).map({ limit - $0 }) else { return nil }
                return window(label, used / limit * 100, object["resetTime"] ?? object["reset_at"])
            }
            if let usage = root["usage"] as? [String: Any], let value = detail("7d", usage) { windows.append(value) }
            for entry in root["limits"] as? [[String: Any]] ?? [] {
                guard let limit = entry["window"] as? [String: Any],
                      let duration = number(limit["duration"]),
                      let unit = limit["timeUnit"] as? String,
                      let object = entry["detail"] as? [String: Any] else { continue }
                let scale: Double
                switch unit {
                case "TIME_UNIT_SECOND": scale = 1
                case "TIME_UNIT_MINUTE": scale = 60
                case "TIME_UNIT_HOUR": scale = 3600
                case "TIME_UNIT_DAY": scale = 86400
                default: continue
                }
                guard let label = durationLabel(seconds: duration * scale) else { continue }
                if let value = detail(label, object) { windows.append(value) }
            }
        case .xai:
            let config = root["config"] as? [String: Any] ?? root
            let products = config["productUsage"] as? [[String: Any]] ?? []
            let build = products.first { ($0["product"] as? String ?? "").lowercased().contains("build") }
            let percent = number(build?["usagePercent"]) ?? number(config["creditUsagePercent"])
            let period = config["currentPeriod"] as? [String: Any]
            if let value = window("7d", percent, period?["end"] ?? config["billingPeriodEnd"]) { windows.append(value) }
            plan = root["subscriptionTier"] as? String ?? config["subscriptionTier"] as? String ?? ""
        case .claude:
            for (key, label) in [("five_hour", "5h"), ("seven_day", "7d"), ("seven_day_opus", "Opus")] {
                if let entry = root[key] as? [String: Any], let value = window(label, number(entry["utilization"]), entry["resets_at"]) { windows.append(value) }
            }
        default: break
        }
        guard !windows.isEmpty else { throw CPAError.message("Quota data is unsupported or incomplete for this account.") }
        return CPAReading(plan: plan, windows: windows)
    }
}
