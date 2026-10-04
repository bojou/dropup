import Foundation

/// Where an image or some text from the clipboard waits as a file until it has been uploaded. The upload needs a real
/// file, and it can be resumed later, so the file stays until nothing in the list needs it any more.
public struct ClipboardStaging: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The staging folder in the user's caches.
    public static func standard() -> ClipboardStaging {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ClipboardStaging(root: caches.appendingPathComponent("app.dropup.DropUp", isDirectory: true).appendingPathComponent("Clipboard", isDirectory: true))
    }

    /// Writes `data` as a file called `name`. Each file gets a folder of its own, so two with the same name never meet.
    public func write(name: String, data: Data) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Deletes every staged file that is not in `keeping`, and returns how many are left. Run whenever the list
    /// changes, and once at launch with what the saved rows refer to.
    @discardableResult
    public func sweep(keeping: Set<URL>) -> Int {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
        let kept = Set(keeping.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var remaining = 0
        for folder in folders {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let inUse = files.contains { kept.contains($0.standardizedFileURL.resolvingSymlinksInPath().path) }
            if inUse {
                remaining += 1
            } else {
                try? fileManager.removeItem(at: folder)
            }
        }
        return remaining
    }
}
