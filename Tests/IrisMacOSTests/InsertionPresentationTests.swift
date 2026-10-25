import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func insertionHasItsOwnStatusAndIsNotCancellable() {
    let environment = TestEnvironment().make()
    environment.handleSnapshot(
        DictationSnapshot(
            state: .final("words"), lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("words"), isTakeActive: true,
            activeTakeID: 1, isInsertionActive: true))

    #expect(environment.statusLine == "Inserting…")
    #expect(environment.menuSymbol == "text.cursor")
    #expect(environment.isTakeActive)
    #expect(environment.isInsertionActive)
    #expect(!environment.canCancelDictation)

    environment.handleSnapshot(
        DictationSnapshot(
            state: .idle, lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("words"), isTakeActive: false,
            activeTakeID: nil, isInsertionActive: false))
    #expect(environment.statusLine == "Ready")
}
