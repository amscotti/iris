import Foundation
import IrisCore

final class FaultingSettingsStore: PersistenceProviding, @unchecked Sendable {
    enum Failure: Error { case read, write }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var readsFail = false
    private var writesFail = false
    private var backupsFail = false

    var failReads: Bool {
        get { lock.withLock { readsFail } }
        set { lock.withLock { readsFail = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { writesFail } }
        set { lock.withLock { writesFail = newValue } }
    }
    var failBackup: Bool {
        get { lock.withLock { backupsFail } }
        set { lock.withLock { backupsFail = newValue } }
    }

    func load(key: String) throws -> Data? {
        try lock.withLock {
            if readsFail { throw Failure.read }
            return values[key]
        }
    }
    func save(_ data: Data, forKey key: String) throws {
        try lock.withLock {
            if writesFail || (backupsFail && key.hasPrefix(SettingsRepository.backupKey)) {
                throw Failure.write
            }
            values[key] = data
        }
    }
    func delete(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
