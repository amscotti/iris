import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func firstChunkPostFailureUsesFullTranscriptFallbackNotice() {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    keys.succeedUnicodePosts = 0
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys)
    var notices: [InsertionNotice] = []
    inserter.onNotice { notices.append($0) }

    inserter.insert("hello")

    #expect(notices == [.keystrokesUnavailable])
    #expect(clipboard.string() == "hello")
}
