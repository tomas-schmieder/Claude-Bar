import Foundation

public enum CodexUsageError: LocalizedError, Sendable {
    case notSignedIn
    case signInExpired
    case http(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Not signed in to Codex. Run `codex login` in Terminal."
        case .signInExpired:
            "Codex sign-in expired. Run `codex login` again."
        case let .http(code):
            "Codex usage request failed (HTTP \(code))."
        case .invalidResponse:
            "Codex returned an unexpected usage response."
        }
    }
}

/// Where the Codex CLI keeps its state (`$CODEX_HOME`, default `~/.codex`).
public enum CodexHome {
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

/// OAuth tokens written by `codex login` to `auth.json`.
struct CodexAuthTokens: Sendable {
    var accessToken: String
    var refreshToken: String?
    var accountID: String?
    var idToken: String?

    static func load(codexHome: URL) -> CodexAuthTokens? {
        let url = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty
        else { return nil }
        return CodexAuthTokens(
            accessToken: access,
            refreshToken: tokens["refresh_token"] as? String,
            accountID: tokens["account_id"] as? String,
            idToken: tokens["id_token"] as? String)
    }

    /// Email claim from the OpenID `id_token`, when present.
    var email: String? {
        guard let idToken, let payload = JWTPayload.decode(idToken) else { return nil }
        return payload["email"] as? String
    }
}

enum JWTPayload {
    static func decode(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Fetches Codex plan limits from the same endpoint the Codex CLI and ChatGPT use (`wham/usage`),
/// authenticated with the tokens in `~/.codex/auth.json`.
///
/// Refreshed access tokens are kept in memory only; `auth.json` stays owned by the Codex CLI.
public actor CodexUsageClient {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let codexHome: URL
    private let session: URLSession
    /// In-memory refreshed token, keyed by the refresh token it came from so a new `codex login` wins.
    private var refreshed: (sourceRefreshToken: String, accessToken: String)?

    public init(codexHome: URL = CodexHome.url(), session: URLSession = .shared) {
        self.codexHome = codexHome
        self.session = session
    }

    public func fetchLimits() async throws -> ProviderLimitSnapshot {
        guard var tokens = CodexAuthTokens.load(codexHome: self.codexHome) else {
            throw CodexUsageError.notSignedIn
        }
        if let refreshed, refreshed.sourceRefreshToken == tokens.refreshToken {
            tokens.accessToken = refreshed.accessToken
        }

        var (data, status) = try await self.requestUsage(tokens: tokens)
        if status == 401 || status == 403 {
            tokens.accessToken = try await self.refreshAccessToken(tokens: tokens)
            (data, status) = try await self.requestUsage(tokens: tokens)
            if status == 401 || status == 403 {
                throw CodexUsageError.signInExpired
            }
        }
        guard status == 200 else { throw CodexUsageError.http(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        return Self.parseUsage(json, email: tokens.email)
    }

    private func requestUsage(tokens: CodexAuthTokens) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar", forHTTPHeaderField: "User-Agent")
        if let accountID = tokens.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func refreshAccessToken(tokens: CodexAuthTokens) async throws -> String {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw CodexUsageError.signInExpired
        }
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              !access.isEmpty
        else {
            throw CodexUsageError.signInExpired
        }
        self.refreshed = (sourceRefreshToken: refreshToken, accessToken: access)
        return access
    }

    static func parseUsage(_ json: [String: Any], email: String?, now: Date = Date()) -> ProviderLimitSnapshot {
        var windows: [NamedRateWindow] = []
        let rateLimit = json["rate_limit"] as? [String: Any]
        if let primary = self.parseWindow(rateLimit?["primary_window"], now: now) {
            windows.append(NamedRateWindow(
                id: "codex-primary",
                title: RateWindowLabel.title(forWindowMinutes: primary.windowMinutes, fallback: "Session"),
                window: primary))
        }
        if let secondary = self.parseWindow(rateLimit?["secondary_window"], now: now) {
            windows.append(NamedRateWindow(
                id: "codex-secondary",
                title: RateWindowLabel.title(forWindowMinutes: secondary.windowMinutes, fallback: "Weekly"),
                window: secondary))
        }
        for (index, entry) in ((json["additional_rate_limits"] as? [[String: Any]]) ?? []).enumerated() {
            let name = (entry["limit_name"] as? String) ?? (entry["metered_feature"] as? String) ?? "Model"
            let limit = entry["rate_limit"] as? [String: Any]
            if let window = self.parseWindow(limit?["primary_window"], now: now) {
                let span = RateWindowLabel.title(forWindowMinutes: window.windowMinutes, fallback: "")
                windows.append(NamedRateWindow(
                    id: "codex-extra-\(index)",
                    title: span.isEmpty ? name : "\(name) · \(span)",
                    window: window))
            }
        }

        var notes: [String] = []
        if let credits = json["credits"] as? [String: Any] {
            let unlimited = (credits["unlimited"] as? Bool) ?? false
            let balance: Double? = if let text = credits["balance"] as? String {
                Double(text)
            } else {
                (credits["balance"] as? NSNumber)?.doubleValue
            }
            if unlimited {
                notes.append("Credits: unlimited")
            } else if let balance, balance > 0 {
                notes.append("Credits: \(UsageFormatter.creditsNumberString(from: balance)) left")
            }
        }

        let plan = (json["plan_type"] as? String).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return ProviderLimitSnapshot(
            windows: windows,
            accountEmail: email,
            planName: plan,
            notes: notes,
            updatedAt: now)
    }

    private static func parseWindow(_ raw: Any?, now: Date) -> RateWindow? {
        guard let window = raw as? [String: Any],
              let used = (window["used_percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let seconds = (window["limit_window_seconds"] as? NSNumber)?.intValue
        let resetsAt: Date? = if let resetAt = (window["reset_at"] as? NSNumber)?.doubleValue, resetAt > 0 {
            Date(timeIntervalSince1970: resetAt)
        } else if let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue {
            now.addingTimeInterval(after)
        } else {
            nil
        }
        return RateWindow(
            usedPercent: min(100, max(0, used)),
            windowMinutes: seconds.map { $0 / 60 },
            resetsAt: resetsAt,
            resetDescription: nil)
    }
}
