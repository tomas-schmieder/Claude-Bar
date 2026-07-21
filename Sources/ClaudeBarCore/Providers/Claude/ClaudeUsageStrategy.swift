import Foundation

/// Usage-source preference used by Claude planning and the debug CLI.
public struct ClaudeUsageStrategy: Equatable, Sendable {
    public let dataSource: ClaudeUsageDataSource
    public let useWebExtras: Bool

    public init(dataSource: ClaudeUsageDataSource, useWebExtras: Bool) {
        self.dataSource = dataSource
        self.useWebExtras = useWebExtras
    }
}

/// Lightweight OAuth availability check extracted from the old provider-descriptor graph.
public enum ClaudeOAuthPlanningAvailability {
    public static func isAvailable(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        environment: [String: String]) -> Bool
    {
        _ = runtime
        let hasEnvironmentOAuthToken = !(environment[ClaudeOAuthCredentialsStore.environmentTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        if hasEnvironmentOAuthToken {
            return true
        }

        let nonInteractiveRecord = try? ClaudeOAuthCredentialsStore.loadRecord(
            environment: environment,
            allowKeychainPrompt: false,
            respectKeychainPromptCooldown: true,
            allowClaudeKeychainRepairWithoutPrompt: false)
        let nonInteractiveCredentials = nonInteractiveRecord?.credentials
        let hasRequiredScopeWithoutPrompt = nonInteractiveCredentials?.scopes.contains("user:profile") == true
        if hasRequiredScopeWithoutPrompt, nonInteractiveCredentials?.isExpired == false {
            return true
        }

        let claudeCLIAvailable = ClaudeCLIResolver.isAvailable(environment: environment)

        if let nonInteractiveRecord, hasRequiredScopeWithoutPrompt, nonInteractiveRecord.credentials.isExpired {
            switch nonInteractiveRecord.owner {
            case .codexbar:
                let refreshToken = nonInteractiveRecord.credentials.refreshToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if sourceMode == .auto {
                    return !refreshToken.isEmpty
                }
                return true
            case .claudeCLI:
                guard sourceMode == .auto else { return true }
                guard claudeCLIAvailable else { return false }
                guard ProviderInteractionContext.current == .background else { return true }
                guard !KeychainAccessGate.isDisabled,
                      ClaudeOAuthKeychainPromptPreference.storedMode() == .always
                else {
                    return false
                }
                return !ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                    interaction: ProviderInteractionContext.current,
                    environment: environment)
            case .environment:
                return sourceMode != .auto
            }
        }

        guard sourceMode == .auto else { return true }

        let promptPolicyApplicable = ClaudeOAuthKeychainPromptPreference.isApplicable()
        if ProviderInteractionContext.current == .userInitiated {
            _ = ClaudeOAuthKeychainAccessGate.clearDenied()
        }

        if promptPolicyApplicable,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return false
        }
        return ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
    }
}
