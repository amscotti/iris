import IrisCore
import IrisProviders

/// Explicit fixture assembly. Application conformance tests independently use
/// AppProviderAssembly, so a provider added only to the app cannot be skipped.
func testProviderRegistry() -> ProviderRegistry {
    var registry = ProviderRegistry()
    registry.register(MetaProvider())
    registry.register(GrokProvider())
    registry.register(MockProvider())
    return registry
}
