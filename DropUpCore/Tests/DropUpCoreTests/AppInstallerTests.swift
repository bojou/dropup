import Foundation
import Testing
@testable import DropUpCore

struct AppInstallerTests {
    private func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dropup-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(in folder: URL, marker: String) throws -> URL {
        let app = folder.appendingPathComponent("DropUp.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"))
        return app
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    @Test func installsIntoAnEmptyFolder() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = try makeApp(in: work.appendingPathComponent("image", isDirectory: true), marker: "new")
        let applications = work.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let destination = applications.appendingPathComponent("DropUp.app", isDirectory: true)

        try AppInstaller.install(source: source, destination: destination, discardExisting: { _ in Issue.record("nothing to discard") })

        #expect(try marker(of: destination) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["DropUp.app"])
    }

    @Test func replacesAnOlderCopyAndHandsItToTheDiscardStep() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = try makeApp(in: work.appendingPathComponent("image", isDirectory: true), marker: "new")
        let applications = work.appendingPathComponent("Applications", isDirectory: true)
        let existing = try makeApp(in: applications, marker: "old")
        var discarded: [URL] = []

        try AppInstaller.install(source: source, destination: existing, discardExisting: { url in
            discarded.append(url)
            try FileManager.default.removeItem(at: url)
        })

        #expect(discarded.map(\.lastPathComponent) == ["DropUp.app"])
        #expect(try marker(of: existing) == "new")
    }

    @Test func aFailedCopyLeavesTheInstalledAppAndNoLeftovers() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let missingSource = work.appendingPathComponent("image/DropUp.app", isDirectory: true)
        let applications = work.appendingPathComponent("Applications", isDirectory: true)
        let existing = try makeApp(in: applications, marker: "old")

        #expect(throws: (any Error).self) {
            try AppInstaller.install(source: missingSource, destination: existing, discardExisting: { _ in
                Issue.record("the old copy must not be touched when the new one can't be made")
            })
        }

        #expect(try marker(of: existing) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["DropUp.app"])
    }

    @Test func aFailureWhileDiscardingKeepsTheOldCopyAndCleansUp() throws {
        struct Locked: Error {}
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = try makeApp(in: work.appendingPathComponent("image", isDirectory: true), marker: "new")
        let applications = work.appendingPathComponent("Applications", isDirectory: true)
        let existing = try makeApp(in: applications, marker: "old")

        #expect(throws: Locked.self) {
            try AppInstaller.install(source: source, destination: existing, discardExisting: { _ in throw Locked() })
        }

        #expect(try marker(of: existing) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["DropUp.app"])
    }

    @Test func picksTheFirstFolderThatExists() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let missing = work.appendingPathComponent("Nope", isDirectory: true)
        let present = work.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)

        let destination = try AppInstaller.destination(appName: "DropUp.app", in: [missing, present])

        #expect(destination.deletingLastPathComponent().lastPathComponent == "Applications")
        #expect(destination.lastPathComponent == "DropUp.app")
    }

    @Test func createsTheLastFolderWhenNoneExist() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let first = work.appendingPathComponent("A", isDirectory: true)
        let last = work.appendingPathComponent("B", isDirectory: true)

        let destination = try AppInstaller.destination(appName: "DropUp.app", in: [first, last])

        #expect(destination == last.appendingPathComponent("DropUp.app", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: last.path))
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func noFoldersMeansNoDestination() {
        #expect(throws: AppInstallError.noApplicationsFolder) {
            try AppInstaller.destination(appName: "DropUp.app", in: [])
        }
    }
}
