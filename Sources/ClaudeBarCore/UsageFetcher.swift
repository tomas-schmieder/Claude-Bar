import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?
    /// Whether this window was synthesized to stand in for a quota lane the provider did not actually
    /// report, rather than being a real zero-usage window.
    ///
    /// Claude web returns a `0%` five-hour window when `five_hour` is `null` (an account with no live
    /// session but a real weekly lane). Lane classifiers — e.g. the combined "Session + Weekly" menu-bar
    /// metric — must treat such a window as "no session lane present" instead of surfacing a phantom
    /// `5h 0%`/`5h 100%` session. A genuine session, even one freshly reset to 0%, is NOT a placeholder.
    /// Missing values decode as `false` for older cached payloads.
    public let isSyntheticPlaceholder: Bool

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        nextRegenPercent: Double? = nil,
        isSyntheticPlaceholder: Bool = false)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
        self.isSyntheticPlaceholder = isSyntheticPlaceholder
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowMinutes
        case resetsAt
        case resetDescription
        case nextRegenPercent
        case isSyntheticPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
        self.nextRegenPercent = try container.decodeIfPresent(Double.self, forKey: .nextRegenPercent)
        self.isSyntheticPlaceholder =
            try container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholder) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(self.windowMinutes, forKey: .windowMinutes)
        try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(self.resetDescription, forKey: .resetDescription)
        try container.encodeIfPresent(self.nextRegenPercent, forKey: .nextRegenPercent)
        // Only persist the flag when set, keeping payloads identical for the common (real-window) case.
        if self.isSyntheticPlaceholder {
            try container.encode(true, forKey: .isSyntheticPlaceholder)
        }
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil {
            return self
        }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        let windowMinutes = if let windowMinutes = self.windowMinutes, windowMinutes > 0 {
            windowMinutes
        } else {
            cached?.windowMinutes
        }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            nextRegenPercent: self.nextRegenPercent,
            // Preserve the placeholder marker: backfilling a stale reset onto Claude web's null-session
            // placeholder must not let it masquerade as a real session lane.
            isSyntheticPlaceholder: self.isSyntheticPlaceholder)
    }
}

public struct NamedRateWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let window: RateWindow
    /// Whether `window.usedPercent` reflects known quota usage.
    ///
    /// Some providers expose reset metadata for a named quota window before
    /// they expose remaining usage. Keep those windows visible for reset/debug
    /// context, but mark them so clients do not render `usedPercent` as a real
    /// exhausted quota. Missing values decode as `true` for older cached payloads.
    public let usageKnown: Bool

    public init(id: String, title: String, window: RateWindow, usageKnown: Bool = true) {
        self.id = id
        self.title = title
        self.window = window
        self.usageKnown = usageKnown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case window
        case usageKnown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.window = try container.decode(RateWindow.self, forKey: .window)
        self.usageKnown = try container.decodeIfPresent(Bool.self, forKey: .usageKnown) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.window, forKey: .window)
        if !self.usageKnown {
            try container.encode(false, forKey: .usageKnown)
        }
    }
}

public struct ProviderIdentitySnapshot: Codable, Sendable {
    public let providerID: UsageProvider?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let accountID: String?

    public init(
        providerID: UsageProvider?,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        accountID: String? = nil)
    {
        self.providerID = providerID
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.accountID = accountID
    }

    public func scoped(to provider: UsageProvider) -> ProviderIdentitySnapshot {
        if self.providerID == provider {
            return self
        }
        return ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod,
            accountID: self.accountID)
    }
}

public enum UsageDataConfidence: String, Codable, Equatable, Sendable {
    case exact
    case estimated
    case percentOnly
    case unknown
}

public struct UsageSnapshot: Codable, Sendable {
    public let primary: RateWindow?
    public let secondary: RateWindow?
    public let tertiary: RateWindow?
    public let extraRateWindows: [NamedRateWindow]?
    public let providerCost: ProviderCostSnapshot?
    public let subscriptionExpiresAt: Date?
    public let subscriptionRenewsAt: Date?
    public let updatedAt: Date
    public let identity: ProviderIdentitySnapshot?
    public let dataConfidence: UsageDataConfidence

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case tertiary
        case extraRateWindows
        case providerCost
        case subscriptionExpiresAt
        case subscriptionRenewsAt
        case updatedAt
        case identity
        case dataConfidence
        case accountEmail
        case accountOrganization
        case loginMethod
    }

    public init(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        extraRateWindows: [NamedRateWindow]? = nil,
        providerCost: ProviderCostSnapshot? = nil,
        subscriptionExpiresAt: Date? = nil,
        subscriptionRenewsAt: Date? = nil,
        updatedAt: Date,
        identity: ProviderIdentitySnapshot? = nil,
        dataConfidence: UsageDataConfidence = .unknown)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
        self.providerCost = providerCost
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.updatedAt = updatedAt
        self.identity = identity
        self.dataConfidence = dataConfidence
    }

    public func with(extraRateWindows: [NamedRateWindow]?) -> UsageSnapshot {
        self.replacing(extraRateWindows: .value(extraRateWindows))
    }

    public func with(primary: RateWindow?, secondary: RateWindow?) -> UsageSnapshot {
        self.replacing(
            primary: .value(primary),
            secondary: .value(secondary))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decodeIfPresent(RateWindow.self, forKey: .primary)
        self.secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
        self.tertiary = try container.decodeIfPresent(RateWindow.self, forKey: .tertiary)
        self.extraRateWindows = try container.decodeIfPresent([NamedRateWindow].self, forKey: .extraRateWindows)
        self.providerCost = try container.decodeIfPresent(ProviderCostSnapshot.self, forKey: .providerCost)
        self.subscriptionExpiresAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionExpiresAt)
        self.subscriptionRenewsAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionRenewsAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let dataConfidence = try container.decodeIfPresent(String.self, forKey: .dataConfidence) {
            self.dataConfidence = UsageDataConfidence(rawValue: dataConfidence) ?? .unknown
        } else {
            self.dataConfidence = .unknown
        }
        if let identity = try container.decodeIfPresent(ProviderIdentitySnapshot.self, forKey: .identity) {
            self.identity = identity
        } else {
            let email = try container.decodeIfPresent(String.self, forKey: .accountEmail)
            let organization = try container.decodeIfPresent(String.self, forKey: .accountOrganization)
            let loginMethod = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            if email != nil || organization != nil || loginMethod != nil {
                self.identity = ProviderIdentitySnapshot(
                    providerID: nil,
                    accountEmail: email,
                    accountOrganization: organization,
                    loginMethod: loginMethod)
            } else {
                self.identity = nil
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Stable JSON schema: keep window keys present (encode `nil` as `null`).
        try container.encode(self.primary, forKey: .primary)
        try container.encode(self.secondary, forKey: .secondary)
        try container.encode(self.tertiary, forKey: .tertiary)
        try container.encodeIfPresent(self.extraRateWindows, forKey: .extraRateWindows)
        try container.encodeIfPresent(self.providerCost, forKey: .providerCost)
        try container.encodeIfPresent(self.subscriptionExpiresAt, forKey: .subscriptionExpiresAt)
        try container.encodeIfPresent(self.subscriptionRenewsAt, forKey: .subscriptionRenewsAt)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.identity, forKey: .identity)
        if self.dataConfidence != .unknown {
            try container.encode(self.dataConfidence, forKey: .dataConfidence)
        }
        try container.encodeIfPresent(self.identity?.accountEmail, forKey: .accountEmail)
        try container.encodeIfPresent(self.identity?.accountOrganization, forKey: .accountOrganization)
        try container.encodeIfPresent(self.identity?.loginMethod, forKey: .loginMethod)
    }

    public func identity(for provider: UsageProvider) -> ProviderIdentitySnapshot? {
        guard let identity, identity.providerID == provider else { return nil }
        return identity
    }

    public func switcherWeeklyWindow(for provider: UsageProvider, showUsed: Bool) -> RateWindow? {
        _ = showUsed
        _ = provider
        // This surface is labelled "Weekly progress", so prefer a real 7-day lane when one is
        // available. Some providers publish model-specific weekly lanes in extraRateWindows.
        if let weekly = self.mostConstrainedSwitcherWeeklyWindow() {
            return weekly
        }
        return self.primary ?? self.secondary
    }

    private func mostConstrainedSwitcherWeeklyWindow() -> RateWindow? {
        let standardWindows = [self.primary, self.secondary, self.tertiary].compactMap(\.self)
        let namedWindows = self.extraRateWindows?
            .filter(\.usageKnown)
            .map(\.window) ?? []
        return (standardWindows + namedWindows)
            .filter { $0.windowMinutes == 7 * 24 * 60 }
            .max { $0.usedPercent < $1.usedPercent }
    }

    public func accountEmail(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.accountEmail
    }

    public func accountOrganization(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.accountOrganization
    }

    public func loginMethod(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.loginMethod
    }

    public var hasRateLimitWindows: Bool {
        self.primary != nil || self.secondary != nil || self.tertiary != nil ||
            !(self.extraRateWindows?.isEmpty ?? true)
    }

    public func rateLimitsUnavailable(for provider: UsageProvider) -> Bool {
        UsageLimitsAvailability.resolve(provider: provider, snapshot: self).isUnavailable
    }

    public func withIdentity(_ identity: ProviderIdentitySnapshot?) -> UsageSnapshot {
        self.replacing(identity: .value(identity))
    }

    public func withDataConfidence(_ dataConfidence: UsageDataConfidence) -> UsageSnapshot {
        self.replacing(dataConfidence: .value(dataConfidence))
    }

    public func scoped(to provider: UsageProvider) -> UsageSnapshot {
        guard let identity else { return self }
        let scopedIdentity = identity.scoped(to: provider)
        if scopedIdentity.providerID == identity.providerID {
            return self
        }
        return self.withIdentity(scopedIdentity)
    }

    public func backfillingResetTimes(from cached: UsageSnapshot?, now: Date = .init()) -> UsageSnapshot {
        guard let cached else { return self }
        guard Self.identitiesMatch(self.identity, cached.identity) else { return self }
        let primary = self.primary?.backfillingResetTime(from: cached.primary, now: now)
        let secondary = self.secondary?.backfillingResetTime(from: cached.secondary, now: now)
        let tertiary = self.tertiary?.backfillingResetTime(from: cached.tertiary, now: now)
        if primary == self.primary, secondary == self.secondary, tertiary == self.tertiary {
            return self
        }
        return self.replacing(
            primary: .value(primary),
            secondary: .value(secondary),
            tertiary: .value(tertiary))
    }

    private static func identitiesMatch(_ lhs: ProviderIdentitySnapshot?, _ rhs: ProviderIdentitySnapshot?) -> Bool {
        if lhs == nil, rhs == nil {
            return true
        }
        guard let lhs, let rhs else { return false }
        let lhsAccountID = lhs.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsAccountID = rhs.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsAccountID, let rhsAccountID, !lhsAccountID.isEmpty, !rhsAccountID.isEmpty {
            return lhsAccountID == rhsAccountID
        }
        let lhsEmail = lhs.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsEmail = rhs.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsEmail, let rhsEmail, !lhsEmail.isEmpty, !rhsEmail.isEmpty {
            return lhsEmail == rhsEmail
        }
        return true
    }

    enum Replacement<Value> {
        case unchanged
        case value(Value)

        func resolving(_ current: Value) -> Value {
            switch self {
            case .unchanged: current
            case let .value(value): value
            }
        }
    }

    func replacing(
        primary: Replacement<RateWindow?> = .unchanged,
        secondary: Replacement<RateWindow?> = .unchanged,
        tertiary: Replacement<RateWindow?> = .unchanged,
        extraRateWindows: Replacement<[NamedRateWindow]?> = .unchanged,
        identity: Replacement<ProviderIdentitySnapshot?> = .unchanged,
        dataConfidence: Replacement<UsageDataConfidence> = .unchanged) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary.resolving(self.primary),
            secondary: secondary.resolving(self.secondary),
            tertiary: tertiary.resolving(self.tertiary),
            extraRateWindows: extraRateWindows.resolving(self.extraRateWindows),
            providerCost: self.providerCost,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            updatedAt: self.updatedAt,
            identity: identity.resolving(self.identity),
            dataConfidence: dataConfidence.resolving(self.dataConfidence))
    }
}

public struct AccountInfo: Equatable, Sendable {
    public let email: String?
    public let plan: String?

    public var hasIdentity: Bool {
        self.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            self.plan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}

public enum UsageError: LocalizedError, Sendable {
    case noSessions
    case noRateLimitsFound
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .noSessions:
            "No Claude sessions found yet. Run at least one Claude prompt first."
        case .noRateLimitsFound:
            "Found sessions, but no rate limit events yet."
        case .decodeFailed:
            "Could not parse Claude session log."
        }
    }

    public static func isNoRateLimitsFoundDescription(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) == UsageError.noRateLimitsFound.errorDescription
    }
}

public enum UsageLimitsAvailability: Equatable, Sendable {
    case available
    case unavailable

    public var isUnavailable: Bool {
        self == .unavailable
    }

    public static func resolve(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo? = nil,
        lastErrorDescription: String? = nil) -> Self
    {
        _ = account
        if provider == .claude {
            guard snapshot == nil else { return .available }
            return ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(lastErrorDescription)
                ? .unavailable
                : .available
        }
        return .available
    }
}

/// JWT payload parsing shared by credential-backed account readers.
public enum JWTPayloadParser {
    public static func parse(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payloadPart = parts[1]

        var padded = String(payloadPart)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}
