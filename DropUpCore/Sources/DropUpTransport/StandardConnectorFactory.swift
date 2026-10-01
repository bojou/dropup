import DropUpCore

/// The real transports: FTP over Network.framework and SFTP over Citadel.
public struct StandardConnectorFactory: ConnectorFactory {
    private let ftp: FTPConnector
    private let sftp: SFTPConnector

    public init(hostKeys: any HostKeyStore) {
        #if canImport(Network)
        ftp = FTPConnector(opener: NetworkByteStreamOpener())
        #else
        ftp = FTPConnector(opener: UnavailableByteStreamOpener())
        #endif
        sftp = SFTPConnector(hostKeys: hostKeys)
    }

    public func connector(for transferProtocol: TransferProtocol) -> any ServerConnector {
        switch transferProtocol {
        case .ftp: ftp
        case .sftp: sftp
        }
    }
}

#if !canImport(Network)
/// DropUp is a macOS app; this only exists so the package builds on Linux for tests.
private struct UnavailableByteStreamOpener: ByteStreamOpener {
    func open(host: String, port: Int) async throws -> any ByteStream {
        throw UploaderError.connectionFailed("FTP needs Network.framework.")
    }
}
#endif
