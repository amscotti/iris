import Foundation
import IrisCore
import IrisProviders

/// Application composition owns default provider assembly.
///
/// `ProviderRegistry()` stays empty so `IrisCore` never hard-codes which
/// concrete providers ship. The app (and previews/tests that need live
/// providers) assemble an explicit registry here. Adding a provider means
/// adding its module plus one `register` line below.
public enum AppProviderAssembly {
    public static var defaultSettings: AppSettings { AppSettings(providerName: MetaProvider().id.name) }
    public static func defaultRegistry() -> ProviderRegistry {
        var registry = ProviderRegistry()
        registry.register(MetaProvider())
        registry.register(GrokProvider())
        #if DEBUG
            registry.register(MockProvider())
        #endif
        return registry
    }
}
