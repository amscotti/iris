#if DEBUG
    import Foundation
    import IrisCore
    import IrisProviders

    /// Preview dependencies have no hardware, input, or network fallbacks.
    @MainActor
    enum PreviewRuntime {
        static func ports() -> DictationRuntimePorts {
            DictationRuntimePorts(
                audio: PreviewAudio(), inserter: PreviewInserter(), hotkey: PreviewKeys(), focus: PreviewFocus(),
                authorization: CaptureAuthorization(microphone: { true }, accessibility: { true }, image: { true }),
                systemEvents: PreviewEvents(),
                makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
                rewriteFactory: { _ in nil })
        }
    }

    private struct PreviewAudio: AudioCaptureLifecycle {
        func start() async throws {}
        func stop() async {}
        func frames() -> AsyncStream<PCMFrame> { AsyncStream { $0.finish() } }
        nonisolated func setCaptureFailureHandler(_ handler: @escaping @Sendable (Int, String) -> Void) {}
    }
    private struct PreviewInserter: ConfigurableTextInserting {
        func insert(_ text: String) {}
        func update(method: AppSettings.InsertMethod) {}
        func onNotice(_ handler: ((InsertionNotice) -> Void)?) {}
    }
    private struct PreviewFocus: FocusPort {
        func isProcessTrusted() -> Bool { true }
        func focusedIsSecure() -> Bool { false }
        func currentTarget() -> InsertionTarget? { nil }
    }
    @MainActor private struct PreviewKeys: HotkeyControlling {
        var isMonitoring: Bool { false }
        func start() -> Bool { false }
        func stop() {}
        func update(keyCode: Int) {}
        nonisolated func events() -> AsyncStream<HotkeyEvent> { AsyncStream { $0.finish() } }
    }
    @MainActor private struct PreviewEvents: SystemEventObserving {
        func start(_ handler: @escaping @MainActor (RuntimeSystemEvent) -> Void) {}
        func stop() {}
    }
#endif
