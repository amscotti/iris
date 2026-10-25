import Foundation
import IrisCore

/// xAI partials are segments, not necessarily the whole take. Chunk finals
/// lock a piece of speech; speech_final replaces those chunks with a stitched
/// utterance. Keep each utterance until audio.done completes the entire take.
struct GrokTranscriptAccumulator: Sendable {
    struct Segment: Sendable {
        var text: String
        var start: Double?
        var duration: Double?
        var utterance: Int

        /// - Parameter requiringExtension: used when an *interim* replaces a
        /// committed segment: only a segment that extends (or equals) the
        /// committed text may take its place. Applies to the untimed
        /// fallback, where a shorter or re-segmented hypothesis can
        /// otherwise delete locked words; timed segments keep the original
        /// overlap semantics (overlapping time ranges are restatements).
        func overlaps(_ other: Segment, requiringExtension: Bool = false) -> Bool {
            if let start, let otherStart = other.start,
                let timed = timedOverlap(
                    start: start, otherStart: otherStart, other: other, requiringExtension: requiringExtension)
            {
                return timed
            }
            // Untimed fallback: servers may omit start/duration. Cumulative
            // resends then share a verbatim prefix (committed "hello" vs
            // interim "hello wo"), while distinct segments ("hello" vs
            // "world") do not. A prefix only counts as an overlap when it
            // ends at a word boundary — "no" vs "nobody knows" are distinct
            // words, not a re-statement, and must both survive (duplication
            // is recoverable; silent deletion is not).
            // A text prefix is evidence of a resend only within this utterance.
            // Across a speech_final boundary, repeated words are new speech.
            guard utterance == other.utterance else { return false }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let theirs = other.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !text.isEmpty, !theirs.isEmpty else { return false }
            if requiringExtension {
                return theirs.hasPrefix(text) && Self.endsAtWordBoundary(text, in: theirs)
            }
            if theirs.hasPrefix(text) { return Self.endsAtWordBoundary(text, in: theirs) }
            if text.hasPrefix(theirs) { return Self.endsAtWordBoundary(theirs, in: text) }
            return false
        }

        private func timedOverlap(
            start: Double, otherStart: Double, other: Segment, requiringExtension: Bool
        ) -> Bool? {
            if let duration, let otherDuration = other.duration {
                if abs(start - otherStart) < 0.001 {
                    // Same start: a restatement (interim) equals the segment
                    // for display, but only a hypothesis that covers at
                    // least the same span may replace it under the
                    // extension rule — otherwise a shorter interim would
                    // silently delete locked words.
                    return requiringExtension ? otherDuration >= duration - 0.001 : true
                }
                let overlapping =
                    start < otherStart + otherDuration - 0.001 && otherStart < start + duration - 0.001
                guard overlapping else { return false }
                guard requiringExtension else { return true }
                // Under the extension rule the interim must cover the whole
                // committed span before it may replace it.
                return otherStart <= start + 0.001 && otherStart + otherDuration >= start + duration - 0.001
            }
            guard abs(start - otherStart) < 0.001 else { return false }
            return requiringExtension ? nil : true
        }

        /// True when `prefix` occupies whole words of `longer`: the character
        /// after the prefix (if any) starts a new word.
        private static func endsAtWordBoundary(_ prefix: String, in longer: String) -> Bool {
            guard prefix.count < longer.count else { return true }
            let next = longer[longer.index(longer.startIndex, offsetBy: prefix.count)]
            // Inspect only the matched boundary. A CJK character elsewhere in
            // the hypothesis must not make "No" overlap "Nobody knows 中文".
            if let last = prefix.last, isWordlessScript(last) || isWordlessScript(next) { return true }
            return next.isWhitespace || next.isPunctuation
        }

        /// A boundary character from a script whose words need no spaces.
        private static func isWordlessScript(_ character: Character) -> Bool {
            character.unicodeScalars.contains { scalar in
                if scalar.properties.isIdeographic { return true }
                switch scalar.value {
                case 0x3040...0x30FF,  // Hiragana, Katakana
                    0xAC00...0xD7AF,  // Hangul syllables
                    0x1100...0x11FF,  // Hangul Jamo
                    0x0E00...0x0E7F,  // Thai
                    0x0E80...0x0EFF,  // Lao
                    0x1000...0x109F,  // Myanmar
                    0x1780...0x17FF:  // Khmer
                    return true
                default:
                    return false
                }
            }
        }
    }

    private var committed: [Segment] = []
    private var interim: Segment?
    private var utterance = 0

    mutating func append(
        text: String, start: Double?, duration: Double?, isFinal: Bool, speechFinal: Bool
    ) -> String {
        let segment = Segment(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            start: start, duration: duration, utterance: utterance)
        if isFinal || speechFinal {
            committed.removeAll {
                $0.overlaps(segment) || (speechFinal && $0.utterance == utterance)
            }
            committed.append(segment)
            interim = nil
            if speechFinal { utterance += 1 }
        } else {
            interim = segment
        }
        return textSoFar
    }

    var textSoFar: String {
        var visible = committed
        if let interim {
            // An interim only supersedes segments it extends; anything else
            // coexists so partial hypotheses cannot erase locked speech.
            visible.removeAll { $0.overlaps(interim, requiringExtension: true) }
            // A stale interim that merely restates part of a committed
            // segment is hidden rather than displayed alongside it.
            if !visible.contains(where: { $0.overlaps(interim) }) {
                visible.append(interim)
            }
        }
        return DictationTextProcessor.joinTranscriptPieces(visible.map(\.text).filter { !$0.isEmpty })
    }

    /// A nonempty session transcript wins. A completion marker with no text
    /// must not erase speech already delivered in transcript.partial events.
    func complete(with text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? textSoFar : text
    }
}
