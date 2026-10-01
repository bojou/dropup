import Foundation

/// SFTP upload over SSH.
///
/// Not implemented yet. The plan (see docs/ARCHITECTURE.md) is to use a pure-Swift SSH/SFTP
/// client (Citadel, built on SwiftNIO SSH) rather than shelling out to `/usr/bin/sftp`,
/// which cannot take a password non-interactively and would not give byte-level progress.
public struct SFTPUploader: Uploader {
    public init() {}

    public func upload(
        _ request: UploadRequest,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws {
        throw UploaderError.notImplemented(.sftp)
    }
}
