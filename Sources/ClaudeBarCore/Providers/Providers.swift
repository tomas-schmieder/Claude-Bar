import Foundation
import SweetCookieKit

// swiftformat:disable sortDeclarations
public enum UsageProvider: String, CaseIterable, Sendable, Codable {
    case claude
}

// swiftformat:enable sortDeclarations

public enum IconStyle: String, Sendable, CaseIterable {
    case claude
    case combined
}

public struct ProviderMetadata: Sendable {
    public let id: UsageProvider
    public let displayName: String
    public let sessionLabel: String
    public let weeklyLabel: String
    public let opusLabel: String?
    public let supportsOpus: Bool
    public let supportsCredits: Bool
    public let creditsHint: String
    public let toggleTitle: String
    public let cliName: String
    public let defaultEnabled: Bool
    public let isPrimaryProvider: Bool
    public let usesAccountFallback: Bool
    public let browserCookieOrder: BrowserCookieImportOrder?
    public let dashboardURL: String?
    public let subscriptionDashboardURL: String?
    /// Provider-specific release notes or changelog URL for CLI/provider updates.
    public let changelogURL: String?
    /// Statuspage.io base URL for incident polling (append /api/v2/status.json).
    public let statusPageURL: String?
    /// Browser-only status link (no API polling); used when statusPageURL is nil.
    public let statusLinkURL: String?
    /// Google Workspace product ID for status polling (appsstatus dashboard).
    public let statusWorkspaceProductID: String?

    public init(
        id: UsageProvider,
        displayName: String,
        sessionLabel: String,
        weeklyLabel: String,
        opusLabel: String?,
        supportsOpus: Bool,
        supportsCredits: Bool,
        creditsHint: String,
        toggleTitle: String,
        cliName: String,
        defaultEnabled: Bool,
        isPrimaryProvider: Bool = false,
        usesAccountFallback: Bool = false,
        browserCookieOrder: BrowserCookieImportOrder? = nil,
        dashboardURL: String?,
        subscriptionDashboardURL: String? = nil,
        changelogURL: String? = nil,
        statusPageURL: String?,
        statusLinkURL: String? = nil,
        statusWorkspaceProductID: String? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.sessionLabel = sessionLabel
        self.weeklyLabel = weeklyLabel
        self.opusLabel = opusLabel
        self.supportsOpus = supportsOpus
        self.supportsCredits = supportsCredits
        self.creditsHint = creditsHint
        self.toggleTitle = toggleTitle
        self.cliName = cliName
        self.defaultEnabled = defaultEnabled
        self.isPrimaryProvider = isPrimaryProvider
        self.usesAccountFallback = usesAccountFallback
        self.browserCookieOrder = browserCookieOrder
        self.dashboardURL = dashboardURL
        self.subscriptionDashboardURL = subscriptionDashboardURL
        self.changelogURL = changelogURL
        self.statusPageURL = statusPageURL
        self.statusLinkURL = statusLinkURL
        self.statusWorkspaceProductID = statusWorkspaceProductID
    }
}

public enum ProviderDefaults {
    public static var metadata: [UsageProvider: ProviderMetadata] {
        [
            .claude: ProviderMetadata(
                id: .claude,
                displayName: "Claude",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: "Sonnet",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Claude Code usage",
                cliName: "claude",
                defaultEnabled: true,
                isPrimaryProvider: true,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://console.anthropic.com/settings/billing",
                subscriptionDashboardURL: "https://claude.ai/settings/usage",
                changelogURL: "https://github.com/anthropics/claude-code/releases",
                statusPageURL: "https://status.claude.com/"),
        ]
    }
}

public enum ProviderBrowserCookieDefaults {
    public static var defaultImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        Browser.defaultImportOrder
        #else
        nil
        #endif
    }

}
