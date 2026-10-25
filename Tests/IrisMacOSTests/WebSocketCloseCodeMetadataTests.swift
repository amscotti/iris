import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func receiveFailurePreservesWebSocketCloseCode() {
    let dropped = NSError(domain: NSPOSIXErrorDomain, code: 57)
    for closeCode in [1000, 1006] {
        let failure =
            URLSessionWebSocketTransport.receiveFailure(
                dropped, statusCode: nil, closeCode: closeCode) as? TranscriptionError
        #expect(failure?.kind == .serverClosed)
        #expect(failure?.closeCode == closeCode)
    }

    for closeCode in [1008, 1011, 1013] {
        let failure =
            URLSessionWebSocketTransport.receiveFailure(
                dropped, statusCode: nil, closeCode: closeCode) as? TranscriptionError
        #expect(failure?.closeCode == closeCode)
    }
}
