import Foundation
@testable import DropUpCore

/// Records every request and reports scripted progress, or throws a scripted error.
final class FakeUploader: Uploader, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [UploadRequest] = []
    private let error: (any Error)?
    private let progressSteps: [Int64]

    init(error: (any Error)? = nil, progressSteps: [Int64] = [50, 100]) {
        self.error = error
        self.progressSteps = progressSteps
    }

    var requests: [UploadRequest] { lock.withLock { _requests } }

    func upload(_ request: UploadRequest, progress: @escaping @Sendable (UploadProgress) -> Void) async throws {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        let total = progressSteps.last ?? 0
        for sent in progressSteps {
            progress(UploadProgress(bytesSent: sent, totalBytes: total))
        }
    }
}

struct FakeUploaderFactory: UploaderFactory {
    let uploader: FakeUploader
    func uploader(for transferProtocol: TransferProtocol) -> any Uploader { uploader }
}

/// Creates real temp files, because the queue checks that dropped items exist and are readable.
struct TempFiles {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(named name: String, contents: String = "hello") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
