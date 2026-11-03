//
//  CodexAPIService.swift
//  JustaUsageBar
//
//  Reads Codex/OpenAI credentials and fetches usage
//

import Foundation

// MARK: - Codex Usage Data Model

nonisolated struct CodexUsageData {
    var planType: String = "unknown"
    var primaryUsedPercent: Int = 0
    var primaryResetAt: Date?
    var primaryWindowSeconds: Int = 18000
    var secondaryUsedPercent: Int = 0
    var secondaryResetAt: Date?
    var hasCredits: Bool = false
    var creditBalance: Double?
    var isUnlimited: Bool = false
    var bankedResets: CodexBankedResets?

    /// True once Codex's primary window is the weekly one (the old 5h window
    /// was retired upstream); the separate secondary weekly is redundant then.
    var primaryIsWeekly: Bool {
        primaryWindowSeconds >= 7 * 24 * 3600
    }

    var primaryWindowLabel: String {
        if primaryIsWeekly { return "W" }
        let hours = primaryWindowSeconds / 3600
        return "\(hours)h"
    }

    var timeUntilPrimaryReset: String {
        guard let resetAt = primaryResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    var timeUntilSecondaryReset: String {
        guard let resetAt = secondaryResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let now = Date()
        guard date > now else { return "Now" }
        let interval = date.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static let placeholder = CodexUsageData()
}

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
            throw APIError.decodingError(NSError(domain: "Codex", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid reset inventory"]))
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

@ProviderActor
final class CodexAPIService {
    static let shared = CodexAPIService()

    private let oauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let tokenEndpoint = "https://auth.openai.com/oauth/token"

    nonisolated struct CodexCredentials {
        var accessToken: String
        var refreshToken: String?
        var accountId: String?
        var lastRefresh: Date?
        var isApiKey: Bool = false
    }

    private var cachedCredentials: CodexCredentials?
    private var lastCredentialCheck: Date?
    private let credentialCacheTTL: TimeInterval = 300
    private var resetInventoryRetryAt: Date?
    private let sendRequest: @ProviderActor (URLRequest) async throws -> (Data, URLResponse)

    private init(sendRequest: @escaping @ProviderActor (URLRequest) async throws -> (Data, URLResponse) = {
        try await ProviderHTTP.data(for: $0)
    }) {
        self.sendRequest = sendRequest
    }

    // MARK: - Credential Discovery

    func loadCredentials() -> CodexCredentials? {
        if let lastCredentialCheck,
           Date().timeIntervalSince(lastCredentialCheck) < credentialCacheTTL {
            return cachedCredentials
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? homeDir.appendingPathComponent(".codex")

        let authPath = codexHome.appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authPath.path),
              let data = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedCredentials = nil
            lastCredentialCheck = Date()
            return nil
        }

        // API key format
        if let apiKey = json["OPENAI_API_KEY"] as? String {
            let creds = CodexCredentials(accessToken: apiKey, isApiKey: true)
            cachedCredentials = creds
            lastCredentialCheck = Date()
            return creds
        }

        // OAuth format
        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String {
            let refreshToken = tokens["refresh_token"] as? String
            let accountId = tokens["account_id"] as? String
            var lastRefresh: Date?
            if let lastRefreshStr = json["last_refresh"] as? String {
                let formatter = ISO8601DateFormatter()
                lastRefresh = formatter.date(from: lastRefreshStr)
            }

            let creds = CodexCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountId: accountId,
                lastRefresh: lastRefresh
            )
            cachedCredentials = creds
            lastCredentialCheck = Date()
            return creds
        }

        cachedCredentials = nil
        lastCredentialCheck = Date()
        return nil
    }

    var hasCredentials: Bool {
        loadCredentials() != nil
    }

    func clearCache() {
        cachedCredentials = nil
        lastCredentialCheck = nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> CodexUsageData {
        guard var creds = loadCredentials() else {
            throw APIError.noCredentials
        }

        // Check if refresh needed (>8 days since last refresh)
        if !creds.isApiKey,
           let lastRefresh = creds.lastRefresh,
           Date().timeIntervalSince(lastRefresh) > 8 * 86400,
           let refreshToken = creds.refreshToken {
            creds = try await refreshAccessToken(refreshToken: refreshToken)
            cachedCredentials = creds
        }

        let baseURL = getBaseURL()
        let usageURL: String
        if baseURL.contains("chatgpt.com") {
            usageURL = "\(baseURL)/backend-api/wham/usage"
        } else {
            usageURL = "\(baseURL)/api/codex/usage"
        }

        guard let url = URL(string: usageURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Usagebar/1.0", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await sendRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }

        switch httpResponse.statusCode {
        case 200:
            return try await fetchResetInventory(usage: parseCodexUsageResponse(data), request: request)
        case 429:
            throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: httpResponse))
        case 401, 403:
            if let refreshToken = creds.refreshToken, !creds.isApiKey {
                do {
                    let newCreds = try await refreshAccessToken(refreshToken: refreshToken)
                    cachedCredentials = newCreds
                    var retryRequest = request
                    retryRequest.setValue("Bearer \(newCreds.accessToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await sendRequest(retryRequest)
                    if let http = retryResponse as? HTTPURLResponse, http.statusCode == 429 {
                        throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: http))
                    }
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                        clearCache()
                        throw APIError.unauthorized
                    }
                    return try await fetchResetInventory(usage: parseCodexUsageResponse(retryData), request: retryRequest)
                } catch let error as APIError where error.isRateLimited {
                    throw error
                } catch let error where isRequestCancelled(error) {
                    throw CancellationError()
                } catch {
                    clearCache()
                    throw APIError.unauthorized
                }
            }
            clearCache()
            throw APIError.unauthorized
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    /// Best-effort, read-only inventory. A failure must not discard valid usage.
    private func fetchResetInventory(usage: CodexUsageData, request: URLRequest) async throws -> CodexUsageData {
        guard !Task.isCancelled else { throw CancellationError() }
        guard resetInventoryRetryAt.map({ $0 <= Date() }) ?? true,
              let usageURL = request.url else { return usage }
        var request = request
        request.url = usageURL.deletingLastPathComponent().appendingPathComponent("rate-limit-reset-credits")
        do {
            let (data, response) = try await sendRequest(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { return usage }
            if http.statusCode == 429 {
                resetInventoryRetryAt = HTTPRetryAfter.date(from: http) ?? Date().addingTimeInterval(120)
                return usage
            }
            guard http.statusCode == 200 else { return usage }
            var usage = usage
            usage.bankedResets = try CodexBankedResets.parse(data)
            resetInventoryRetryAt = nil
            return usage
        } catch {
            if isRequestCancelled(error) || Task.isCancelled { throw CancellationError() }
            return usage
        }
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(refreshToken: String) async throws -> CodexCredentials {
        guard let url = URL(string: tokenEndpoint) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": oauthClientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await sendRequest(request)

        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: http))
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.unauthorized
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw APIError.decodingError(NSError(domain: "Codex", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh response"]))
        }

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? refreshToken,
            accountId: cachedCredentials?.accountId,
            lastRefresh: Date()
        )
    }

    // MARK: - Parse Response

    private func parseCodexUsageResponse(_ data: Data) throws -> CodexUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }

        var usage = CodexUsageData()
        usage.planType = json["plan_type"] as? String ?? "unknown"
        if let resets = json["rate_limit_reset_credits"] as? [String: Any],
           let count = resets["available_count"] as? Int, count >= 0 {
            usage.bankedResets = CodexBankedResets(availableCount: count)
        }

        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                if let pct = primary["used_percent"] as? Double {
                    usage.primaryUsedPercent = Int(pct)
                } else if let pct = primary["used_percent"] as? Int {
                    usage.primaryUsedPercent = pct
                }
                if let resetAt = primary["reset_at"] as? Double {
                    usage.primaryResetAt = Date(timeIntervalSince1970: resetAt)
                }
                if let windowSec = primary["limit_window_seconds"] as? Int {
                    usage.primaryWindowSeconds = windowSec
                }
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                if let pct = secondary["used_percent"] as? Double {
                    usage.secondaryUsedPercent = Int(pct)
                } else if let pct = secondary["used_percent"] as? Int {
                    usage.secondaryUsedPercent = pct
                }
                if let resetAt = secondary["reset_at"] as? Double {
                    usage.secondaryResetAt = Date(timeIntervalSince1970: resetAt)
                }
            }
        }

        if let credits = json["credits"] as? [String: Any] {
            usage.hasCredits = credits["has_credits"] as? Bool ?? false
            usage.isUnlimited = credits["unlimited"] as? Bool ?? false
            usage.creditBalance = credits["balance"] as? Double
        }

        return usage
    }

    private func getBaseURL() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? homeDir.appendingPathComponent(".codex")
        let configPath = codexHome.appendingPathComponent("config.toml")

        if let content = try? String(contentsOf: configPath, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("chatgpt_base_url") {
                    let parts = trimmed.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let value = parts[1].trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !value.isEmpty { return value }
                    }
                }
            }
        }

        return "https://chatgpt.com"
    }
}
