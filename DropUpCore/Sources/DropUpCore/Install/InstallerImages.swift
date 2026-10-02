import Foundation

/// A disk image that is currently mounted, as reported by `hdiutil info -plist`.
public struct MountedImage: Equatable, Sendable {
    /// The `.dmg` file the volume was mounted from.
    public let imageURL: URL
    /// Where its volumes appear, such as `/Volumes/DropUp`.
    public let mountPoints: [URL]

    public init(imageURL: URL, mountPoints: [URL]) {
        self.imageURL = imageURL
        self.mountPoints = mountPoints
    }

    public var imageName: String { imageURL.lastPathComponent }

    /// Whether `url` is on one of this image's volumes.
    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return mountPoints.contains { mount in
            let mountPath = mount.standardizedFileURL.resolvingSymlinksInPath().path
            return path == mountPath || path.hasPrefix(mountPath + "/")
        }
    }
}

/// Finds the DropUp installer disk image left mounted after installing, so the app can offer to eject it
/// and move the downloaded `.dmg` to the Trash. Pure logic, so the decisions are unit tested.
public enum InstallerImages {
    /// Parses the output of `hdiutil info -plist`. Images with no mounted volume are left out.
    public static func parse(_ plist: Data) -> [MountedImage] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String, !path.isEmpty else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let mounts = entities
                .compactMap { $0["mount-point"] as? String }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            guard !mounts.isEmpty else { return nil }
            return MountedImage(imageURL: URL(fileURLWithPath: path), mountPoints: mounts)
        }
    }

    /// The mounted DropUp installer to offer to clean up, if there is one.
    ///
    /// It must be named like a DropUp download and hold the app. It is skipped when the running app
    /// lives on that image (not installed yet) and when the user already said "Keep" for it.
    /// - Parameters:
    ///   - dismissed: Paths of images the user chose to keep.
    ///   - holdsApp: Whether a mount point contains `DropUp.app`.
    public static func cleanupCandidate(
        in images: [MountedImage],
        runningAppURL: URL,
        dismissed: Set<String>,
        holdsApp: (URL) -> Bool
    ) -> MountedImage? {
        images.first { image in
            guard image.imageName.lowercased().hasPrefix("dropup"),
                  !dismissed.contains(image.imageURL.path),
                  image.mountPoints.contains(where: holdsApp) else { return false }
            return !image.contains(runningAppURL)
        }
    }

    /// The mounted image that the app at `appURL` is running from, if it is running from one.
    public static func image(holding appURL: URL, in images: [MountedImage]) -> MountedImage? {
        images.first { $0.contains(appURL) }
    }
}

#if os(macOS)
/// Talks to `hdiutil`, the system tool for disk images.
public enum DiskImages {
    /// Every disk image currently mounted. Empty if `hdiutil` can't be run.
    public static func mounted() async -> [MountedImage] {
        await Task.detached {
            guard let output = run(["info", "-plist"]) else { return [] }
            return InstallerImages.parse(output)
        }.value
    }

    /// Ejects the image mounted at `mountPoint`. Tries a normal detach first, then a forced one.
    public static func detach(mountPoint: URL) async -> Bool {
        await Task.detached {
            run(["detach", mountPoint.path]) != nil || run(["detach", "-force", mountPoint.path]) != nil
        }.value
    }

    /// Runs `hdiutil` and returns its output, or nil if it fails.
    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
#endif
