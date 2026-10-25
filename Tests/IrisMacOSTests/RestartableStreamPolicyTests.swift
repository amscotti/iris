import Foundation
import Testing

@testable import IrisMacOS

/// Locks the stream buffering contract: the default is lossless (hotkey
/// edges and audio must not be dropped), and an explicit newest policy still
/// coalesces when a caller asks for it.
@Test func newestPolicyCoalescesToTheLatestEdge() async {
    let host = RestartableStream<Int>(bufferingPolicy: .bufferingNewest(1))
    host.currentContinuation.yield(1)
    host.currentContinuation.yield(2)
    host.currentContinuation.yield(3)
    var iterator = host.currentStream.makeAsyncIterator()
    #expect(await iterator.next() == 3)
    host.finish()
    #expect(await iterator.next() == nil)
}

@Test func rotatePreservesTheBufferingPolicy() async {
    let host = RestartableStream<Int>(bufferingPolicy: .bufferingNewest(1))
    host.currentContinuation.yield(1)
    host.rotate()
    host.currentContinuation.yield(2)
    host.currentContinuation.yield(3)
    var iterator = host.currentStream.makeAsyncIterator()
    #expect(await iterator.next() == 3)
}

@Test func defaultPolicyKeepsEveryValue() async {
    let host = RestartableStream<Int>()
    host.currentContinuation.yield(1)
    host.currentContinuation.yield(2)
    host.currentContinuation.yield(3)
    host.finish()
    var seen: [Int] = []
    for await value in host.currentStream { seen.append(value) }
    #expect(seen == [1, 2, 3])
}
