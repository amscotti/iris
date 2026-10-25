import SwiftUI
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func concealedClipboardIsNotAcceptedAsAnAPIKey() {
    let clipboard = FakeClipboard(
        snapshot: FakeClipboard.text("password-manager-secret", markers: [FakeClipboard.concealedType]))
    let environment = TestEnvironment().make(clipboard: clipboard)
    #expect(environment.readClipboardTextResult() == .concealed)

    var draft = ""
    let binding = Binding(get: { draft }, set: { draft = $0 })
    let message = ProviderKeyDraftActions.paste(binding, from: environment.readClipboardTextResult())
    #expect(message == "The clipboard contains a concealed password. Copy an API key explicitly instead.")
    #expect(draft.isEmpty)
    #expect(clipboard.string() == "password-manager-secret")
}
