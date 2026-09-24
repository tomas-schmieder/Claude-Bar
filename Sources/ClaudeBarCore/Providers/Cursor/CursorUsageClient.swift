import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public enum CursorUsageError: LocalizedError, Sendable {
    case notSignedIn
    case sessionExpired
    case http(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Not signed in to Cursor. Open the Cursor app and sign in."
        case .sessionExpired:
            "Cursor session expired. Open the Cursor app to refresh it."
        case let .http(code):
            "Cursor usage request failed (HTTP \(code))."
        case let .invalidResponse(detail):
            "Cursor returned an unexpected response (\(detail))."
        }
    }
}

/// Session credentials borrowed from the signed-in Cursor desktop app.
struct CursorSession: Sendable {
    let accessToken: String
    let userID: String
    let email: String?

    /// Cookie the cursor.com dashboard expects: `WorkosCursorSessionToken=<user>::<jwt>`.
    var cookieHeader: String {
        "WorkosCursorSessionToken=\(self.userID)%3A%3A\(self.accessToken)"
    }

    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func load(databaseURL: URL = CursorSession.defaultDatabaseURL) throws -> CursorSession {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let token = CursorStateDatabase.value(for: "cursorAuth/accessToken", databaseURL: databaseURL)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let payload = JWTPayload.decode(token),
              let subject = payload["sub"] as? String,
              let userID = subject.split(separator: "|").last.map(String.init),
              !userID.isEmpty
        else {
            throw CursorUsageError.notSignedIn
        }
        if let exp = (payload["exp"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: exp) < Date()
        {
            throw CursorUsageError.sessionExpired
        }
        let email = (payload["email"] as? String)
            ?? CursorStateDatabase.value(for: "cursorAuth/cachedEmail", databaseURL: databaseURL)
        return CursorSession(accessToken: token, userID: userID, email: email)
    }
}

/// Read-only access to Cursor's VS Code-style key/value store.
enum CursorStateDatabase {
    static func value(for key: String, databaseURL: URL) -> String? {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &statement, nil)
            == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
        #else
        _ = key
        _ = databaseURL
        return nil
        #endif
    }
}

/// Fetches Cursor plan usage and per-request token events from the cursor.com dashboard API,
/// authenticated with the Cursor desktop app's session.
public struct CursorUsageClient: Sendable {
    private let baseURL = URL(string: "https://cursor.com")!
    private let session: URLSession
    private let databaseURL: URL?

    public init(session: URLSession = .shared) {
        self.session = session
        self.databaseURL = nil
    }

    init(session: URLSession, databaseURL: URL) {
        self.session = session
        self.databaseURL = databaseURL
    }

    private func loadSession() throws -> CursorSession {
        if let databaseURL {
            return try CursorSession.load(databaseURL: databaseURL)
        }
        return try CursorSession.load()
    }

    // MARK: Limits

    public func fetchLimits(now: Date = Date()) async throws -> ProviderLimitSnapshot {
        let session = try self.loadSession()
        var request = URLRequest(url: self.baseURL.appendingPathComponent("api/usage-summary"), timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        let data = try await self.perform(request)
        let summary: CursorUsageSummary
        do {
            summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse("usage summary")
        }
        let email = await self.fetchEmail(session: session) ?? session.email
        return Self.limits(from: summary, email: email, now: now)
    }

    private func fetchEmail(session: CursorSession) async -> String? {
        var request = URLRequest(url: self.baseURL.appendingPathComponent("api/auth/me"), timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        guard let data = try? await self.perform(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }

    static func limits(from summary: CursorUsageSummary, email: String?, now: Date) -> ProviderLimitSnapshot {
        let parser = TimestampParser()
        let cycleStart = summary.billingCycleStart.flatMap(parser.parse)
        let cycleEnd = summary.billingCycleEnd.flatMap(parser.parse)
        let cycleMinutes: Int? = if let cycleStart, let cycleEnd, cycleEnd > cycleStart {
            Int(cycleEnd.timeIntervalSince(cycleStart) / 60)
        } else {
            nil
        }
        func window(_ percent: Double) -> RateWindow {
            RateWindow(
                usedPercent: min(100, max(0, percent)),
                windowMinutes: cycleMinutes,
                resetsAt: cycleEnd,
                resetDescription: nil)
        }

        let plan = summary.individualUsage?.plan
        var windows: [NamedRateWindow] = []
        // Cursor reports these as percentages already (0.36 means 0.36%).
        let totalPercent: Double? = if let total = plan?.totalPercentUsed {
            total
        } else if let used = plan?.used, let limit = plan?.limit, limit > 0 {
            Double(used) / Double(limit) * 100
        } else if let overall = summary.individualUsage?.overall, let used = overall.used,
                  let limit = overall.limit, limit > 0
        {
            Double(used) / Double(limit) * 100
        } else {
            nil
        }
        if let totalPercent {
            windows.append(NamedRateWindow(id: "cursor-total", title: "Included usage", window: window(totalPercent)))
        }
        if let auto = plan?.autoPercentUsed {
            windows.append(NamedRateWindow(id: "cursor-auto", title: "Auto + Composer", window: window(auto)))
        }
        if let api = plan?.apiPercentUsed {
            windows.append(NamedRateWindow(id: "cursor-api", title: "API models", window: window(api)))
        }

        var notes: [String] = []
        if let used = plan?.used, let limit = plan?.limit, limit > 0 {
            notes.append("Included: \(UsageFormatter.usdString(Double(used) / 100)) of \(UsageFormatter.usdString(Double(limit) / 100))")
        }
        if let onDemand = summary.individualUsage?.onDemand, onDemand.enabled != false, let used = onDemand.used, used > 0 {
            if let limit = onDemand.limit, limit > 0 {
                notes.append("On-demand: \(UsageFormatter.usdString(Double(used) / 100)) of \(UsageFormatter.usdString(Double(limit) / 100))")
            } else {
                notes.append("On-demand: \(UsageFormatter.usdString(Double(used) / 100))")
            }
        }
        if summary.isUnlimited == true {
            notes.append("Unlimited plan")
        }

        return ProviderLimitSnapshot(
            windows: windows,
            accountEmail: email,
            planName: summary.membershipType.map { $0.replacingOccurrences(of: "_", with: " ").capitalized },
            notes: notes,
            updatedAt: now)
    }

    // MARK: Token history

    public func fetchHistory(historyDays: Int = 30, now: Date = Date()) async throws -> TokenUsageHistory {
        let session = try self.loadSession()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(max(1, historyDays) - 1), to: today) ?? today

        let pageSize = 500
        var accumulator = TokenUsageAccumulator()
        for page in 1...40 {
            try Task.checkCancellation()
            var request = URLRequest(
                url: self.baseURL.appendingPathComponent("api/dashboard/get-filtered-usage-events"),
                timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
            // Cursor enforces CSRF on dashboard POSTs; the Origin must match.
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "page": page,
                "pageSize": pageSize,
                "startDate": String(Int64(since.timeIntervalSince1970 * 1000)),
                "endDate": String(Int64(now.timeIntervalSince1970 * 1000)),
            ])
            let data = try await self.perform(request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CursorUsageError.invalidResponse("usage events")
            }
            let events = (json["usageEventsDisplay"] as? [[String: Any]]) ?? []
            for event in events {
                Self.add(event: event, to: &accumulator, calendar: calendar)
            }
            if events.count < pageSize {
                break
            }
        }
        return accumulator.history(
            sinceKey: TokenUsageDayKey.key(from: since, calendar: calendar),
            updatedAt: now,
            sourceDescription: "cursor.com usage events (API list price)")
    }

    static func add(event: [String: Any], to accumulator: inout TokenUsageAccumulator, calendar: Calendar) {
        func number(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return Double(text) }
            return nil
        }
        guard let timestampMS = number(event["timestamp"]), timestampMS > 0,
              let usage = event["tokenUsage"] as? [String: Any]
        else { return }

        var totals = TokenUsageAccumulator.Totals()
        totals.input = max(0, Int(number(usage["inputTokens"]) ?? 0))
        totals.output = max(0, Int(number(usage["outputTokens"]) ?? 0))
        totals.cacheWrite = max(0, Int(number(usage["cacheWriteTokens"]) ?? 0))
        totals.cacheRead = max(0, Int(number(usage["cacheReadTokens"]) ?? 0))
        guard totals.total > 0 else { return }
        // `totalCents` is the token cost at vendor list prices (what the request would cost via API).
        if let cents = number(usage["totalCents"]), cents.isFinite, cents >= 0 {
            totals.costUSD = cents / 100
        }

        let date = Date(timeIntervalSince1970: timestampMS / 1000)
        let model = (event["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        accumulator.add(dayKey: TokenUsageDayKey.key(from: date, calendar: calendar), model: model, totals: totals)
    }

    // MARK: HTTP

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return data
        case 401, 403:
            throw CursorUsageError.sessionExpired
        default:
            throw CursorUsageError.http(status)
        }
    }
}

// MARK: - API models

struct CursorUsageSummary: Decodable, Sendable {
    struct Individual: Decodable, Sendable {
        let plan: Plan?
        let onDemand: Budget?
        let overall: Budget?
    }

    struct Plan: Decodable, Sendable {
        let used: Int?
        let limit: Int?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct Budget: Decodable, Sendable {
        let enabled: Bool?
        let used: Int?
        let limit: Int?
    }

    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let individualUsage: Individual?
}
