import Foundation

public protocol ConfigurationStorage {
    associatedtype Configuration: Codable
    func load() -> Configuration
    func save(_ value: Configuration) throws
}
public protocol ProviderSecretStore {
    func read(_ id: UUID) throws -> String
    func save(_ key: String, id: UUID) throws
    func delete(_ id: UUID) throws
}
@MainActor public protocol TextDelivery: AnyObject {
    /// True means the platform insertion API was invoked for the matching foreground
    /// document. It is not an acknowledgement that a host sent/saved the text.
    func insert(_ text: String, target: UUID) -> Bool
    func deleteBackward(target: UUID) -> Bool
}
