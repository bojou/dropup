import Foundation

/// Plain FTP upload (passive mode, binary type, `STOR`).
///
/// Not implemented yet. The plan (see docs/ARCHITECTURE.md):
/// open the control connection with Network.framework, feed incoming bytes to `FTPReplyParser`,
/// send `USER`/`PASS`/`TYPE I`, try `EPSV` then fall back to `PASV` (`FTPPassiveParser`),
/// open the data connection, send `STOR <path>`, stream the file in chunks while reporting progress,
/// then wait for the `226` completion reply.
public struct FTPUploader: Uploader {
    public init() {}

    public func upload(
        _ request: UploadRequest,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws {
        throw UploaderError.notImplemented(.ftp)
    }
}
