import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private final class ClipboardReadGate: @unchecked Sendable {
    let entered = AsyncStream.makeStream(of: Void.self)
    let finished = AsyncStream.makeStream(of: Void.self)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    var isReleased: Bool { lock.withLock { released } }
    func wait() {
        entered.continuation.yield(())
        releaseSignal.wait()
    }
    func release() {
        let first = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if first { releaseSignal.signal() }
    }
}

/// Models an unresponsive pasteboard owner while holding the production gate.
/// All writes and Settings reads still go through the actual LiveClipboard.
private struct ParkedClipboard: ClipboardPort {
    let live: LiveClipboard
    let access: ClipboardAccess
    let read: ClipboardReadGate
    func string() -> String? { live.string() }
    func setString(_ text: String) -> Bool { live.setString(text) }
    func setTransientString(_ text: String) -> Bool { live.setTransientString(text) }
    func clear() { live.clear() }
    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        live.preparePaste(text, previous: previous)
    }
    func snapshot() -> ClipboardSnapshot? {
        let saved: ClipboardSnapshot? = access.withAccess(or: nil) {
            read.wait()
            return FakeClipboard.text("old clipboard")
        }
        read.finished.continuation.yield(())
        return saved
    }
    func restore(_ snapshot: ClipboardSnapshot) -> Bool { live.restore(snapshot) }
    func restoreIfUnchanged(_ snapshot: ClipboardSnapshot, dictation: String, revision: Int)
        -> ClipboardRestoreOutcome
    {
        live.restoreIfUnchanged(snapshot, dictation: dictation, revision: revision)
    }
    var changeCount: Int { live.changeCount }
}

private final class ClipboardNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var messages: [String] { lock.withLock { stored } }
    func append(_ message: String) { lock.withLock { stored.append(message) } }
}

@Test func abandonedClipboardReadDoesNotHangInsertionOrSettingsAccess() async throws {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let access = ClipboardAccess(waitSeconds: 0.02)
    let live = LiveClipboard(name: name, access: access)
    #expect(live.setString("old clipboard"))
    let read = ClipboardReadGate()
    let watchdog = Task.detached {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        read.release()
    }
    defer {
        watchdog.cancel()
        read.release()
        NSPasteboard(name: name).releaseGlobally()
    }
    let keys = FakeKeys()
    let notices = ClipboardNotices()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: ParkedClipboard(live: live, access: access, read: read),
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    let inserting = Task {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                inserter.insert("dictation")
                done.resume()
            }
        }
    }
    try await AsyncDeadline.run(seconds: 5) {
        var entered = read.entered.stream.makeAsyncIterator()
        _ = await entered.next()
    }
    // The key editor and reset-command action must not wait for this owner.
    #expect(live.string() == nil)
    #expect(!live.setString("reset commands"))
    #expect(live.changeCount == -1)
    #expect(!live.restore(FakeClipboard.text("restored")))
    #expect(
        live.restoreIfUnchanged(FakeClipboard.text("restored"), dictation: "dictation", revision: 1) == .unavailable)
    try await AsyncDeadline.run(seconds: 5) { await inserting.value }
    #expect(!read.isReleased)
    #expect(keys.pastePosts == 0)
    #expect(notices.messages == ["Could not place text on the clipboard."])
    read.release()
    try await AsyncDeadline.run(seconds: 5) {
        var finished = read.finished.stream.makeAsyncIterator()
        _ = await finished.next()
    }
    // The abandoned snapshot must never write its late result back.
    #expect(live.string() == "old clipboard")
    #expect(live.setString("new copy"))
    #expect(live.string() == "new copy")
}

@Test func clipboardAccessRecoversAProvablyAbandonedLease() {
    // The quarantine window equals one wait: the first timeout starts the
    // clock, and any later timed-out call has already burned past it.
    let access = ClipboardAccess(waitSeconds: 0.05, leaseStuckSeconds: 0.05)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let holder = Thread {
        _ = access.withAccess(or: nil) {
            entered.signal()
            release.wait()
            return "parked"
        }
    }
    holder.start()
    #expect(entered.wait(timeout: .now() + 5) == .success)
    // The abandoned lease still fails fast while the clock runs.
    #expect(access.withAccess(or: "fallback") { "ran" } == "fallback")
    // Past the window the stuck lease is replaced and access recovers.
    #expect(access.withAccess(or: "fallback") { "ran" } == "ran")
    release.signal()
}

/// Counts concurrent critical sections; `maxInside` records the worst seen.
private final class AccessOverlapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private(set) var maxInside = 0
    private(set) var fEntries = 0
    func enter() {
        lock.withLock {
            inside += 1
            maxInside = max(maxInside, inside)
        }
    }
    func enterAsF() {
        lock.withLock {
            fEntries += 1
            enterLocked()
        }
    }
    func exit() { lock.withLock { inside -= 1 } }
    private func enterLocked() {
        inside += 1
        maxInside = max(maxInside, inside)
    }
}

@Test func aLateSignalOnARetiredLeaseGateCannotEnterConcurrently() {
    // Three-party interleaving: A abandons its lease; C's replacement wait
    // retires the stuck gate and enters; F's wait was already parked on the
    // retired gate when A's late signal lands in it. F must discard that
    // entry and re-queue on the replacement gate, never run beside C.
    let access = ClipboardAccess(waitSeconds: 0.5, leaseStuckSeconds: 0.5)
    let counter = AccessOverlapCounter()
    let aEntered = DispatchSemaphore(value: 0)
    let releaseA = DispatchSemaphore(value: 0)
    let cTimedOut = DispatchSemaphore(value: 0)
    let cInside = DispatchSemaphore(value: 0)
    let releaseC = DispatchSemaphore(value: 0)
    let joined = DispatchSemaphore(value: 0)

    // A: acquires the original gate, then stalls past any bounded operation.
    // Its parked operation is the abandoned one; the overlap seam counts
    // only C and F, the callers the retirement policy must serialize.
    Thread {
        access.withAccess(or: ()) {
            aEntered.signal()
            releaseA.wait()
        }
        joined.signal()
    }.start()
    #expect(aEntered.wait(timeout: .now() + 5) == .success)

    // C: one full wait times out (stuck clock starts), the next replaces
    // the gate and enters on the replacement.
    Thread {
        access.withAccess(or: ()) {}
        cTimedOut.signal()
        access.withAccess(or: ()) {
            counter.enter()
            cInside.signal()
            releaseC.wait()
            counter.exit()
        }
        joined.signal()
    }.start()
    #expect(cTimedOut.wait(timeout: .now() + 5) == .success)

    // F queues on the original gate while it is still current, but with its
    // wait alive past the moment C retires that gate.
    Thread.sleep(forTimeInterval: 0.1)
    Thread {
        access.withAccess(or: ()) {
            counter.enterAsF()
            counter.exit()
        }
        joined.signal()
    }.start()

    #expect(cInside.wait(timeout: .now() + 5) == .success)
    // The abandoned holder finally returns; its signal lands on the retired
    // gate, inside F's pending wait.
    releaseA.signal()
    Thread.sleep(forTimeInterval: 0.25)
    #expect(counter.maxInside == 1)

    releaseC.signal()
    for _ in 0..<3 { #expect(joined.wait(timeout: .now() + 5) == .success) }
    #expect(counter.maxInside == 1)
    // F eventually ran — the discard re-queued it rather than dropping it.
    #expect(counter.fEntries == 1)
}

@Test func copyingPlainTextReplacesOldFormatsAndConcealedMarkers() {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let old = NSPasteboardItem()
    old.setString("old text", forType: .string)
    old.setData(Data(#"{\rtf1 old text}"#.utf8), forType: .rtf)
    old.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardSnapshot.concealedType))
    let image = NSPasteboardItem()
    image.setData(Data([1, 2, 3]), forType: .png)
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([old, image]))
    let live = LiveClipboard(name: name)
    #expect(live.setString("tccutil reset Microphone io.github.amscotti.iris"))
    #expect(live.string() == "tccutil reset Microphone io.github.amscotti.iris")
    #expect(pasteboard.pasteboardItems?.count == 1)
    #expect(pasteboard.data(forType: .rtf) == nil)
    #expect(pasteboard.data(forType: .png) == nil)
    #expect(live.snapshot()?.isConcealed == false)
}

@Test func aTransientCopyAlsoReplacesOldClipboardFormats() {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setData(Data([1, 2, 3]), forType: .png)
    let live = LiveClipboard(name: name)
    #expect(live.setTransientString("dictation"))
    #expect(live.string() == "dictation")
    #expect(pasteboard.data(forType: .png) == nil)
    #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType(LiveClipboard.transientType)) == true)
}

private struct UnreadableRevisionClipboard: ClipboardPort {
    let storage = FakeClipboard(string: "before")
    func string() -> String? { storage.string() }
    func setString(_ text: String) -> Bool { storage.setString(text) }
    func setTransientString(_ text: String) -> Bool { storage.setTransientString(text) }
    func clear() { storage.clear() }
    func snapshot() -> ClipboardSnapshot? { storage.snapshot() }
    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        switch storage.preparePaste(text, previous: previous) {
        case .written(_, let saved): return .written(revision: -1, previous: saved)
        case .failed: return .failed
        case .changed: return .changed
        case .unavailable: return .unavailable
        }
    }
    func restore(_ snapshot: ClipboardSnapshot) -> Bool { storage.restore(snapshot) }
    func restoreIfUnchanged(_ snapshot: ClipboardSnapshot, dictation: String, revision: Int)
        -> ClipboardRestoreOutcome
    {
        storage.restoreIfUnchanged(snapshot, dictation: dictation, revision: revision)
    }
    var changeCount: Int { -1 }
}

@Test func anUnreadableClipboardRevisionCannotAuthorizeAPaste() {
    let clipboard = UnreadableRevisionClipboard()
    let keys = FakeKeys()
    let notices = ClipboardNotices()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil),
        keys: keys, pasteRestoreSeconds: 0)
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 0)
    #expect(notices.messages == ["Couldn’t confirm the clipboard contents. Paste was skipped."])
}
