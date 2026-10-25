import Foundation

/// Per-utterance session state owned by the orchestrator.
///
/// Tracks the recording phase, the latest cumulative partial (used to
/// complete endpointing-style turns), and the insert-once guard so a
/// completed transcript is emitted at most once per session.
public struct TranscriptionSession: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable, Hashable {
        case idle
        case recording
        case finalizing
    }

    public var phase: Phase = .idle
    public var partialText: String = ""
    public var emittedFinal: Bool = false
    public var completedTurnIds: Set<String> = []
    /// Per-turn transcripts for endpointing-style sessions, in arrival order.
    public var turnTranscripts: [String] = []
    /// IDs parallel to turnTranscripts; numeric IDs are ordered at finish.
    public var turnIDs: [String] = []
    public var failure: TranscriptionError?

    /// True when any transcript text was recorded this session — turns or a
    /// non-blank partial — including text that never surfaced as a partial
    /// state (endpointing boundaries carry it only here).
    public var hasRecordedTranscript: Bool {
        !turnTranscripts.isEmpty
            || !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init() {}

    public mutating func begin() {
        phase = .recording
        partialText = ""
        emittedFinal = false
        completedTurnIds = []
        turnTranscripts = []
        turnIDs = []
        failure = nil
    }

    public mutating func beginFinalizing() {
        if phase == .recording {
            phase = .finalizing
        }
    }

    public mutating func accumulate(partial text: String) {
        guard phase == .recording || phase == .finalizing else { return }
        partialText = text
    }

    /// Records a final transcript. Returns the text to emit, or nil when this
    /// session already completed (insert-once guard) or is not active.
    public mutating func complete(final text: String, turnId: String? = nil) -> String? {
        guard !emittedFinal, phase == .recording || phase == .finalizing else { return nil }
        if let turnId, !turnId.isEmpty {
            guard completedTurnIds.insert(turnId).inserted else { return nil }
        }
        emittedFinal = true
        phase = .idle
        return text
    }

    /// Records one endpointing/diarization turn without completing the
    /// session, so later turns in the same press are not dropped.
    public mutating func recordTurn(id: String, text: String) {
        guard phase == .recording || phase == .finalizing else { return }
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if !id.isEmpty, !completedTurnIds.insert(id).inserted { return }
        // Frames without a turn id cannot be deduped by id; a redelivered
        // boundary repeats the same piece — record it once.
        if id.isEmpty, turnTranscripts.last == piece { return }
        turnTranscripts.append(piece)
        turnIDs.append(id)
        // The current partial belonged to the turn just recorded; clear
        // it so a later textless boundary cannot duplicate that text.
        partialText = ""
    }

    private func orderedTurns(_ pieces: [String]) -> [String] {
        let numbered = zip(turnIDs, pieces).compactMap { id, text -> (Int, String)? in
            guard let number = Int(id) else { return nil }
            return (number, text)
        }
        guard numbered.count == pieces.count else { return pieces }
        return numbered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Joins recorded turns plus a trailing partial — the in-flight
    /// utterance after the last boundary — into one final. Nil when there
    /// is nothing to insert; the session still goes idle.
    public mutating func finishTurns() -> String? {
        guard !emittedFinal, phase == .recording || phase == .finalizing else { return nil }
        var pieces = turnTranscripts
        let trailing = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        var trailingPiece: String?
        if !trailing.isEmpty {
            if let last = pieces.last {
                // Reconcile against arrival order first: a cumulative
                // extension replaces that turn, a genuinely new partial is
                // appended only after numeric turn ordering below.
                if trailing.hasPrefix(last) {
                    pieces[pieces.count - 1] = trailing
                } else if !last.hasPrefix(trailing) {
                    trailingPiece = trailing
                }
            } else {
                trailingPiece = trailing
            }
        }
        pieces = orderedTurns(pieces)
        if let trailingPiece { pieces.append(trailingPiece) }
        let text = DictationTextProcessor.joinTranscriptPieces(pieces)
        emittedFinal = !text.isEmpty
        phase = .idle
        return text.isEmpty ? nil : text
    }

    public mutating func fail(_ error: TranscriptionError) {
        failure = error
        phase = .idle
    }
}
