import XCTest
import SwiftData
@testable import OpenCAN

@MainActor
final class SSHKeyPairSecurityTests: XCTestCase {
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(
            for: SSHKeyPair.self, Node.self, Workspace.self, Session.self,
            configurations: config
        )
        modelContext = ModelContext(modelContainer)
    }

    override func tearDown() async throws {
        if let modelContext {
            let keys = try? modelContext.fetch(FetchDescriptor<SSHKeyPair>())
            keys?.forEach { $0.deletePrivateKeyFromKeychain() }
        }
        modelContext = nil
        modelContainer = nil
    }

    func testInitStoresPrivateKeyInKeychain() throws {
        let pem = Data("test-private-key".utf8)
        let key = try SSHKeyPair(name: "init-key", privateKeyPEM: pem)
        modelContext.insert(key)
        try modelContext.save()

        XCTAssertTrue(key.privateKeyPEM.isEmpty)
        XCTAssertNotNil(key.keychainIdentifier)
        XCTAssertEqual(try key.privateKeyDataForConnection(), pem)
    }

    func testMigrateLegacyPrivateKeyClearsSwiftDataBlob() throws {
        let key = try SSHKeyPair(name: "legacy-key", privateKeyPEM: Data("initial".utf8))
        modelContext.insert(key)
        try modelContext.save()

        key.deletePrivateKeyFromKeychain()
        key.privateKeyPEM = Data("legacy-value".utf8)

        let migrated = try key.migrateLegacyPrivateKeyIfNeeded()

        XCTAssertTrue(migrated)
        XCTAssertTrue(key.privateKeyPEM.isEmpty)
        XCTAssertEqual(try key.privateKeyDataForConnection(), Data("legacy-value".utf8))
    }

    func testCleanupOrphanedKeychainEntriesRemovesDeletedRecords() throws {
        let survivor = try SSHKeyPair(name: "survivor", privateKeyPEM: Data("alive".utf8))
        let orphan = try SSHKeyPair(name: "orphan", privateKeyPEM: Data("orphaned".utf8))
        modelContext.insert(survivor)
        modelContext.insert(orphan)
        try modelContext.save()

        modelContext.delete(orphan)
        try modelContext.save()

        let persistedKeys = try modelContext.fetch(FetchDescriptor<SSHKeyPair>())
        let removed = try SSHKeyPair.cleanupOrphanedKeychainEntries(
            validIdentifiers: SSHKeyPair.keychainIdentifiers(in: persistedKeys)
        )

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try survivor.privateKeyDataForConnection(), Data("alive".utf8))
        XCTAssertThrowsError(try orphan.privateKeyDataForConnection())
    }
}
