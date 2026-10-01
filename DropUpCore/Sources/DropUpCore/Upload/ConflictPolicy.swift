import Foundation

/// What to do when the upload folder already has a file with the dropped file's name.
public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
    /// Upload as `name-1.ext`, `name-2.ext`, … so nothing is overwritten.
    case keepBoth
    /// Overwrite the existing file.
    case replace
}

public enum RemoteFileName {
    /// The `index`th alternative for a file name: `photo.png` → `photo-1.png`, `archive.tar.gz` → `archive-1.tar.gz`,
    /// `.env` → `.env-1`, `README` → `README-1`.
    public static func numbered(_ fileName: String, index: Int) -> String {
        let (stem, ext) = split(fileName)
        return "\(stem)-\(index)\(ext)"
    }

    /// Splits off the extension, keeping common double extensions together and leaving dotfiles whole.
    static func split(_ fileName: String) -> (stem: String, ext: String) {
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] where fileName.lowercased().hasSuffix(double) && fileName.count > double.count {
            return (String(fileName.dropLast(double.count)), String(fileName.suffix(double.count)))
        }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, "")
        }
        return (String(fileName[..<dot]), String(fileName[dot...]))
    }

    /// Finds the remote path to upload to under `policy`, asking `session` which names are taken.
    public static func resolve(
        fileName: String,
        in config: ServerConfig,
        policy: ConflictPolicy,
        session: any ServerSession,
        maxAttempts: Int = 1000
    ) async throws -> String {
        let first = config.remotePath(forFileNamed: fileName)
        guard policy == .keepBoth else { return first }
        let firstTaken = try await session.fileExists(atPath: first)
        guard firstTaken else { return first }
        for index in 1...maxAttempts {
            let candidate = config.remotePath(forFileNamed: numbered(fileName, index: index))
            let taken = try await session.fileExists(atPath: candidate)
            if !taken { return candidate }
        }
        throw UploaderError.serverRejected(code: 0, message: "Too many files named \(fileName) already exist.")
    }
}
