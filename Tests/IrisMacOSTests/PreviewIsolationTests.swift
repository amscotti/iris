#if DEBUG
    import Foundation
    import Testing

    @testable import IrisCore
    @testable import IrisMacOS
    import IrisProviders

    @Test @MainActor func settingsPreviewEditsStayInPrivateStoresAndUseOfflineServices() async throws {
        let edited = SettingsPreview.makeEnvironment()
        let untouched = SettingsPreview.makeEnvironment()
        defer {
            edited.connections.invalidate("Meta")
            untouched.connections.invalidate("Meta")
        }
        do {
            #expect(edited.isSettingsPreview)
            #expect(untouched.isSettingsPreview)
            let originalSettings = untouched.settings
            let originalRaw = try #require(try untouched.settingsRepository.rawPayload())
            try await AsyncDeadline.run(seconds: 5) { await edited.start() }
            #expect(edited.runtime.isStarted)
            #expect(!edited.runtime.isMonitoring)
            #expect(edited.resolvedConfiguration.apiKey == "preview-only")
            #expect(edited.permissions.microphoneGranted)
            #expect(edited.permissions.accessibilityGranted)
            #expect(!edited.startupLimited)
            var notices: [DictationNotice] = []
            let originalNotice = edited.runtime.onNotice
            edited.runtime.onNotice = {
                originalNotice?($0)
                notices.append($0)
            }

            let savedRaw = try exercisePreviewSettingsIsolation(
                edited: edited, untouched: untouched,
                originalSettings: originalSettings, originalRaw: originalRaw)
            try await exerciseOfflinePreviewSecretIsolation(edited: edited, untouched: untouched)
            #expect(try edited.settingsRepository.rawPayload() == savedRaw)
            #expect(try untouched.settingsRepository.rawPayload() == originalRaw)
            untouched.retrySettingsLoad()
            #expect(untouched.settings == originalSettings)
            #expect(edited.settings.providerConfigs["Meta"]?["apiKey"] == nil)
            #expect(!edited.permissionOperationInProgress)
            #expect(!edited.runtime.isMonitoring)
            #expect(!edited.requiresRelaunch)
            #expect(edited.settingsWindowController == nil)
            #expect(notices.isEmpty)
        } catch {
            await edited.stop()
            await untouched.stop()
            throw error
        }
        await edited.stop()
        await untouched.stop()
        #expect(edited.inputState == .stopped)
        #expect(untouched.inputState == .stopped)
    }

    @MainActor
    private func exercisePreviewSettingsIsolation(
        edited: AppEnvironment, untouched: AppEnvironment,
        originalSettings: AppSettings, originalRaw: Data
    ) throws -> Data {
        var settings = edited.settings
        settings.insertMethod = .paste
        settings.hotkey.keyCode = 54
        settings.trailingSpace = !originalSettings.trailingSpace
        edited.saveSettings(settings)
        edited.setProviderValue(key: "languageBias", value: "French", provider: "Meta")
        let savedRaw = try #require(try edited.settingsRepository.rawPayload())
        #expect(try JSONDecoder().decode(AppSettings.self, from: savedRaw) == edited.settings)
        #expect(edited.settings.insertMethod == .paste)
        #expect(edited.settings.hotkey.keyCode == 54)
        #expect(edited.resolvedConfiguration.string("languageBias") == "French")
        #expect(try untouched.settingsRepository.rawPayload() == originalRaw)
        #expect(untouched.settings == originalSettings)
        #expect(!edited.copyTextToClipboard("preview copy must stay unavailable"))
        #expect(edited.readClipboardText() == nil)
        #expect(untouched.readClipboardText() == nil)
        return savedRaw
    }

    @MainActor
    private func exerciseOfflinePreviewSecretIsolation(
        edited: AppEnvironment, untouched: AppEnvironment
    ) async throws {
        let savedInvalid = try await AsyncDeadline.run(seconds: 5) {
            await edited.saveSecret("invalid", field: "apiKey", provider: "Meta")
        }
        #expect(savedInvalid)
        try await AsyncDeadline.run(seconds: 5) { await edited.testProviderConnection("Meta") }
        #expect(
            edited.connections.state(for: "Meta")
                == .failed("The API key was rejected. Check the key and your provider account’s access."))
        let savedValid = try await AsyncDeadline.run(seconds: 5) {
            await edited.saveSecret("edited-preview-key", field: "apiKey", provider: "Meta")
        }
        #expect(savedValid)
        // The other environment's first secret read happens after these writes, so no cache can mask leakage.
        #expect(untouched.credentials.state(for: "Meta") == .notLoaded)
        let untouchedKey = try await AsyncDeadline.run(seconds: 5) {
            await edited.testProviderConnection("Meta")
            return await untouched.loadSecret(field: "apiKey", provider: "Meta")
        }
        #expect(edited.credentials.cachedValues(for: "Meta")["apiKey"] == "edited-preview-key")
        #expect(untouchedKey == "preview-only")
        #expect(edited.connections.state(for: "Meta") == .connected)
        #expect(untouched.connections.state(for: "Meta") == .notChecked)
    }

    @Test func previewClipboardReportsUnavailableForReadsAndEveryMutation() {
        let clipboard: any ClipboardPort = PreviewClipboard()
        let previous = ClipboardSnapshot.concealedText("preview-only previous contents")
        #expect(clipboard.string() == nil)
        #expect(clipboard.snapshot() == nil)
        #expect(clipboard.changeCount == -1)
        #expect(!clipboard.setString("preview text"))
        #expect(!clipboard.setTransientString("preview transient text"))
        #expect(clipboard.preparePaste("preview text", previous: nil) == .unavailable)
        #expect(clipboard.preparePaste("preview text", previous: previous) == .unavailable)
        #expect(!clipboard.restore(previous))
        #expect(clipboard.restoreIfUnchanged(previous, dictation: "preview text", revision: 1) == .unavailable)
        clipboard.clear()
        #expect(clipboard.string() == nil)
        #expect(clipboard.snapshot() == nil)
        #expect(clipboard.changeCount == -1)
    }

    @Test @MainActor func previewRuntimePortsStayInertAcrossSettingsUpdatesAndInsertion() async throws {
        let ports = PreviewRuntime.ports()
        let audio = ports.audio
        let config = ProviderConfiguration(provider: .meta, values: ["apiKey": "preview-only"])
        let service = ports.makeService(config)
        var notices: [InsertionNotice] = []
        ports.inserter.onNotice { notices.append($0) }
        defer {
            ports.inserter.onNotice(nil)
            ports.hotkey.stop()
        }
        do {
            for method in [AppSettings.InsertMethod.keystroke, .paste] {
                ports.inserter.update(method: method)
                ports.inserter.insert("preview text", target: InsertionTargetSnapshot(pid: 1))
            }
            #expect(notices.isEmpty)
            #expect(ports.focus.currentTargetSnapshot() == nil)
            ports.hotkey.update(keyCode: 54)
            #expect(!ports.hotkey.start())
            #expect(!ports.hotkey.isMonitoring)
            let hotkeyEvents = ports.hotkey.events()
            let event = try await AsyncDeadline.run(seconds: 5) {
                var input = hotkeyEvents.makeAsyncIterator()
                return await input.next()
            }
            #expect(event == nil)
            try await AsyncDeadline.run(seconds: 5) { try await audio.start() }
            let audioFrames = audio.frames()
            let frame = try await AsyncDeadline.run(seconds: 5) {
                var input = audioFrames.makeAsyncIterator()
                return await input.next()
            }
            #expect(frame == nil)
            // The actual preview factory must supply the offline scripted service, even for Meta settings.
            let outcome = try await AsyncDeadline.run(seconds: 5) {
                try await service.start(config: config)
                return await service.finish()
            }
            #expect(outcome == .completed("hello world"))
            #expect(await service.requiresRestart == false)
        } catch {
            await audio.stop()
            _ = await service.cancel()
            throw error
        }
        await audio.stop()
        #expect(await service.cancel() == .clean)
    }
#endif
