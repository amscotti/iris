import Foundation

/// Pure take transitions. Resource ownership and effects remain on the orchestrator.
public struct TakeLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case starting, recording, finalizing }
    public enum Release: Sendable, Equatable { case cancelStartup, finishRecording, ignored }
    public private(set) var phase: Phase = .starting
    public init() {}

    @discardableResult public mutating func captureReady() -> Bool {
        guard phase == .starting else { return false }
        phase = .recording
        return true
    }

    public mutating func release() -> Release {
        switch phase {
        case .starting:
            phase = .finalizing
            return .cancelStartup
        case .recording:
            phase = .finalizing
            return .finishRecording
        case .finalizing: return .ignored
        }
    }

    public mutating func fail() { phase = .finalizing }
}
