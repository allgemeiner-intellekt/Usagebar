import Foundation
import CryptoKit

extension StatusRenderingTests {
    @ProviderActor static func testCPAStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.enc")
        let key = SymmetricKey(size: .bits256)
        let connection = try CPAConnection(address: "https://fixture.invalid", key: "fixture-management-secret")
        let legacy: [String: Any] = [
            "sessionKey": "fixture-session",
            "organizationId": "fixture-org",
            "claudeOAuth": ["accessToken": "fixture-token", "scopes": ["user:profile"]],
            "kimiCredential": "fixture-kimi"
        ]
        func writeLegacyFile(_ fields: [String: Any]) throws {
            let plaintext = try JSONSerialization.data(withJSONObject: fields)
            let encrypted = try AES.GCM.seal(plaintext, using: key)
            try encrypted.combined!.write(to: file)
        }
        try writeLegacyFile(legacy)
        let unconfigured = CredentialStorage(storageURL: file, encryptionKey: key)
        precondition(unconfigured.cpaConnection == nil, "Direct-only credentials must lead to setup")

        var legacyWithCPA = legacy
        legacyWithCPA["cpaConnection"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection))
        try writeLegacyFile(legacyWithCPA)
        let upgraded = CredentialStorage(storageURL: file, encryptionKey: key)
        precondition(upgraded.cpaConnection == connection, "Upgrade lost the saved CPA connection")

        let replacement = try CPAConnection(address: "https://other.invalid", key: "replacement-secret")
        try upgraded.saveCPAConnection(replacement)
        let encrypted = try Data(contentsOf: file)
        precondition(!String(decoding: encrypted, as: UTF8.self).contains(replacement.key), "CPA key saved in plaintext")
        let reopened = CredentialStorage(storageURL: file, encryptionKey: key)
        precondition(reopened.cpaConnection == replacement, "CPA connection did not survive encrypted reload")
        try reopened.saveCPAConnection(nil)
        let cleared = CredentialStorage(storageURL: file, encryptionKey: key)
        precondition(cleared.cpaConnection == nil, "Clear did not remove the saved CPA connection")
        let failed = CredentialStorage(storageURL: directory.appendingPathComponent("absent/credentials.enc"), encryptionKey: key)
        do { try failed.saveCPAConnection(connection); fatalError("Persistence failure was ignored") } catch {}
        precondition(failed.cpaConnection == nil, "Failed persistence changed in-memory connection")
        print("PASS: CPA legacy upgrade, encrypted persistence, removal, and persistence failure")
    }
}
