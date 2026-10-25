import Foundation

extension SettingsRepository {
    private static let topLevelKeys: Set<String> = [
        "schemaVersion", "providerName", "providerConfigs", "providerValues", "hotkey", "insertMethod",
        "trailingSpace", "trailingNewline", "reduceMotion", "pillTranslucent", "waveformColorHex", "prompts",
        "selectedPromptID",
    ]
    private static let hotkeyKeys: Set<String> = ["keyCode", "modifiers", "mode"]
    private static let promptKeys: Set<String> = ["id", "name", "template", "order", "enabled", "model", "effort"]
    private static let legacyProviderValueKeys: Set<String> = ["model", "effort"]

    /// Backup copies never keep plaintext secrets. Known non-secret settings
    /// are retained byte-for-byte when possible. Unknown providers/fields,
    /// unsupported schemas, and unparseable nonempty payloads are not treated
    /// as safe merely because no recognized secret key was found.
    static func redactingSecrets(from raw: Data, registry: ProviderRegistry) -> Data {
        guard !raw.isEmpty else { return raw }
        if let object = try? JSONSerialization.jsonObject(with: raw) {
            if let placeholder = canonicalRecoveryPlaceholder(object) { return placeholder }
            guard let redacted = sanitizingPayload(object, registry: registry) else {
                return recoveryPlaceholder(for: raw)
            }
            guard redacted.changed else { return raw }
            guard let encoded = try? JSONSerialization.data(withJSONObject: redacted.object) else {
                return recoveryPlaceholder(for: raw)
            }
            return encoded
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let object = try? PropertyListSerialization.propertyList(from: raw, options: [], format: &format),
            let redacted = sanitizingPayload(object, registry: registry)
        else { return recoveryPlaceholder(for: raw) }
        guard redacted.changed else { return raw }
        guard
            let encoded = try? PropertyListSerialization.data(
                fromPropertyList: redacted.object, format: format, options: 0)
        else { return recoveryPlaceholder(for: raw) }
        return encoded
    }

    private static func sanitizingPayload(
        _ object: Any, registry: ProviderRegistry
    ) -> (object: Any, changed: Bool)? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let version = dictionary["schemaVersion"] as? Int, version > currentVersion { return nil }
        var result = dictionary
        var changed = false
        for (key, value) in dictionary {
            guard topLevelKeys.contains(key), validTopLevelValue(key, value) else { return nil }
            let sanitized: (object: Any, changed: Bool)?
            switch key {
            case "providerConfigs":
                sanitized = sanitizingProviderConfigs(value, registry: registry)
            case "providerValues":
                sanitized = sanitizingLegacyProviderValues(
                    value, providerName: dictionary["providerName"] as? String, registry: registry)
            case "hotkey":
                sanitized = sanitizingHotkey(value)
            case "prompts":
                sanitized = sanitizingPrompts(value)
            default:
                sanitized = (value, false)
            }
            guard let sanitized else { return nil }
            result[key] = sanitized.object
            changed = changed || sanitized.changed
        }
        return (result, changed)
    }

    private static func sanitizingProviderConfigs(
        _ value: Any, registry: ProviderRegistry
    ) -> (object: Any, changed: Bool)? {
        guard let configs = value as? [String: Any] else { return nil }
        var result = configs
        var changed = false
        for (name, rawValues) in configs {
            // A malformed namespace contains no recoverable typed fields;
            // dropping it is safe and lets other providers remain useful.
            guard let values = rawValues as? [String: Any] else {
                result[name] = nil
                changed = true
                continue
            }
            guard let descriptor = registry.descriptor(forName: name) else { return nil }
            var cleaned: [String: Any] = [:]
            for (field, fieldValue) in values {
                if descriptor.persistentSecretKeys.contains(field) {
                    changed = true
                    continue
                }
                guard let fieldDescriptor = descriptor.field(for: field),
                    fieldDescriptor.type != .secret, fieldValue is String
                else { return nil }
                cleaned[field] = fieldValue
            }
            result[name] = cleaned
        }
        return (result, changed)
    }

    private static func sanitizingLegacyProviderValues(
        _ value: Any, providerName: String?, registry: ProviderRegistry
    ) -> (object: Any, changed: Bool)? {
        guard let values = value as? [String: Any] else { return nil }
        guard !values.isEmpty else { return (value, false) }
        guard let descriptor = registry.descriptor(forName: providerName ?? AppSettings.legacyProviderName)
        else { return nil }
        let allowed = Set(descriptor.fields.filter { $0.type != .secret }.map(\.key))
            .union(legacyProviderValueKeys)
        var cleaned: [String: Any] = [:]
        var changed = false
        for (field, fieldValue) in values {
            if descriptor.persistentSecretKeys.contains(field) {
                changed = true
                continue
            }
            guard allowed.contains(field), fieldValue is String else { return nil }
            cleaned[field] = fieldValue
        }
        return (cleaned, changed)
    }

    private static func validTopLevelValue(_ key: String, _ value: Any) -> Bool {
        switch key {
        case "schemaVersion": return value is Int
        case "providerName", "insertMethod": return value is String
        case "trailingSpace", "trailingNewline", "reduceMotion", "pillTranslucent": return value is Bool
        case "waveformColorHex", "selectedPromptID": return value is String || value is NSNull
        default: return true
        }
    }

    private static func sanitizingHotkey(_ value: Any) -> (object: Any, changed: Bool)? {
        guard let dictionary = value as? [String: Any], dictionary.keys.allSatisfy({ hotkeyKeys.contains($0) })
        else { return nil }
        for (key, fieldValue) in dictionary {
            switch key {
            case "keyCode", "modifiers":
                guard fieldValue is Int else { return nil }
            case "mode":
                guard fieldValue is String else { return nil }
            default:
                return nil
            }
        }
        return (dictionary, false)
    }

    private static func validPromptField(_ key: String, _ value: Any) -> Bool {
        switch key {
        case "id", "name", "template", "model", "effort": return value is String
        case "order": return value is Int
        case "enabled": return value is Bool
        default: return false
        }
    }

    private static func sanitizingPrompts(_ value: Any) -> (object: Any, changed: Bool)? {
        guard let prompts = value as? [Any] else { return nil }
        for prompt in prompts {
            guard let dictionary = prompt as? [String: Any],
                dictionary.allSatisfy({ promptKeys.contains($0.key) && validPromptField($0.key, $0.value) })
            else { return nil }
        }
        return (prompts, false)
    }

    private static let placeholderReason = "Original payload omitted because it could not be safely redacted."

    private static func canonicalRecoveryPlaceholder(_ object: Any) -> Data? {
        guard let dictionary = object as? [String: Any], dictionary.count == 3,
            dictionary["irisRecoveryBackupPlaceholder"] as? Bool == true,
            let byteCount = dictionary["originalByteCount"] as? Int,
            dictionary["reason"] is String
        else { return nil }
        return recoveryPlaceholder(originalByteCount: byteCount)
    }

    private static func recoveryPlaceholder(for raw: Data) -> Data {
        recoveryPlaceholder(originalByteCount: raw.count)
    }

    private static func recoveryPlaceholder(originalByteCount: Int) -> Data {
        let object: [String: Any] = [
            "irisRecoveryBackupPlaceholder": true,
            "originalByteCount": originalByteCount,
            "reason": placeholderReason,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"irisRecoveryBackupPlaceholder":true}"#.utf8)
    }
}
