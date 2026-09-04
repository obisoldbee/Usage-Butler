import Foundation
import UsageButlerDomain

public enum ProviderDefaults {
    public static let initiallyEnabled: Set<ProviderID> = Set(ProviderID.allCases)
}

public enum ProviderPreferenceKey {
    public static let openAIEnabled = "usageButler.settings.v1.providers.openai.enabled"
    public static let miniMaxEnabled = "usageButler.settings.v1.providers.minimax.enabled"
    public static let arkEnabled = "usageButler.settings.v1.providers.ark.enabled"
    public static let globalRefreshSeconds = "usageButler.settings.v1.defaultRefreshSeconds"
    public static let openAIRefreshOverrideSeconds = "usageButler.settings.v1.providers.openai.refreshOverrideSeconds"
    public static let miniMaxRefreshOverrideSeconds = "usageButler.settings.v1.providers.minimax.refreshOverrideSeconds"
    public static let arkRefreshOverrideSeconds = "usageButler.settings.v1.providers.ark.refreshOverrideSeconds"
    public static let openAIExecutablePath = "usageButler.settings.v1.providers.openai.executablePath"
    public static let miniMaxExecutablePath = "usageButler.settings.v1.providers.minimax.executablePath"
    public static let arkExecutablePath = "usageButler.settings.v1.providers.ark.executablePath"
    public static let globalShortcut = "usageButler.settings.v1.panel.globalShortcut"
    public static let quotaAlertsEnabled = "usageButler.settings.v1.quotaAlerts.enabled"
    public static let larkQuotaAlertChatID = "usageButler.settings.v1.quotaAlerts.larkChatID"
    public static let quotaAlertNotifiedCycles = "usageButler.quotaAlerts.v1.notified"

    public static func refreshOverrideSecondsKey(for providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: openAIRefreshOverrideSeconds
        case .miniMax: miniMaxRefreshOverrideSeconds
        case .ark: arkRefreshOverrideSeconds
        }
    }
}
