import Foundation

/// Only lists accounts and sends read-only, account-pinned quota requests.
@ProviderActor
final class CPAClient {
    private let connection: CPAConnection
    private let send: @ProviderActor (URLRequest) async throws -> (Data, URLResponse)
    private var version: String?
    private var inventoryRetryAt: [String: Date] = [:]
    private var codeAssistRetryAt: [String: Date] = [:]
    private var antigravityHostRetryAt: [String: Date] = [:]
    private var resolvedAntigravityProjectIDs: [String: String] = [:]
    private var subscriptionPlans: [String: (plan: String, fetchedAt: Date)] = [:]
    private var subscriptionPlanRetryAt: [String: Date] = [:]
    /// Plans rarely change, so one profile read covers many quota refreshes.
    private static let subscriptionPlanTTL: TimeInterval = 6 * 3600

    private static let antigravityQuotaURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]
    private static let antigravityCodeAssistURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let antigravityUserAgent = "antigravity/hub/2.23.0 darwin/arm64"
    private static let antigravityCodeAssistBody = #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#

    private struct OutboundResponse {
        let data: Data
        let serverDate: Date?
    }

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
            case "antigravity": provider = .antigravity
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
                variant: name, chatGPTAccountID: Self.accountID(file), projectID: Self.projectID(file)))
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
        case .antigravity:
            return try await antigravityUsage(for: account)
        case .cursor, .zai:
            throw CPAError.message("Quota queries are unsupported for this CPA account authentication.")
        }
        var reading = try Self.parse(await outbound(url: url, account: account, headers: headers).data, provider: account.provider)
        if let plan = try await subscriptionPlan(for: account, headers: headers), !plan.isEmpty {
            reading.plan = plan
        }
        let inventoryKey = account.provider.rawValue + ":" + account.id + ":" + (account.chatGPTAccountID ?? "")
        let inventory: (url: String, headers: [String: String], parse: (Data) throws -> BankedResets)?
        switch account.provider {
        case .codex:
            inventory = ("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers, BankedResets.parse)
        case .claude:
            // Same read-only request as the CPA management panel. The grant program
            // can depend on the client, so identify as Claude Code like that panel does.
            var claudeHeaders = headers
            claudeHeaders["User-Agent"] = "claude-cli/2.1.280 (external, cli)"
            inventory = ("https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1", claudeHeaders, { try BankedResets.parseClaude($0) })
        default:
            inventory = nil
        }
        if let inventory, inventoryRetryAt[inventoryKey, default: .distantPast] <= Date() {
            do {
                let data = try await outbound(url: inventory.url, account: account, headers: inventory.headers).data
                reading.bankedResets = try inventory.parse(data)
                inventoryRetryAt[inventoryKey] = nil
            } catch {
                try Task.checkCancellation()
                if case CPAError.http(let status, let retryAfter) = error, status == 429 || retryAfter != nil {
                    inventoryRetryAt[inventoryKey] = retryAfter ?? Date().addingTimeInterval(120)
                }
                // Keep any count from usage; expiration details remain unavailable.
            }
        }
        return reading
    }

    /// Reads the plan name for providers whose quota response omits it. Failures
    /// keep the last known plan and never prevent quota display.
    private func subscriptionPlan(for account: CPAAccount, headers: [String: String]) async throws -> String? {
        let url: String
        let parse: (Data) -> String?
        switch account.provider {
        case .claude:
            url = "https://api.anthropic.com/api/oauth/profile"
            parse = Self.parseClaudeProfilePlan
        case .kimi:
            url = account.variant == "kimi-ai" ? "https://api.kimi.ai/coding/v1/me" : "https://api.kimi.com/coding/v1/me"
            parse = Self.parseKimiProfilePlan
        default:
            return nil
        }
        let key = account.provider.rawValue + ":" + account.id
        let cached = subscriptionPlans[key]
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.subscriptionPlanTTL { return cached.plan }
        guard subscriptionPlanRetryAt[key, default: .distantPast] <= Date() else { return cached?.plan }
        do {
            let plan = parse(try await outbound(url: url, account: account, headers: headers).data) ?? ""
            subscriptionPlans[key] = (plan, Date())
            subscriptionPlanRetryAt[key] = nil
            return plan
        } catch {
            try Task.checkCancellation()
            var retryAfter = Date().addingTimeInterval(600)
            if case CPAError.http(_, let serverRetry?) = error { retryAfter = max(retryAfter, serverRetry) }
            subscriptionPlanRetryAt[key] = retryAfter
            return cached?.plan
        }
    }

    /// `organization.organization_type` is e.g. `claude_max`; `rate_limit_tier`
    /// distinguishes Max 5x from Max 20x.
    nonisolated static func parseClaudeProfilePlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = root["organization"] as? [String: Any],
              let type = organization["organization_type"] as? String else { return nil }
        let subscription = type.lowercased().hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        return PlanNames.claude(subscriptionType: subscription, rateLimitTier: organization["rate_limit_tier"] as? String)
    }

    /// Kimi's own membership name, e.g. `Allegretto`, so renamed tiers need no app update.
    nonisolated static func parseKimiProfilePlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = safeText(root["user_level_name"], limit: 40)
        return name.isEmpty ? nil : name
    }

    private func fetchAntigravityCodeAssist(for account: CPAAccount, headers: [String: String]) async throws -> (plan: String?, projectID: String?) {
        let codeAssistKey = "antigravity:\(account.id)"
        guard codeAssistRetryAt[codeAssistKey, default: .distantPast] <= Date() else { return (nil, nil) }
        do {
            let response = try await outbound(
                url: Self.antigravityCodeAssistURL,
                method: "POST",
                account: account,
                headers: headers,
                bodyData: Self.antigravityCodeAssistBody
            )
            codeAssistRetryAt[codeAssistKey] = nil
            let parsed = Self.parseAntigravityCodeAssist(response.data)
            if let fallbackProject = parsed.projectID, !fallbackProject.isEmpty {
                resolvedAntigravityProjectIDs[account.id] = fallbackProject
            }
            return parsed
        } catch {
            try Task.checkCancellation()
            if case CPAError.http(let status, let retryAfter) = error, status == 429 || retryAfter != nil {
                codeAssistRetryAt[codeAssistKey] = retryAfter ?? Date().addingTimeInterval(120)
            }
            // Subscription tier is optional; failures never prevent quota display.
            return (nil, nil)
        }
    }

    private func antigravityUsage(for account: CPAAccount) async throws -> CPAReading {
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": Self.antigravityUserAgent
        ]
        let cachedProjectID = account.projectID == nil ? resolvedAntigravityProjectIDs[account.id] : nil
        if let projectID = account.projectID ?? cachedProjectID {
            let poolGroups: [CPAPoolGroup]
            do {
                poolGroups = try await antigravityQuotaGroups(for: account, projectID: projectID, headers: headers)
            } catch {
                try Task.checkCancellation()
                guard cachedProjectID != nil else { throw error }
                let refreshed = try await fetchAntigravityCodeAssist(for: account, headers: headers)
                guard let replacement = refreshed.projectID, replacement != projectID else { throw error }
                let recovered = try await antigravityQuotaGroups(for: account, projectID: replacement, headers: headers)
                return CPAReading(plan: refreshed.plan ?? "", windows: [], poolGroups: recovered)
            }
            let codeAssist = try await fetchAntigravityCodeAssist(for: account, headers: headers)
            return CPAReading(plan: codeAssist.plan ?? "", windows: [], poolGroups: poolGroups)
        }

        let codeAssist = try await fetchAntigravityCodeAssist(for: account, headers: headers)
        guard let projectID = codeAssist.projectID else {
            throw CPAError.message("Antigravity account is missing project_id. Refresh or re-login this account in CPA.")
        }
        let poolGroups = try await antigravityQuotaGroups(for: account, projectID: projectID, headers: headers)
        return CPAReading(plan: codeAssist.plan ?? "", windows: [], poolGroups: poolGroups)
    }

    private func antigravityQuotaGroups(for account: CPAAccount, projectID: String, headers: [String: String]) async throws -> [CPAPoolGroup] {
        let bodyBytes = try JSONSerialization.data(withJSONObject: ["project": projectID])
        let requestBody = String(decoding: bodyBytes, as: UTF8.self)

        var groupOrder: [String] = []
        var mergedGroups: [String: AntigravityParsedGroup] = [:]
        var hadSuccess = false
        var lastError: Error?
        var priorityError: CPAError?
        var earliestHostCooldown: Date?
        var serverTimeOffset: TimeInterval?

        for url in Self.antigravityQuotaURLs {
            try Task.checkCancellation()
            let hostKey = "antigravity:\(account.id):\(url)"
            if let retryAt = antigravityHostRetryAt[hostKey], retryAt > Date() {
                if earliestHostCooldown == nil || retryAt < earliestHostCooldown! {
                    earliestHostCooldown = retryAt
                }
                continue
            }
            do {
                let response = try await outbound(
                    url: url,
                    method: "POST",
                    account: account,
                    headers: headers,
                    bodyData: requestBody
                )
                antigravityHostRetryAt[hostKey] = nil
                hadSuccess = true
                let candidateOffset = serverTimeOffset ?? response.serverDate.map { $0.timeIntervalSinceNow }
                let parsedGroups = Self.parseAntigravityQuotaGroups(response.data, serverTimeOffset: candidateOffset ?? 0)
                guard !parsedGroups.isEmpty else { continue }
                if mergedGroups.isEmpty {
                    serverTimeOffset = candidateOffset
                }
                for group in parsedGroups {
                    if var existing = mergedGroups[group.id] {
                        let existingIDs = Set(existing.buckets.map(\.id))
                        existing.buckets.append(contentsOf: group.buckets.filter { !existingIDs.contains($0.id) })
                        if existing.description == nil { existing.description = group.description }
                        mergedGroups[group.id] = existing
                    } else {
                        groupOrder.append(group.id)
                        mergedGroups[group.id] = group
                    }
                }
                // Daily hosts can return a successful but partial Claude/GPT-only summary.
                // Keep real buckets from each response until a Gemini pool is available.
                let hasGemini = mergedGroups.values.contains { group in
                    group.buckets.contains { $0.id.lowercased().hasPrefix("gemini-") }
                }
                if hasGemini { break }
            } catch {
                try Task.checkCancellation()
                lastError = error
                if case let cpaError as CPAError = error,
                   case .http(let status, let retryAfter) = cpaError {
                    if status == 429 || retryAfter != nil {
                        let deadline = retryAfter ?? Date().addingTimeInterval(120)
                        antigravityHostRetryAt[hostKey] = deadline
                        if earliestHostCooldown == nil || deadline < earliestHostCooldown! {
                            earliestHostCooldown = deadline
                        }
                    }
                    if (status == 401 || status == 403 || status == 404 || status == 429),
                       priorityError == nil {
                        priorityError = cpaError
                    }
                }
            }
        }

        let finalGroups: [CPAPoolGroup] = groupOrder.compactMap { id in
            guard let group = mergedGroups[id], !group.buckets.isEmpty else { return nil }
            let sorted = group.buckets.sorted { lhs, rhs in
                if lhs.kind.sortOrder != rhs.kind.sortOrder { return lhs.kind.sortOrder < rhs.kind.sortOrder }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            let weeklyExhausted = sorted.contains { $0.kind == .weekly && $0.remainingFraction <= 0 }
            let windows = sorted.map { bucket in
                let blocked = weeklyExhausted && bucket.kind == .fiveHour && bucket.percent == 0
                return CPAWindow(
                    id: bucket.id,
                    label: bucket.label,
                    percent: bucket.percent,
                    reset: bucket.reset,
                    blockedByOuterLimit: blocked,
                    detail: blocked ? "Blocked because this pool's weekly limit is exhausted." : nil
                )
            }
            return CPAPoolGroup(id: group.id, label: group.label, description: group.description, windows: windows)
        }

        guard !finalGroups.isEmpty else {
            if !hadSuccess {
                if let error = priorityError ?? lastError { throw error }
                if let earliestHostCooldown { throw CPAError.http(429, earliestHostCooldown) }
            }
            throw CPAError.message("Quota data is unsupported or incomplete for this account.")
        }

        return finalGroups
    }

    private func outbound(url: String, method: String = "GET", account: CPAAccount, headers: [String: String], bodyData: String? = nil) async throws -> OutboundResponse {
        guard let version else { throw CPAError.message("Discover accounts before querying quota.") }
        var body: [String: Any] = [
            "auth_index": account.id, "method": method, "url": url, "header": headers
        ]
        if let bodyData { body["data"] = bodyData }
        let data = try await request(version == "v8" ? "/v8/management/requests/api-call" : "/v0/management/api-call", body: body)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = envelope["status_code"] as? Int,
              let bodyText = envelope["body"] as? String else { throw CPAError.message("Invalid CPA outbound response.") }
        let rawHeaders = envelope["header"] as? [String: Any] ?? [:]
        var fields: [String: String] = [:]
        for (key, value) in rawHeaders {
            if let first = (value as? [String])?.first { fields[key] = first }
            else if let text = value as? String { fields[key] = text }
        }
        if !(200..<300).contains(status) {
            let response = HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: fields)!
            throw CPAError.http(status, HTTPRetryAfter.date(from: response))
        }
        let dateHeader = fields.first { $0.key.caseInsensitiveCompare("Date") == .orderedSame }?.value
        return OutboundResponse(data: Data(bodyText.utf8), serverDate: dateHeader.flatMap(Self.httpDate))
    }

    private static func projectID(_ file: [String: Any]) -> String? {
        let containers = [file, file["metadata"] as? [String: Any] ?? [:], file["attributes"] as? [String: Any] ?? [:]]
        for container in containers {
            for key in ["project_id", "projectId", "gemini_virtual_project"] {
                if let value = container[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated enum AntigravityBucketKind {
        case fiveHour, daily, weekly, monthly, other

        var sortOrder: Int {
            switch self {
            case .fiveHour: return 0
            case .daily: return 1
            case .weekly: return 2
            case .monthly: return 3
            case .other: return 99
            }
        }

        var shortLabel: String? {
            switch self {
            case .fiveHour: return "5h"
            case .daily: return "1d"
            case .weekly: return "7d"
            case .monthly: return "30d"
            case .other: return nil
            }
        }
    }

    private nonisolated struct AntigravityParsedBucket {
        let id: String
        let label: String
        let kind: AntigravityBucketKind
        let percent: Int
        let remainingFraction: Double
        let reset: Date?
    }

    private nonisolated struct AntigravityParsedGroup {
        let id: String
        let label: String
        var description: String?
        var buckets: [AntigravityParsedBucket]
    }

    private nonisolated static func safeText(_ value: Any?, limit: Int = 160) -> String {
        guard let text = value as? String else { return "" }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        return String(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    nonisolated static func stablePoolID(_ value: String, fallback: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? fallback : result
    }

    private nonisolated static func parseAntigravityFraction(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasSuffix("%") {
                guard let pct = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)), pct.isFinite else { return nil }
                return pct / 100.0
            }
            guard let double = Double(trimmed), double.isFinite else { return nil }
            return double
        }
        return nil
    }

    private nonisolated static func classifyAntigravityBucket(label: String, window: String?) -> AntigravityBucketKind {
        func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func stripRemaining(_ text: String) -> String {
            var value = text
            if value.hasSuffix("remaining") {
                value = String(value.dropLast("remaining".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -:"))
            }
            return value
        }
        let normalizedLabel = normalize(label)
        for candidate in [normalizedLabel, stripRemaining(normalizedLabel)] {
            switch candidate {
            case "5 hour limit", "5-hour limit", "five hour limit", "five-hour limit": return .fiveHour
            case "daily limit": return .daily
            case "weekly limit": return .weekly
            case "monthly limit": return .monthly
            default: break
            }
        }
        if let window {
            switch normalize(window) {
            case "5h", "five-hour", "five_hour": return .fiveHour
            case "daily", "day": return .daily
            case "weekly", "week": return .weekly
            case "monthly", "month": return .monthly
            default: break
            }
        }
        return .other
    }

    private nonisolated static func parseAntigravityGroupDescription(groupID: String, raw: Any?) -> String? {
        let cleaned = safeText(raw, limit: 240)
        guard !cleaned.isEmpty else { return nil }
        if let range = cleaned.range(of: "models within this group:", options: [.anchored, .caseInsensitive]) {
            let tail = cleaned[range.upperBound...]
            var models = tail.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if groupID == "gemini-models" {
                let seen = Set(models.map { $0.lowercased() })
                if !seen.contains("gemini argon") {
                    models.append("Gemini Argon")
                }
            }
            return models.isEmpty ? nil : "Models: " + models.joined(separator: ", ")
        }
        return cleaned
    }

    private nonisolated static func unwrapAntigravityRoot(_ data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if root["groups"] != nil || root["currentTier"] != nil || root["current_tier"] != nil || root["paidTier"] != nil || root["paid_tier"] != nil {
            return root
        }
        if let nested = root["body"] as? [String: Any] { return nested }
        if let nestedString = root["body"] as? String,
           let nested = try? JSONSerialization.jsonObject(with: Data(nestedString.utf8)) as? [String: Any] {
            return nested
        }
        return root
    }

    nonisolated static func parseAntigravityCodeAssist(_ data: Data) -> (plan: String?, projectID: String?) {
        guard let root = unwrapAntigravityRoot(data) else { return (nil, nil) }
        func tier(_ value: Any?) -> (id: String, name: String)? {
            guard let object = value as? [String: Any] else { return nil }
            let id = safeText(object["id"], limit: 80)
            let name = safeText(object["name"], limit: 80)
            return (id.isEmpty && name.isEmpty) ? nil : (id, name)
        }
        let paid = tier(root["paidTier"] ?? root["paid_tier"])
        let current = tier(root["currentTier"] ?? root["current_tier"])
        let effective = (paid?.id.isEmpty == false) ? paid : current
        let plan: String?
        if let effective {
            switch effective.id.lowercased() {
            case "free-tier": plan = "Free"
            case "g1-pro-tier": plan = "Pro"
            case "g1-ultra-tier": plan = "Ultra"
            case "g1-ultra-lite-tier": plan = "Ultra Lite"
            default: plan = effective.name.isEmpty ? nil : effective.name
            }
        } else {
            plan = nil
        }

        let rawProject = root["cloudaicompanionProject"] ?? root["cloudaicompanion_project"]
        let projectID: String?
        if let text = rawProject as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            projectID = trimmed.isEmpty ? nil : trimmed
        } else if let object = rawProject as? [String: Any], let id = object["id"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            projectID = trimmed.isEmpty ? nil : trimmed
        } else {
            projectID = nil
        }
        return (plan, projectID)
    }

    private nonisolated static func parseAntigravityQuotaGroups(_ data: Data, serverTimeOffset: TimeInterval = 0) -> [AntigravityParsedGroup] {
        guard let root = unwrapAntigravityRoot(data),
              let rawGroups = root["groups"] as? [[String: Any]] else { return [] }
        let offset = serverTimeOffset.isFinite ? serverTimeOffset : 0
        var parsedGroups: [AntigravityParsedGroup] = []
        for (groupIndex, group) in rawGroups.enumerated() {
            let rawLabel = safeText(group["displayName"] ?? group["display_name"], limit: 120)
            let label = rawLabel.isEmpty ? "Quota Group \(groupIndex + 1)" : rawLabel
            let groupID = stablePoolID(label, fallback: "quota-group-\(groupIndex + 1)")
            let description = parseAntigravityGroupDescription(groupID: groupID, raw: group["description"])
            guard let rawBuckets = group["buckets"] as? [[String: Any]] else { continue }
            var buckets: [AntigravityParsedBucket] = []
            for (bucketIndex, bucket) in rawBuckets.enumerated() {
                guard let fraction = parseAntigravityFraction(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) else { continue }
                let clamped = min(1.0, max(0.0, fraction))
                let usedPercent = Int(((1.0 - clamped) * 100.0).rounded())
                let windowText = safeText(bucket["window"], limit: 40)
                let rawBucketID = safeText(bucket["bucketId"] ?? bucket["bucket_id"], limit: 120)
                let bucketID = rawBucketID.isEmpty ? "\(groupID)-\(windowText.isEmpty ? "bucket" : windowText)-\(bucketIndex + 1)" : rawBucketID
                let displayName = safeText(bucket["displayName"] ?? bucket["display_name"], limit: 120)
                let fallbackLabel = displayName.isEmpty ? (windowText.isEmpty ? bucketID : windowText) : displayName
                let kind = classifyAntigravityBucket(label: fallbackLabel, window: windowText.isEmpty ? nil : windowText)
                let compactLabel = kind.shortLabel ?? String(fallbackLabel.prefix(12))
                let rawReset = (bucket["resetTime"] ?? bucket["reset_time"]) as? String
                let resetDate = rawReset.flatMap(ISO8601Timestamp.date(from:)).map { $0.addingTimeInterval(-offset) }
                buckets.append(AntigravityParsedBucket(
                    id: bucketID,
                    label: compactLabel,
                    kind: kind,
                    percent: min(100, max(0, usedPercent)),
                    remainingFraction: clamped,
                    reset: resetDate
                ))
            }
            guard !buckets.isEmpty else { continue }
            parsedGroups.append(AntigravityParsedGroup(id: groupID, label: label, description: description, buckets: buckets))
        }
        return parsedGroups
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
            guard let percent, percent.isFinite else { return nil }
            return CPAWindow(label: label, percent: Int(min(100, max(0, percent)).rounded()), reset: date(reset))
        }
        var windows: [CPAWindow] = []
        var plan = root["plan_type"] as? String ?? ""
        switch provider {
        case .codex:
            plan = PlanNames.codex(root["plan_type"] as? String)
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
            // Short windows come before the weekly one, matching Claude's 5h-then-7d order.
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
            if let usage = root["usage"] as? [String: Any], let value = detail("7d", usage) { windows.append(value) }
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
        var reading = CPAReading(plan: plan, windows: windows)
        if provider == .codex,
           let resets = root["rate_limit_reset_credits"] as? [String: Any],
           let count = resets["available_count"] as? Int, count >= 0 {
            reading.bankedResets = BankedResets(availableCount: count)
        }
        return reading
    }
}
