import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func cleartextSpeechTransportIsRejectedBeforeConnecting() async throws {
    let url = try #require(URL(string: "ws://localhost:1234"))
    let transport = URLSessionWebSocketTransport(url: url)
    do {
        try await transport.connect()
        Issue.record("A cleartext speech socket must not be opened")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .invalidState)
        #expect(failure.message == "Speech connections must use wss.")
    }
}
