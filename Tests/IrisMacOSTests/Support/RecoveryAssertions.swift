import Foundation
import Testing

@testable import IrisCore

func expectRecoveryBackupPlaceholder(
    _ persistence: any PersistenceProviding, original: Data
) throws {
    let backup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    let object = try #require(try JSONSerialization.jsonObject(with: backup) as? [String: Any])
    #expect(object["irisRecoveryBackupPlaceholder"] as? Bool == true)
    #expect(object["originalByteCount"] as? Int == original.count)
}
