import XCTest

@testable import NascKit

/// Against the real Keychain, under a throwaway service so nothing real is touched.
final class CredentialStoreTests: XCTestCase {
    private var store: CredentialStore!
    private let a = "ws://a.example:4100"
    private let b = "ws://b.example:4100"

    override func setUp() {
        store = CredentialStore(service: "com.mnotony.nasc.credential.test.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.deleteCredential(server: a)
        try? store.deleteCredential(server: b)
    }

    func testNothingStoredReadsAsNone() throws {
        XCTAssertNil(try store.credential(server: a))
    }

    func testSavedCredentialReadsBackTrimmed() throws {
        try store.save("  secret-a \n", server: a)
        XCTAssertEqual(try store.credential(server: a), "secret-a")
    }

    func testSavingAgainReplacesIt() throws {
        try store.save("first", server: a)
        try store.save("second", server: a)
        XCTAssertEqual(try store.credential(server: a), "second")
    }

    func testSavingEmptyRemovesIt() throws {
        try store.save("secret-a", server: a)
        try store.save("   ", server: a)
        XCTAssertNil(try store.credential(server: a))
    }

    func testCredentialsAreKeptPerServer() throws {
        try store.save("secret-a", server: a)
        try store.save("secret-b", server: b)
        XCTAssertEqual(try store.credential(server: a), "secret-a")
        XCTAssertEqual(try store.credential(server: b), "secret-b")
    }

    func testSavingUnderANewURLMovesItOffTheOldOne() throws {
        try store.save("secret", server: a)
        try store.save("secret", server: b, replacing: a)
        XCTAssertNil(try store.credential(server: a))
        XCTAssertEqual(try store.credential(server: b), "secret")
    }

    func testReplacingTheSameURLKeepsIt() throws {
        try store.save("secret", server: a, replacing: a)
        XCTAssertEqual(try store.credential(server: a), "secret")
    }

    func testDeletingWhatIsntThereIsFine() throws {
        XCTAssertNoThrow(try store.deleteCredential(server: a))
    }
}
