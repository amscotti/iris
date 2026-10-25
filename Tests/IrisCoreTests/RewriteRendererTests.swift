import Foundation
import Testing

@testable import IrisCore

@Test func rendererReplacesPlaceholderWithEscapedBlock() {
    let message = RewritePromptRenderer.developerMessage(template: "Rewrite this: {{transcript}}", transcript: "hello")
    #expect(message == "Rewrite this: <dictation>hello</dictation>")
}

@Test func rendererReplacesEveryPlaceholder() {
    let message = RewritePromptRenderer.developerMessage(template: "{{transcript}} / {{transcript}}", transcript: "hi")
    #expect(message == "<dictation>hi</dictation> / <dictation>hi</dictation>")
}

@Test func rendererAppendsBlockWhenPlaceholderAbsent() {
    let message = RewritePromptRenderer.developerMessage(template: "Clean this up.", transcript: "hello")
    #expect(message == "Clean this up.\n\n<dictation>hello</dictation>")
}

@Test func rendererEmptyTemplateYieldsBlockAlone() {
    #expect(RewritePromptRenderer.developerMessage(template: "", transcript: "hello") == "<dictation>hello</dictation>")
    #expect(RewritePromptRenderer.userMessage(transcript: "hello") == "<dictation>hello</dictation>")
}

@Test func rendererEscapesAmpersandsAndTags() {
    let message = RewritePromptRenderer.developerMessage(
        template: "{{transcript}}", transcript: "fish & chips <b>yum</b>")
    #expect(message == "<dictation>fish &amp; chips &lt;b&gt;yum&lt;/b&gt;</dictation>")
}

@Test func rendererEscapesBeforeWrapping() {
    let block = RewritePromptRenderer.dictationBlock(for: "a>b & <c")
    #expect(block == "<dictation>a&gt;b &amp; &lt;c</dictation>")
}
