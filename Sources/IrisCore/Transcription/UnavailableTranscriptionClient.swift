import Foundation

/// Unknown persisted providers fail explicitly instead of producing a mock
/// transcript or routing traffic through a different provider.
public struct UnavailableTranscriptionClient: TranscriptionClient {
    public init() {}
    private var failure: TranscriptionError {
        TranscriptionError(
            kind: .invalidState, message: "The selected provider is unavailable. Choose one in Settings → Providers.")
    }

    public func start(config: ProviderConfiguration) async throws { throw failure }
    public func sendAudio(_ frame: PCMFrame) async throws { throw failure }
    public func events() -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: failure) }
    }
    public func endAudio() async throws {
        throw failure
    }

    public func cancel() async {}
}
