#if os(macOS)
import Foundation
import Testing
import DropUpCore

/// Mounts a real disk image with `hdiutil`, so the parsing of its output and the eject are checked against macOS itself.
struct DiskImageTests {
    @Test func findsAndEjectsAMountedInstaller() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dropup-dmg-\(UUID().uuidString)")
        let source = work.appendingPathComponent("src")
        let app = source.appendingPathComponent("DropUp.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: app.appendingPathComponent("marker.txt"))
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent("DropUp-9.9.9.dmg")
        let volume = "DropUpTest\(Int.random(in: 1000...9999))"
        try hdiutil(["create", "-volname", volume, "-srcfolder", source.path, "-ov", "-format", "UDZO", dmg.path])
        try hdiutil(["attach", "-nobrowse", "-quiet", dmg.path])

        let images = await DiskImages.mounted()
        let mine = try #require(images.first { $0.imageURL.resolvingSymlinksInPath() == dmg.resolvingSymlinksInPath() })
        let mount = try #require(mine.mountPoints.first)
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("DropUp.app").path))

        let candidate = InstallerImages.cleanupCandidate(
            in: images, runningAppURL: URL(fileURLWithPath: "/Applications/DropUp.app"), dismissed: [],
            holdsApp: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DropUp.app").path) }
        )
        #expect(candidate?.imageURL.resolvingSymlinksInPath() == dmg.resolvingSymlinksInPath())

        #expect(await DiskImages.detach(mountPoint: mount))
        #expect(!FileManager.default.fileExists(atPath: mount.path))
        let after = await DiskImages.mounted()
        #expect(!after.contains { $0.imageURL.resolvingSymlinksInPath() == dmg.resolvingSymlinksInPath() })
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "hdiutil", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed"])
        }
    }
}
#endif
