import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func boolDecodesCommonSpellings() {
    let config = ProviderConfiguration(
        provider: .mock,
        values: [
            "t1": "true", "t2": "TRUE", "t3": "1", "t4": "yes", "t5": "Yes",
            "f1": "false", "f2": "0", "f3": "no", "f4": "anything",
        ])
    #expect(config.bool("t1"))
    #expect(config.bool("t2"))
    #expect(config.bool("t3"))
    #expect(config.bool("t4"))
    #expect(config.bool("t5"))
    #expect(!config.bool("f1"))
    #expect(!config.bool("f2"))
    #expect(!config.bool("f3"))
    #expect(!config.bool("f4"))
    #expect(!config.bool("missing"))
    #expect(config.bool("missing", default: true))
}

@Test func boolTrimsSurroundingWhitespace() {
    let config = ProviderConfiguration(
        provider: .mock, values: ["a": " true ", "b": "\n1\t", "c": " yes", "d": " false "])
    #expect(config.bool("a"))
    #expect(config.bool("b"))
    #expect(config.bool("c"))
    #expect(!config.bool("d"))
}

@Test func stringListSplitsTrimsAndDropsBlanks() {
    let config = ProviderConfiguration(
        provider: .mock,
        values: ["bias": "en, fr ,,de ", "empty": "", "blank": " , "])
    #expect(config.stringList("bias") == ["en", "fr", "de"])
    #expect(config.stringList("empty") == [])
    #expect(config.stringList("blank") == [])
    #expect(config.stringList("missing") == [])
}

@Test func apiKeyIsNilWhenMissingOrBlank() {
    #expect(ProviderConfiguration(provider: .mock, values: [:]).apiKey == nil)
    #expect(ProviderConfiguration(provider: .mock, values: ["apiKey": ""]).apiKey == nil)
    #expect(ProviderConfiguration(provider: .mock, values: ["apiKey": "k"]).apiKey == "k")
}

@Test func stringFallsBackToDefault() {
    let config = ProviderConfiguration(provider: .mock, values: ["present": "value"])
    #expect(config.string("present") == "value")
    #expect(config.string("missing") == nil)
    #expect(config.string("missing", default: "fallback") == "fallback")
}

@Test func nonPickerFieldTypesExposeNoPresets() {
    #expect(ConfigFieldType.secret.presetCases == nil)
    #expect(ConfigFieldType.bool.presetCases == nil)
    #expect(!ConfigFieldType.secret.allowsCustom)
    #expect(!ConfigFieldType.bool.allowsCustom)
    #expect(!ConfigFieldType.string.allowsCustom)
    let plain = ConfigFieldType.enum(cases: ["a"])
    #expect(plain.pickerSelection(for: "b", customTag: "custom") == "b")
}
