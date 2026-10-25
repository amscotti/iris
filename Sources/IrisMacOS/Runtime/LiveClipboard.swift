import AppKit
import Foundation

/// Serializes live pasteboard transactions with bounded access acquisition.
public struct LiveClipboard: ClipboardPort {
    public static let transientType = "org.nspasteboard.TransientType"
    public static let snapshotByteBudget = 32 * 1024 * 1024
    public static let snapshotSecondsBudget: TimeInterval = 1
    /// Promised files cannot be restored meaningfully and can be slow to render.
    static let unrestorableTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
    ]
    private static let sharedAccess = ClipboardAccess()
    private let name: NSPasteboard.Name
    private let byteBudget: Int
    private let access: ClipboardAccess
    /// Test injection: real `NSPasteboard` writes cannot be forced to fail,
    /// so this fails only the dictation write in `preparePaste`.
    private let failTextWrites: @Sendable () -> Bool

    /// Tests use a uniquely named private pasteboard, never the user's clipboard.
    public init(name: NSPasteboard.Name = .general, byteBudget: Int = LiveClipboard.snapshotByteBudget) {
        self.init(name: name, byteBudget: byteBudget, access: Self.sharedAccess)
    }

    init(
        name: NSPasteboard.Name,
        byteBudget: Int = LiveClipboard.snapshotByteBudget,
        access: ClipboardAccess,
        failTextWrites: @escaping @Sendable () -> Bool = { false }
    ) {
        self.name = name
        self.byteBudget = byteBudget
        self.access = access
        self.failTextWrites = failTextWrites
    }

    private var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    public func string() -> String? { access.withAccess(or: nil) { pasteboard.string(forType: .string) } }
    public func readString() -> ClipboardTextRead {
        access.withAccess(or: .unavailable) {
            let concealed =
                pasteboard.pasteboardItems?.contains { item in
                    item.types.contains { $0.rawValue == ClipboardSnapshot.concealedType }
                } ?? false
            if concealed { return .concealed }
            return pasteboard.string(forType: .string).map(ClipboardTextRead.text) ?? .empty
        }
    }
    public var changeCount: Int { access.withAccess(or: -1) { Int(pasteboard.changeCount) } }

    @discardableResult public func setString(_ text: String) -> Bool { replaceText(text, transient: false) }
    @discardableResult public func setTransientString(_ text: String) -> Bool { replaceText(text, transient: true) }
    public func clear() { access.withAccess(or: ()) { _ = pasteboard.clearContents() } }

    private func replaceText(_ text: String, transient: Bool) -> Bool {
        access.withAccess(or: false) {
            let pasteboard = self.pasteboard
            pasteboard.clearContents()
            return writeText(text, transient: transient, to: pasteboard)
        }
    }

    public func snapshot() -> ClipboardSnapshot? {
        access.withAccess(or: nil) {
            let pasteboard = self.pasteboard
            let revision = Int(pasteboard.changeCount)
            let deadline = Date().addingTimeInterval(Self.snapshotSecondsBudget)
            var total = 0
            var items: [[ClipboardSnapshot.Representation]] = []
            let pasteboardItems = pasteboard.pasteboardItems ?? []
            for item in pasteboardItems {
                var representations: [ClipboardSnapshot.Representation] = []
                for type in item.types where !Self.unrestorableTypes.contains(type.rawValue) {
                    guard Date() <= deadline else { return nil }
                    guard let data = item.data(forType: type) else { continue }
                    total += data.count
                    guard total <= byteBudget else { return nil }
                    representations.append(.init(type: type.rawValue, data: data))
                }
                if !representations.isEmpty { items.append(representations) }
            }
            guard Int(pasteboard.changeCount) == revision else { return nil }
            guard pasteboardItems.isEmpty || !items.isEmpty else { return nil }
            return ClipboardSnapshot(items: items, revision: revision)
        }
    }

    public func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        access.withAccess(or: .unavailable) {
            let pasteboard = self.pasteboard
            if let previousRevision = previous?.revision, previousRevision != Int(pasteboard.changeCount) {
                return .changed
            }
            let backup = previous?.revision == Int(pasteboard.changeCount) ? previous : nil
            // Without a full snapshot (its budget gave up, or an alternate
            // port produced none) a failed write would strand the transcript
            // and destroy the clipboard. A cheap text read bounds that
            // damage; content it cannot capture refuses the destructive
            // clear outright, leaving the user's clipboard intact.
            var textFallback: String?
            if backup == nil {
                let fallback = pasteboard.string(forType: .string)
                if fallback == nil, (pasteboard.pasteboardItems ?? []).isEmpty == false {
                    return .failed
                }
                textFallback = fallback
            }
            let clearedRevision = Int(pasteboard.clearContents())
            guard !failTextWrites(), writeText(text, transient: true, to: pasteboard) else {
                // Acquisition failure never reaches here. Roll back only our
                // own clear, while still holding the lease, not after returning.
                if Int(pasteboard.changeCount) == clearedRevision {
                    if let backup {
                        _ = writeSnapshot(backup, to: pasteboard)
                    } else if let textFallback {
                        _ = writeText(textFallback, transient: false, to: pasteboard)
                    }
                }
                return .failed
            }
            return .written(revision: Int(pasteboard.changeCount), previous: backup)
        }
    }

    @discardableResult public func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        access.withAccess(or: false) {
            let pasteboard = self.pasteboard
            pasteboard.clearContents()
            return writeSnapshot(snapshot, to: pasteboard)
        }
    }

    public func restoreIfUnchanged(
        _ snapshot: ClipboardSnapshot, dictation: String, revision: Int
    ) -> ClipboardRestoreOutcome {
        access.withAccess(or: .unavailable) {
            let pasteboard = self.pasteboard
            // Revision first: an external owner's promised text need not render.
            guard revision >= 0, Int(pasteboard.changeCount) == revision,
                pasteboard.string(forType: .string) == dictation
            else { return .changed }
            let clearedRevision = Int(pasteboard.clearContents())
            if writeSnapshot(snapshot, to: pasteboard) { return .restored }
            // Never turn an unavailable lease into destructive recovery later.
            // A failed owned write can recover only before releasing this lease.
            guard Int(pasteboard.changeCount) == clearedRevision else {
                return .failed(dictationPreserved: false)
            }
            pasteboard.clearContents()
            let preserved = writeText(dictation, transient: true, to: pasteboard)
            return .failed(dictationPreserved: preserved)
        }
    }

    /// These writers are called only while the access lease is owned.
    private func writeText(_ text: String, transient: Bool, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient { item.setData(Data(), forType: NSPasteboard.PasteboardType(Self.transientType)) }
        return pasteboard.writeObjects([item])
    }

    private func writeSnapshot(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) -> Bool {
        guard !snapshot.isEmpty else { return true }
        let items = snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}
