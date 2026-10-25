import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func pasteRestoreFailurePutsTheDictationBack() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    keys.onPaste = { clipboard.failNextSets = 1 }
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("dictation")
    #expect(clipboard.string() == "dictation")
    #expect(clipboard.snapshot()?.items.first?.contains { $0.type == LiveClipboard.transientType } == true)
    #expect(
        notices == [
            "Your words were already pasted. The previous clipboard couldn’t be restored; the transcript remains on the clipboard."
        ])
}
