//
//  CredentialStorage.swift
//  JustaUsageBar
//
//  Encrypted file-based credential storage (no Keychain prompts)
//

import Foundation
import CryptoKit

@ProviderActor
final class CredentialStorage {
    static let shared = CredentialStorage()

    private let storageURL: URL?
    private let keyOverride: SymmetricKey?
    private let fileName = "credentials.enc"
    private var cachedCredentials: Credentials?

    nonisolated struct Credentials: Codable {
        var cpaConnection: CPAConnection?
    }

    init(storageURL: URL? = nil, encryptionKey: SymmetricKey? = nil) {
        self.storageURL = storageURL
        self.keyOverride = encryptionKey
        loadCredentials()
    }

    var cpaConnection: CPAConnection? { cachedCredentials?.cpaConnection }

    /// Propagate persistence failure so connection setup cannot activate unsaved credentials.
    func saveCPAConnection(_ connection: CPAConnection?) throws {
        var credentials = cachedCredentials ?? Credentials()
        credentials.cpaConnection = connection
        let data = try encrypt(JSONEncoder().encode(credentials))
        try data.write(to: credentialsFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
        cachedCredentials = credentials
    }

    // MARK: - File Storage

    private var credentialsFileURL: URL {
        if let storageURL { return storageURL }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("JustaUsageBar", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        return appFolder.appendingPathComponent(fileName)
    }

    private func loadCredentials() {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else {
            cachedCredentials = nil
            return
        }

        do {
            let encryptedData = try Data(contentsOf: credentialsFileURL)
            let decryptedData = try decrypt(encryptedData)
            cachedCredentials = try JSONDecoder().decode(Credentials.self, from: decryptedData)
        } catch {
            print("Failed to load credentials: \(error)")
            cachedCredentials = nil
        }
    }

    // MARK: - Encryption (AES-GCM with device-specific key)

    private lazy var encryptionKey: SymmetricKey = {
        if let keyOverride { return keyOverride }
        // Generate a deterministic key based on machine-specific info
        // This ensures only this machine can decrypt the credentials
        let machineId = getMachineIdentifier()
        let salt = "JustaUsageBar.v1"
        let keyMaterial = "\(machineId).\(salt)"

        // Use SHA256 to derive a 256-bit key
        let hash = SHA256.hash(data: Data(keyMaterial.utf8))
        return SymmetricKey(data: hash)
    }()

    private func getMachineIdentifier() -> String {
        // Use hardware UUID as machine identifier
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        defer { IOObjectRelease(platformExpert) }

        if let serialNumberAsCFString = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) {
            return (serialNumberAsCFString.takeUnretainedValue() as? String) ?? "default"
        }

        return "default"
    }

    private func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "CredentialStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: encryptionKey)
    }
}
