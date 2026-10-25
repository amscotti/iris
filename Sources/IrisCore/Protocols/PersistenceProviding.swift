import Foundation

/// Plain (non-secret) keyed persistence for settings and UI state.
///
/// No wire-format guarantee: the JSON helpers use default
/// `JSONEncoder`/`Decoder` strategies, so callers must supply stable
/// `Codable` shapes (explicit keys, no date/float edge cases) rather than
/// relying on encoder settings. Writes are synchronous but neither atomic
/// nor mutually exclusive — concurrent settings access must be serialized
/// by the caller; the last completed write wins.
public protocol PersistenceProviding: Sendable {
    func load(key: String) throws -> Data?
    func save(_ data: Data, forKey key: String) throws
    func delete(key: String) throws
}

extension PersistenceProviding {
    public func load<T: Decodable>(key: String, as type: T.Type = T.self) throws -> T? {
        guard let data = try load(key: key) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, forKey key: String) throws {
        try save(JSONEncoder().encode(value), forKey: key)
    }
}
