import Foundation

/// Inserts finalized text.
///
/// The default destination is the focused app at insert time. Callers that
/// need an explicit session boundary capture a target at press start and
/// use `insert(_:target:)`; the default implementation forwards to
/// `insert(_:)` so existing inserters keep working.
///
/// Failure semantics: synchronous and non-throwing by design for the
/// hot path. Implementations must not crash or block on failure
/// (missing accessibility trust, no focused target, AX errors); they
/// fall back (e.g. clipboard) and report out-of-band via runtime
/// logging/user notification so the orchestrator's outcome stays
/// transcript-accurate.
///
/// Target semantics: `nil` means "focused app at insert time". An
/// `InsertionTargetSnapshot` with both fields `nil` (`isFollowFocus`)
/// is canonicalized to the same follow-focus behavior — pinning only
/// happens with at least one identifying field set.
public protocol TextInserting: Sendable {
    func insert(_ text: String)
    func insert(_ text: String, target: InsertionTargetSnapshot?)
    /// Invalidates work belonging to an insertion that exceeded its deadline.
    /// Ordinary stop does not call this: healthy in-flight insertions are joined.
    func cancelInsertion()
}

public struct InsertionTargetSnapshot: Sendable, Equatable {
    public var pid: Int32?
    public var bundleID: String?

    public init(pid: Int32? = nil, bundleID: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
    }

    /// True when neither field is set: equivalent to a `nil` target
    /// (follow the focused app at insert time).
    public var isFollowFocus: Bool { pid == nil && bundleID == nil }

    /// Explicit follow-focus target, for call sites that prefer a value
    /// over `nil`.
    public static var followFocus: InsertionTargetSnapshot { InsertionTargetSnapshot() }
}

extension TextInserting {
    public func insert(_ text: String, target: InsertionTargetSnapshot?) {
        insert(text)
    }

    /// Source-compatible default for inserters without cancellable workers.
    public func cancelInsertion() {}
}
