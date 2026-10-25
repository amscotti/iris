import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

/// Streams a large body in chunks on the loading thread's run loop and
/// records how much was delivered before the client stopped the load.
/// Start, ticks, and stop all run on that one loading thread.
final class ChunkedBodyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var totalBytes = 0
    nonisolated(unsafe) private static var sentBytes = 0
    private static let chunk = Data(repeating: 0x61, count: 32 * 1024)

    private var timer: Timer?

    static func reset(totalBytes: Int) {
        lock.withLock {
            self.totalBytes = totalBytes
            sentBytes = 0
        }
    }

    static var bytesSent: Int { lock.withLock { sentBytes } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let timer = Timer(
            timeInterval: 0.002, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    @objc private func tick() {
        let done = Self.lock.withLock { () -> Bool in
            guard Self.sentBytes < Self.totalBytes else { return true }
            Self.sentBytes += Self.chunk.count
            return false
        }
        if done {
            timer?.invalidate()
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didLoad: Self.chunk)
        }
    }

    override func stopLoading() {
        timer?.invalidate()
    }
}

@Test func oversizedReplyIsCutOffWhileStreamingNotAfterBuffering() async {
    // Far more than the client should ever read, so the assertion checks that
    // it stopped early rather than how fast this machine consumes bytes.
    let totalBytes = 64 * 1024 * 1024
    ChunkedBodyProtocol.reset(totalBytes: totalBytes)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChunkedBodyProtocol.self]
    let client = RewriteChatClient(
        configuration: ProviderConfiguration(provider: .meta, values: ["apiKey": "test-key"]),
        registry: AppProviderAssembly.defaultRegistry(),
        session: URLSession(configuration: config), timeoutSeconds: 10, deadlineSeconds: 60)
    let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
    #expect(await client.rewrite(text: "raw words", prompt: prompt) == nil)
    // The cap must stop the download shortly after 256 KiB, not after the
    // whole body has been buffered in memory.
    #expect(ChunkedBodyProtocol.bytesSent > RewriteChatClient.maxResponseBytes)
    #expect(ChunkedBodyProtocol.bytesSent < 8 * RewriteChatClient.maxResponseBytes)
    #expect(ChunkedBodyProtocol.bytesSent < totalBytes)
}
