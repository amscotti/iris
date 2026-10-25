import Foundation

/// UI-facing dictation state broadcast by the transcription orchestrator.
public enum PushToTalkState: Sendable, Equatable {
    case idle
    /// Live capture meter. `level` is normalized to 0...1 (see `PCMFrame.rms`);
    /// publishers must clamp out-of-range values before emitting.
    case recording(level: Float)
    case partial(String)
    case final(String)
    /// A rewrite prompt is enhancing the final transcript. Emitted only
    /// while enabled prompts run, between the service completion and
    /// insertion.
    case enhancing
    /// Display message for a failed take. Carries text only (not the
    /// `TranscriptionError` category) because this stream drives UI;
    /// retry/branching logic must use `TranscriptionService.terminalOutcome`.
    case error(String)
}
