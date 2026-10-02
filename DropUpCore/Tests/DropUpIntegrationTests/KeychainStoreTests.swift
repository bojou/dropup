#if os(macOS)
import Foundation
import Testing
import DropUpCore

/// Uses the real macOS Keychain under a throwaway service name.
struct KeychainStoreTests {
    @Test func removeAllPasswordsClearsEveryItemOfTheService() throws {
        let service = "app.dropup.test.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let other = KeychainCredentialStore(service: service + ".other")
        defer {
            try? store.removeAllPasswords()
            try? other.removeAllPasswords()
        }

        try store.setPassword("one", for: "alice@files.example.com:22")
        try store.setPassword("two", for: "bob@files.example.com:21")
        try store.setPassword("three", for: "carol@other.example.com:22")
        try other.setPassword("keep", for: "alice@files.example.com:22")
        #expect(try store.password(for: "bob@files.example.com:21") == "two")

        try store.removeAllPasswords()

        #expect(try store.password(for: "alice@files.example.com:22") == nil)
        #expect(try store.password(for: "bob@files.example.com:21") == nil)
        #expect(try store.password(for: "carol@other.example.com:22") == nil)
        // Only this app's service is touched.
        #expect(try other.password(for: "alice@files.example.com:22") == "keep")

        // Nothing left to remove is fine.
        try store.removeAllPasswords()
    }
}
#endif
