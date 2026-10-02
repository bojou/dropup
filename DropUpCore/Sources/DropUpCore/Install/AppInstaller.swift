import Foundation

public enum AppInstallError: Error, Equatable, Sendable {
    /// There is no folder to install into.
    case noApplicationsFolder
}

extension AppInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noApplicationsFolder: "There is no Applications folder DropUp can write to."
        }
    }
}

/// Copies the app out of the disk image into Applications. File work only; the app decides when to ask.
public enum AppInstaller {
    /// Where `appName` should go: the first folder that exists and can be written to, creating the
    /// last one (the user's own `~/Applications`) if that is all there is.
    public static func destination(
        appName: String,
        in folders: [URL],
        fileManager: FileManager = .default
    ) throws -> URL {
        for folder in folders {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
               isDirectory.boolValue, fileManager.isWritableFile(atPath: folder.path) {
                return folder.appendingPathComponent(appName, isDirectory: true)
            }
        }
        if let last = folders.last {
            do {
                try fileManager.createDirectory(at: last, withIntermediateDirectories: true)
                return last.appendingPathComponent(appName, isDirectory: true)
            } catch {
                throw AppInstallError.noApplicationsFolder
            }
        }
        throw AppInstallError.noApplicationsFolder
    }

    /// Puts a copy of `source` at `destination`. The copy is made next to the destination first, so a
    /// failure half way leaves whatever was installed before untouched. Anything already at the
    /// destination is handed to `discardExisting` (the app moves it to the Trash).
    public static func install(
        source: URL,
        destination: URL,
        discardExisting: (URL) throws -> Void,
        fileManager: FileManager = .default
    ) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).installing-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: source, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                try discardExisting(destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}
