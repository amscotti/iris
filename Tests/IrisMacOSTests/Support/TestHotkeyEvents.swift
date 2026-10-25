import Foundation

@testable import IrisMacOS

@MainActor
final class TestHotkeyEvents: HotkeyEventMonitoring {
    var globalHandlers: [@MainActor (HotkeyInput) -> Void] = []
    var localHandlers: [@MainActor (HotkeyInput) -> Void] = []
    var activeTokens: Set<Int> = []
    var failGlobal = false
    var keyPressed = false
    private(set) var physicalReads = 0
    private var nextToken = 0
    /// Tokens parallel to the handler arrays, so `remove` deletes exactly
    /// the handler the token installed (indices shift together, and a
    /// removal from one list can never touch the other).
    private var globalTokens: [Int] = []
    private var localTokens: [Int] = []

    func addGlobal(_ handler: @escaping @MainActor (HotkeyInput) -> Void) -> Any? {
        guard !failGlobal else { return nil }
        globalHandlers.append(handler)
        globalTokens.append(makeToken())
        return globalTokens.last
    }

    func addLocal(_ handler: @escaping @MainActor (HotkeyInput) -> Void) -> Any? {
        localHandlers.append(handler)
        localTokens.append(makeToken())
        return localTokens.last
    }

    func remove(_ monitor: Any) {
        guard let token = monitor as? Int else { return }
        activeTokens.remove(token)
        if let index = globalTokens.firstIndex(of: token) {
            globalTokens.remove(at: index)
            globalHandlers.remove(at: index)
        } else if let index = localTokens.firstIndex(of: token) {
            localTokens.remove(at: index)
            localHandlers.remove(at: index)
        }
    }

    func isKeyPressed(_ keyCode: Int) -> Bool {
        physicalReads += 1
        return keyPressed
    }

    private func makeToken() -> Int {
        nextToken += 1
        activeTokens.insert(nextToken)
        return nextToken
    }
}
