import SwiftUI
import Testing

@testable import IrisMacOS

@Test @MainActor func clipboardPasteDistinguishesBusyFromEmpty() {
    var draft = ""
    let binding = Binding(get: { draft }, set: { draft = $0 })
    #expect(
        ProviderKeyDraftActions.paste(binding, from: .unavailable)
            == "Clipboard is busy. Try Paste again.")
    #expect(draft.isEmpty)
    #expect(
        ProviderKeyDraftActions.paste(binding, from: .empty)
            == "Copy an API key first, then choose Paste.")
    #expect(
        ProviderKeyDraftActions.paste(binding, from: .text("  \n"))
            == "Copy an API key first, then choose Paste.")
    #expect(ProviderKeyDraftActions.paste(binding, from: .text("  fixture-key \n")) == nil)
    #expect(draft == "fixture-key")
}

@Test @MainActor func failedCredentialSavePreservesTheBoundEditorDraftUntilRetrySucceeds() async {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    var draft = "  fixture-key \n"
    let binding = Binding(get: { draft }, set: { draft = $0 })
    await fixture.secrets.failMutations(true)
    let failed = await ProviderKeyDraftActions.save(binding) { value in
        await environment.saveSecret(value, field: "apiKey", provider: "Meta")
    }
    #expect(!failed)
    #expect(draft == "  fixture-key \n")
    #expect(environment.credentialErrors["Meta"] != nil)
    await fixture.secrets.failMutations(false)
    let succeeded = await ProviderKeyDraftActions.save(binding) { value in
        await environment.saveSecret(value, field: "apiKey", provider: "Meta")
    }
    #expect(succeeded)
    #expect(draft.isEmpty)
    #expect(environment.credentialErrors["Meta"] == nil)
}
