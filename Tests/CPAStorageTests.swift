import Foundation
import CryptoKit

extension StatusRenderingTests {
    @ProviderActor static func testCPAStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.enc")
        let key = SymmetricKey(size: .bits256)
        let store = CredentialStorage(storageURL: file, encryptionKey: key)
        store.setWebSession(sessionKey: "fixture-session", organizationId: "fixture-org")
        store.setKimiCredential("fixture-kimi")
        let connection = try CPAConnection(address: "https://fixture.invalid", key: "fixture-management-secret")
        try store.saveCPAConnection(connection)
        let encrypted = try Data(contentsOf: file)
        precondition(!String(decoding: encrypted, as: UTF8.self).contains(connection.key), "CPA key saved in plaintext")
        let reopened = CredentialStorage(storageURL: file, encryptionKey: key)
        precondition(reopened.cpaConnection == connection, "CPA connection did not survive encrypted reload")
        try reopened.saveCPAConnection(nil)
        let cleared = CredentialStorage(storageURL: file, encryptionKey: key)
        precondition(cleared.cpaConnection == nil && cleared.sessionKey == "fixture-session" && cleared.kimiCredential == "fixture-kimi", "CPA removal erased direct credentials")
        let failed = CredentialStorage(storageURL: directory.appendingPathComponent("absent/credentials.enc"), encryptionKey: key)
        do { try failed.saveCPAConnection(connection); fatalError("Persistence failure was ignored") } catch {}
        precondition(failed.cpaConnection == nil, "Failed persistence changed in-memory connection")
        print("PASS: CPA encrypted persistence, removal isolation, and persistence failure")
    }
}
