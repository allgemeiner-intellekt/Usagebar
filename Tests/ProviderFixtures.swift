// In-memory store for refresh tests so fixtures never reach the user's file.
@ProviderActor final class CredentialStorage {
    static let shared = CredentialStorage()
    var cpaConnection: CPAConnection?

    func saveCPAConnection(_ value: CPAConnection?) throws {
        cpaConnection = value
    }
}
