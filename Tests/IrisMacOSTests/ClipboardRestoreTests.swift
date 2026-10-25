import AppKit
import Foundation
import Testing

@testable import IrisMacOS

// Each test owns a private pasteboard and access lease, independent of other tests
// and the user's clipboard. All external writes below are synchronous and local.
@Test @MainActor func liveConditionalRestoreReturnsEveryItemTypeAndByteWhenUnchanged() throws {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let live = LiveClipboard(name: name, access: ClipboardAccess())
    let marker = NSPasteboard.PasteboardType("iris-tests.restore-marker")
    let richText = Data(#"{\rtf1 previous text}"#.utf8)
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    let text = NSPasteboardItem()
    try #require(text.setData(Data("previous text".utf8), forType: .string))
    try #require(text.setData(richText, forType: .rtf))
    try #require(text.setData(Data(), forType: marker))
    let image = NSPasteboardItem()
    try #require(image.setData(imageData, forType: .png))
    pasteboard.clearContents()
    try #require(pasteboard.writeObjects([text, image]))
    let saved = try #require(live.snapshot())
    try #require(live.setTransientString("dictation"))
    let writtenRevision = live.changeCount
    try #require(writtenRevision >= 0)
    try #require(pasteboard.string(forType: .string) == "dictation")
    try #require(pasteboard.types?.contains(NSPasteboard.PasteboardType(LiveClipboard.transientType)) == true)

    #expect(live.restoreIfUnchanged(saved, dictation: "dictation", revision: writtenRevision) == .restored)
    #expect(live.snapshot() == saved)
    // Read AppKit directly as well: matching snapshots alone could miss a type
    // or byte sequence that both snapshot and restore accidentally dropped.
    let restored = try #require(pasteboard.pasteboardItems)
    try #require(restored.count == 2)
    // AppKit can synthesize additional plain-text encodings from RTF. Require
    // every explicitly written representation without forbidding derived ones.
    #expect(Set(restored[0].types).isSuperset(of: [.string, .rtf, marker]))
    #expect(restored[0].data(forType: .string) == Data("previous text".utf8))
    #expect(restored[0].data(forType: .rtf) == richText)
    #expect(restored[0].data(forType: marker) == Data())
    #expect(Set(restored[1].types) == [.png])
    #expect(restored[1].data(forType: .png) == imageData)
}

@Test @MainActor func liveConditionalRestoreLeavesANewerCopyAndItsFormatsAlone() throws {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let live = LiveClipboard(name: name, access: ClipboardAccess())
    try #require(live.setString("old clipboard"))
    let saved = try #require(live.snapshot())
    try #require(live.setTransientString("dictation"))
    let writtenRevision = live.changeCount
    try #require(writtenRevision >= 0)
    let richText = Data(#"{\rtf1 user copy}"#.utf8)
    let userCopy = NSPasteboardItem()
    try #require(userCopy.setData(Data("user copy".utf8), forType: .string))
    try #require(userCopy.setData(richText, forType: .rtf))
    pasteboard.clearContents()
    try #require(pasteboard.writeObjects([userCopy]))
    let externalRevision = Int(pasteboard.changeCount)
    try #require(externalRevision > writtenRevision)

    #expect(live.restoreIfUnchanged(saved, dictation: "dictation", revision: writtenRevision) == .changed)
    #expect(Int(pasteboard.changeCount) == externalRevision)
    // Even the current revision cannot authorize restoring over different text.
    #expect(live.restoreIfUnchanged(saved, dictation: "dictation", revision: externalRevision) == .changed)
    #expect(Int(pasteboard.changeCount) == externalRevision)
    let current = try #require(pasteboard.pasteboardItems)
    try #require(current.count == 1)
    #expect(Set(current[0].types).isSuperset(of: [.string, .rtf]))
    #expect(current[0].data(forType: .string) == Data("user copy".utf8))
    #expect(current[0].data(forType: .rtf) == richText)
}

@Test @MainActor func liveConditionalRestoreRejectsARecopyOfTheSameTextAtANewerRevision() throws {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let live = LiveClipboard(name: name, access: ClipboardAccess())
    try #require(live.setString("old clipboard"))
    let saved = try #require(live.snapshot())
    try #require(live.setTransientString("dictation"))
    let writtenRevision = live.changeCount
    try #require(writtenRevision >= 0)
    // Re-copy the same string directly, independently of the production lease.
    pasteboard.clearContents()
    try #require(pasteboard.setString("dictation", forType: .string))
    let externalRevision = Int(pasteboard.changeCount)
    try #require(externalRevision > writtenRevision)
    try #require(pasteboard.string(forType: .string) == "dictation")
    let externalData = try #require(pasteboard.data(forType: .string))

    #expect(live.restoreIfUnchanged(saved, dictation: "dictation", revision: writtenRevision) == .changed)
    #expect(Int(pasteboard.changeCount) == externalRevision)
    let current = try #require(pasteboard.pasteboardItems)
    try #require(current.count == 1)
    #expect(Set(current[0].types) == [.string])
    #expect(current[0].string(forType: .string) == "dictation")
    #expect(current[0].data(forType: .string) == externalData)
}
