import Foundation
import Testing

@testable import IrisCore

@Test func insertionBudgetAccountsForPerChunkAccessibilityChecks() {
    let text = String(repeating: "x", count: 2_000)
    let budget = DictationOrchestrator.insertionBudgetSeconds(baseTimeout: 10, text: text)
    let chunks =
        (text.utf16.count + DictationTextProcessor.maxChunkUTF16 - 1)
        / DictationTextProcessor.maxChunkUTF16
    #expect(chunks == 100)
    #expect(budget == 17)
    #expect(budget > 10 + Double(text.utf16.count) * 0.001)
}

@Test func multibyteGraphemesUseTheWorkersActualChunkCount() {
    let text = String(repeating: "👩‍👩‍👧‍👦", count: 200)
    let chunks = DictationTextProcessor.chunk(text).count
    let estimated =
        (text.utf16.count + DictationTextProcessor.maxChunkUTF16 - 1)
        / DictationTextProcessor.maxChunkUTF16
    #expect(chunks > estimated)
    let budget = DictationOrchestrator.insertionBudgetSeconds(baseTimeout: 10, text: text)
    #expect(budget >= 10 + Double(chunks) * 0.05)
}
