import IrisCore

@MainActor
extension DictationRuntime {
    var configuration: ProviderConfiguration { pressBox.current().config }

    public func update(settings: AppSettings, config: ProviderConfiguration) {
        ports.hotkey.update(keyCode: settings.hotkey.keyCode)
        ports.inserter.update(method: settings.insertMethod)
        pressBox.update(settings: settings, config: config)
    }
}
