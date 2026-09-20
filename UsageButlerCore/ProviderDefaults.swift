import Foundation
import UsageButlerDomain

public enum ProviderDefaults {
    public static let initiallyEnabled: Set<ProviderID> = Set(ProviderID.allCases)
}

/// UserDefaults keys for network preferences. The store
/// (`UserDefaultsNetworkSettingsStore` in Infrastructure) and the settings UI
/// both reference these constants so the key strings exist exactly once.
public enum NetworkPreferenceKey {
    public static let collectionEnabled = "usageButler.network.v1.collectionEnabled"
    public static let retention = "usageButler.network.v1.historyRetention"
    public static let uploadAlertThresholdBytes = "usageButler.network.v1.uploadAlertThresholdBytes"
    public static let notificationsEnabled = "usageButler.network.v1.notificationsEnabled"
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

    public static func productEnabledKey(for providerID: ProviderID, sourceProductID: String) -> String {
        "usageButler.settings.v1.providers.\(providerID.rawValue).products.\(sourceProductID).enabled"
    }

    public static let arkAgentPlanEnabled = productEnabledKey(for: .ark, sourceProductID: "agent-plan")
    public static let arkCodingPlanEnabled = productEnabledKey(for: .ark, sourceProductID: "coding-plan")

    public static func isProductEnabled(
        providerID: ProviderID,
        sourceProductID: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = productEnabledKey(for: providerID, sourceProductID: sourceProductID)
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }
}
