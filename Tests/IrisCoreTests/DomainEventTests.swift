import Foundation
import Testing

@testable import IrisCore

@Test func eventTextSurfacesHypothesesOnly() {
    #expect(TranscriptionEvent.partial("hel").text == "hel")
    #expect(TranscriptionEvent.final("hi").text == "hi")
    #expect(TranscriptionEvent.speechStarted.text == nil)
    #expect(TranscriptionEvent.speechComplete(turnId: "t-1", transcript: "").text == nil)
    #expect(TranscriptionEvent.error(TranscriptionError(kind: .network, message: "down")).text == nil)
}

@Test func onlyFinalEventsAreFinal() {
    #expect(TranscriptionEvent.final("hi").isFinal)
    #expect(!TranscriptionEvent.partial("hi").isFinal)
    #expect(!TranscriptionEvent.speechStarted.isFinal)
    #expect(!TranscriptionEvent.speechComplete(turnId: "t-1", transcript: "").isFinal)
    #expect(!TranscriptionEvent.error(TranscriptionError(kind: .network, message: "down")).isFinal)
}

@Test func frameSampleCountMatchesSamples() {
    #expect(PCMFrame(samples: [1, -2, 3]).sampleCount == 3)
    #expect(PCMFrame(samples: []).sampleCount == 0)
}
