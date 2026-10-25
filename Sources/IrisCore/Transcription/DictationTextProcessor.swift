import Foundation

/// Pure preparation and chunking policy for finalized transcripts.
///
/// Lives in the core so the hold-to-talk loop, the tests, and every
/// insertion mechanism share one definition of "insertable text":
/// blank results are dropped, trailing separators come from settings,
/// and long results split on character boundaries that never tear a
/// UTF-16 surrogate pair.
public enum DictationTextProcessor {
    /// Largest chunk, in UTF-16 code units, handed to one keystroke event.
    ///
    /// `CGEventKeyboardSetUnicodeString` payloads beyond ~20 UTF-16 units
    /// are silently truncated by many receiving apps (the documented
    /// behavior long-standing input tools design around: enigo chunks at
    /// 20, Hammerspoon posts one character per event). Terminal happens to
    /// accept longer payloads, which hides the loss during development.
    /// Bound chunks to the safe platform size; `CGEvent.post` cannot report
    /// truncation, so prevention is the only defense.
    public static let maxChunkUTF16 = 20

    /// Returns the string to insert, or nil when there is nothing to insert.
    ///
    /// Blank or whitespace-only transcripts return nil. Otherwise a single
    /// trailing space and/or trailing newline is ensured, each only when the
    /// matching toggle is on and the text does not already end that way.
    public static func prepare(
        _ text: String, trailingSpace: Bool = true, trailingNewline: Bool = false
    ) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var prepared = text
        if trailingSpace, !prepared.hasSuffix(" "), !prepared.hasSuffix("\n"), !prepared.hasSuffix("\t") {
            prepared += " "
        }
        if trailingNewline, !prepared.hasSuffix("\n") {
            prepared += "\n"
        }
        return prepared
    }

    /// Joins provider-supplied turns/segments without inserting spaces into
    /// scripts that are normally written without them. Latin and other
    /// space-separated text retains the existing single-space behavior.
    public static func joinTranscriptPieces(_ pieces: [String]) -> String {
        var previous: String?
        return pieces.filter { !$0.isEmpty }.reduce(into: "") { result, piece in
            if let previous, shouldSeparate(previous, from: piece) { result += " " }
            result += piece
            previous = piece
        }
    }

    private static func shouldSeparate(_ previous: String, from piece: String) -> Bool {
        // Repeated utterances are separate speech, not one continuous word.
        if previous == piece { return true }
        return !(isWhollyWordless(previous) && isWhollyWordless(piece))
    }

    private static func isWhollyWordless(_ text: String) -> Bool {
        var sawScript = false
        for character in text {
            if character.isWhitespace || character.isPunctuation || character.isSymbol { continue }
            guard isWordlessScript(character) else { return false }
            sawScript = true
        }
        return sawScript
    }

    private static func isWordlessScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            if scalar.properties.isIdeographic { return true }
            switch scalar.value {
            case 0x3040...0x30FF, 0xAC00...0xD7AF, 0x1100...0x11FF,
                0x0E00...0x0E7F, 0x0E80...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
                return true
            default:
                return false
            }
        }
    }

    /// Splits text into chunks of at most `maxUTF16` UTF-16 code units.
    ///
    /// Boundaries always fall between characters, so grapheme clusters and
    /// surrogate pairs stay intact. Short inputs return a single chunk.
    /// Exception: a single grapheme cluster longer than `maxUTF16` (extreme
    /// combining sequences) is emitted whole rather than torn; such a
    /// payload is beyond the platform's safe event size either way.
    public static func chunk(_ text: String, maxUTF16: Int = maxChunkUTF16) -> [String] {
        guard maxUTF16 > 0 else { return [text] }
        guard text.utf16.count > maxUTF16 else { return [text] }
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if currentUnits + units > maxUTF16, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
