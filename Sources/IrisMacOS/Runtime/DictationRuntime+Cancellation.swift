import IrisCore

@MainActor
extension DictationRuntime {
    /// Cancels only the active take; input monitoring and runtime readiness
    /// stay owned by the existing lifecycle. The reason travels with this
    /// request, so it cannot overwrite a suspension's first-cause notice.
    @discardableResult
    public func cancelDictation(takeID: Int? = nil) async -> Bool {
        await orchestrator.cancelActiveTake(expectedID: takeID, cancellationReason: .userRequested)
    }
}
