import Foundation
import Testing
@testable import DropUpCore

struct BrowseSessionTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private let docs = RemoteEntry(name: "docs", kind: .folder)
    private let notes = RemoteEntry(name: "notes.txt", kind: .file, size: 5)

    private func makeBrowser(session: FakeSession) -> (BrowseSession, FakeConnector) {
        let connector = FakeConnector(session: session)
        return (BrowseSession(connectors: connector, config: config, password: "secret"), connector)
    }

    @Test func listsAFolderAndNormalizesThePath() async throws {
        let session = FakeSession(entries: ["/drops": [docs, notes]])
        let (browser, connector) = makeBrowser(session: session)

        let entries = try await browser.entries(atPath: "/drops/")

        #expect(entries == [docs, notes])
        #expect(connector.passwords == ["secret"])
    }

    @Test func keepsOneConnectionForSeveralFolders() async throws {
        let session = FakeSession(entries: ["/": [docs], "/docs": [notes]])
        let (browser, connector) = makeBrowser(session: session)

        _ = try await browser.entries(atPath: "/")
        _ = try await browser.entries(atPath: "/docs")
        _ = try await browser.entries(atPath: "/")

        #expect(connector.connectionCount == 1)
        #expect(session.closeCount == 0)
    }

    @Test func reconnectsOnceWhenTheIdleLoginWasDropped() async throws {
        let session = FakeSession(entries: ["/": [docs]])
        let (browser, connector) = makeBrowser(session: session)
        _ = try await browser.entries(atPath: "/")

        // The server drops the idle login, so the next listing finds a dead connection.
        session.failNextListing(with: UploaderError.connectionFailed("The server closed the connection."))
        let entries = try await browser.entries(atPath: "/")

        #expect(entries == [docs])
        #expect(connector.connectionCount == 2)
        #expect(session.closeCount == 1)
    }

    @Test func aFreshConnectionThatFailsIsNotRetried() async throws {
        let session = FakeSession(listFailures: [UploaderError.timedOut, UploaderError.timedOut])
        let (browser, connector) = makeBrowser(session: session)

        await #expect(throws: UploaderError.timedOut) { _ = try await browser.entries(atPath: "/") }

        #expect(connector.connectionCount == 1)
        #expect(session.listingCount == 1)
        #expect(session.closeCount == 1)
    }

    @Test func aServerAnswerKeepsTheConnectionAndIsNotRetried() async throws {
        let refusal = UploaderError.serverRejected(code: 550, message: "No such folder")
        let session = FakeSession(entries: ["/": [docs]])
        let (browser, connector) = makeBrowser(session: session)

        // Open a connection, then ask for a folder that doesn't exist.
        _ = try await browser.entries(atPath: "/")
        session.failNextListing(with: refusal)
        await #expect(throws: refusal) { _ = try await browser.entries(atPath: "/nope") }
        let entries = try await browser.entries(atPath: "/")

        #expect(entries == [docs])
        #expect(connector.connectionCount == 1)
        #expect(session.closeCount == 0)
    }

    @Test func listingsNeverOverlapOnOneConnection() async throws {
        let session = FakeSession(entries: ["/": [docs]])
        let (browser, _) = makeBrowser(session: session)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try? await browser.entries(atPath: "/") }
            }
        }

        #expect(session.listingCount == 6)
        #expect(session.mostListingsAtOnce == 1)
    }

    @Test func closeEndsTheConnectionAndALaterListingConnectsAgain() async throws {
        let session = FakeSession(entries: ["/": [docs]])
        let (browser, connector) = makeBrowser(session: session)

        _ = try await browser.entries(atPath: "/")
        await browser.close()
        await browser.close()
        _ = try await browser.entries(atPath: "/")

        #expect(session.closeCount == 1)
        #expect(connector.connectionCount == 2)
    }

    @Test func aCancelledListingDropsTheUncertainConnection() async throws {
        // Long enough that a busy machine can't let the listing finish before the cancel: the cancel cuts the wait short.
        let session = FakeSession(entries: ["/": [docs]], listDelayMilliseconds: 10_000)
        let (browser, connector) = makeBrowser(session: session)

        let task = Task { try await browser.entries(atPath: "/") }
        try await eventually { session.listingCount == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(session.closeCount == 1)

        // The next listing starts over on a fresh connection.
        session.setListDelay(milliseconds: 2)
        let entries = try await browser.entries(atPath: "/")
        #expect(entries == [docs])
        #expect(connector.connectionCount == 2)
    }

    @Test func entriesSortFoldersFirstInFinderOrder() {
        let sorted = RemoteEntry.sorted([
            RemoteEntry(name: "file10.txt", kind: .file),
            RemoteEntry(name: "Zeta", kind: .folder),
            RemoteEntry(name: "file2.txt", kind: .file),
            RemoteEntry(name: "alpha", kind: .folder),
            RemoteEntry(name: "shortcut", kind: .link),
        ])
        #expect(sorted.map(\.name) == ["alpha", "Zeta", "file2.txt", "file10.txt", "shortcut"])
    }

    @Test func theTrailListsEveryFolderFromTheRoot() {
        #expect(RemotePath.trail(to: "/").map(\.path) == ["/"])
        let steps = RemotePath.trail(to: "var//www/My Site/")
        #expect(steps.map(\.name) == ["/", "var", "www", "My Site"])
        #expect(steps.map(\.path) == ["/", "/var", "/var/www", "/var/www/My Site"])
    }

    @Test func hiddenMeansALeadingDot() {
        #expect(RemoteEntry(name: ".htaccess", kind: .file).isHidden)
        #expect(!RemoteEntry(name: "index.html", kind: .file).isHidden)
    }
}
