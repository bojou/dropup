import Foundation

/// A bidirectional byte stream, such as a TCP connection.
/// Production: `NetworkByteStream` in `DropUpTransport` (Network.framework). Tests: a scripted fake server.
public protocol ByteStream: Sendable {
    func send(_ data: Data) async throws
    /// Returns up to `maxLength` bytes as soon as some arrive. An empty result means the peer closed the stream.
    func receive(maxLength: Int) async throws -> Data
    /// Flushes pending data, sends end-of-stream and closes. Never throws.
    func close() async
}

public protocol ByteStreamOpener: Sendable {
    func open(host: String, port: Int) async throws -> any ByteStream
}

/// Plain FTP (RFC 959): passive mode, binary type.
public struct FTPConnector: ServerConnector {
    private let opener: any ByteStreamOpener
    private let replyTimeout: Double

    public init(opener: any ByteStreamOpener, replyTimeout: Double = 30) {
        self.opener = opener
        self.replyTimeout = replyTimeout
    }

    public func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        let control = try await opener.open(host: config.host, port: config.port)
        let session = FTPSession(control: control, opener: opener, host: config.host, replyTimeout: replyTimeout)
        do {
            try await session.login(username: config.username, password: password)
        } catch {
            await session.close()
            throw error
        }
        return session
    }
}

public actor FTPSession: ServerSession {
    private let control: any ByteStream
    private let opener: any ByteStreamOpener
    private let host: String
    private let replyTimeout: Double
    private var parser = FTPReplyParser()
    private var pendingReplies: [FTPReply] = []
    private var epsvUnsupported = false
    private var isClosed = false

    private static let chunkSize = 256 * 1024

    init(control: any ByteStream, opener: any ByteStreamOpener, host: String, replyTimeout: Double) {
        self.control = control
        self.opener = opener
        self.host = host
        self.replyTimeout = replyTimeout
    }

    func login(username: String, password: String) async throws {
        try Self.validate(username)
        try Self.validate(password)
        var greeting = try await readReply()
        while greeting.code == 120 {
            greeting = try await readReply()
        }
        guard greeting.code == 220 else { throw Self.rejected(greeting) }

        let user = try await command("USER \(username)")
        if user.code == 331 || user.code == 332 {
            let pass = try await command("PASS \(password)")
            guard pass.isPositiveCompletion else {
                throw pass.code == 530 ? UploaderError.authenticationFailed : Self.rejected(pass)
            }
        } else if !user.isPositiveCompletion {
            throw user.code == 530 ? UploaderError.authenticationFailed : Self.rejected(user)
        }

        // Ask for UTF-8 file names. Servers that don't know the option reply 5xx, which is fine.
        _ = try await command("OPTS UTF8 ON")
        let type = try await command("TYPE I")
        guard type.isPositiveCompletion else { throw Self.rejected(type) }
    }

    // MARK: ServerSession

    public func fileExists(atPath path: String) async throws -> Bool {
        try Self.validate(path)
        let size = try await command("SIZE \(path)")
        switch size.code {
        case 213: return true
        case 550: return false
        case 500, 501, 502, 504:
            // SIZE is an extension (RFC 3659). Fall back to MDTM, which older servers often have.
            let mdtm = try await command("MDTM \(path)")
            return mdtm.code == 213
        default:
            throw Self.rejected(size)
        }
    }

    public func fileSize(atPath path: String) async throws -> Int64? {
        try Self.validate(path)
        let size = try await command("SIZE \(path)")
        switch size.code {
        case 213:
            guard let bytes = Int64(size.message.trimmingCharacters(in: .whitespaces)) else { throw UploaderError.cannotResume }
            return bytes
        case 550:
            return nil
        case 500, 501, 502, 504:
            // Without SIZE (RFC 3659) there is no telling how much of a file has arrived.
            throw UploaderError.cannotResume
        default:
            throw Self.rejected(size)
        }
    }

    public func listDirectories(atPath path: String) async throws -> [String] {
        let listing = try await fetchListing(atPath: path)
        return listing.machineReadable ? FTPListing.directoriesFromMLSD(listing.text) : FTPListing.directoriesFromLIST(listing.text)
    }

    public func listEntries(atPath path: String) async throws -> [RemoteEntry] {
        let listing = try await fetchListing(atPath: path)
        let entries = listing.machineReadable ? FTPListing.entriesFromMLSD(listing.text) : FTPListing.entriesFromLIST(listing.text)
        return RemoteEntry.sorted(entries)
    }

    /// `listEntries`, then a second look with `LIST`, whose Unix-style lines mark links plainly even where `MLSD` follows them.
    /// A server whose `LIST` can't be read, or that refuses it, just keeps the first answer.
    public func listEntriesWithLinks(atPath path: String) async throws -> [RemoteEntry] {
        let entries = try await listEntries(atPath: path)
        guard let listing = try? await fetchListing(atPath: path, forceLIST: true), !listing.machineReadable else { return entries }
        let links = Set(FTPListing.entriesFromLIST(listing.text).filter { $0.kind == .link }.map(\.name))
        guard !links.isEmpty else { return entries }
        return entries.map { entry in
            var entry = entry
            if links.contains(entry.name) { entry.kind = .link }
            return entry
        }
    }

    /// Asks for a folder listing: `MLSD`, or `LIST` on servers without it (or when `forceLIST` is set).
    private func fetchListing(atPath path: String, forceLIST: Bool = false) async throws -> (text: String, machineReadable: Bool) {
        try Self.validate(path)
        var data = try await openDataStream()
        var reply = try await command(forceLIST ? "LIST \(path)" : "MLSD \(path)")
        var machineReadable = !forceLIST
        if !forceLIST, [500, 501, 502, 504].contains(reply.code) {
            // No MLSD (RFC 3659): fall back to LIST and parse Unix-style `ls -l` lines.
            await data.close()
            data = try await openDataStream()
            reply = try await command("LIST \(path)")
            machineReadable = false
        }
        guard reply.code == 150 || reply.code == 125 else {
            await data.close()
            throw Self.rejected(reply)
        }
        var bytes = Data()
        do {
            while true {
                let chunk = try await data.receive(maxLength: 64 * 1024)
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
        } catch {
            await data.close()
            throw error
        }
        await data.close()
        let done = try await readReply()
        guard done.isPositiveCompletion else { throw Self.rejected(done) }
        return (String(decoding: bytes, as: UTF8.self), machineReadable)
    }

    public func upload(
        fileURL: URL,
        to remotePath: String,
        startingAt offset: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try Self.validate(remotePath)
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        if offset > 0 { try file.seek(toOffset: UInt64(offset)) }

        let data = try await openDataStream()
        if offset > 0 {
            // REST names where in the file the next STOR starts writing. 350 says the server will.
            let rest = try await command("REST \(offset)")
            guard rest.isPositiveIntermediate else {
                await data.close()
                throw UploaderError.cannotResume
            }
        }
        let stor = try await command("STOR \(remotePath)")
        guard stor.code == 150 || stor.code == 125 else {
            await data.close()
            throw Self.rejected(stor)
        }

        progress(offset)
        var sent = offset
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                try await data.send(chunk)
                sent += Int64(chunk.count)
                progress(sent)
            }
        } catch {
            await data.close()
            throw error
        }
        // Closing the data connection is what tells the server the file is complete.
        await data.close()
        let done = try await readReply(timeout: max(replyTimeout, 120))
        guard done.isPositiveCompletion else { throw Self.rejected(done) }
    }

    public func download(
        remotePath: String,
        to fileURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try Self.validate(remotePath)
        let data = try await openDataStream()
        let retr = try await command("RETR \(remotePath)")
        guard retr.code == 150 || retr.code == 125 else {
            await data.close()
            throw Self.rejected(retr)
        }

        var received: Int64 = 0
        do {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
            let file = try FileHandle(forWritingTo: fileURL)
            defer { try? file.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try await data.receive(maxLength: Self.chunkSize)
                if chunk.isEmpty { break }
                try file.write(contentsOf: chunk)
                received += Int64(chunk.count)
                progress(received)
            }
        } catch {
            await data.close()
            throw error
        }
        await data.close()
        let done = try await readReply(timeout: max(replyTimeout, 120))
        guard done.isPositiveCompletion else { throw Self.rejected(done) }
    }

    public func deleteFile(atPath remotePath: String) async throws {
        try Self.validate(remotePath)
        let reply = try await command("DELE \(remotePath)")
        guard reply.isPositiveCompletion else { throw Self.rejected(reply) }
    }

    public func makeDirectory(atPath path: String) async throws {
        try Self.validate(path)
        let reply = try await command("MKD \(path)")
        guard reply.isPositiveCompletion else { throw Self.rejected(reply) }
    }

    public func removeDirectory(atPath path: String) async throws {
        try Self.validate(path)
        let reply = try await command("RMD \(path)")
        guard reply.isPositiveCompletion else { throw Self.rejected(reply) }
    }

    public func rename(from oldPath: String, to newPath: String) async throws {
        try Self.validate(oldPath)
        try Self.validate(newPath)
        // RNFR names the item (350: waiting for the new name), RNTO then does the move.
        let from = try await command("RNFR \(oldPath)")
        guard from.isPositiveIntermediate else { throw Self.rejected(from) }
        let to = try await command("RNTO \(newPath)")
        guard to.isPositiveCompletion else { throw Self.rejected(to) }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        _ = try? await withTimeout(seconds: 3) { [control] in
            try await control.send(Data("QUIT\r\n".utf8))
        }
        await control.close()
    }

    // MARK: Control connection

    private func command(_ line: String) async throws -> FTPReply {
        try await control.send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    private func readReply(timeout: Double? = nil) async throws -> FTPReply {
        while pendingReplies.isEmpty {
            let control = self.control
            let data = try await withTimeout(seconds: timeout ?? replyTimeout) {
                try await control.receive(maxLength: 8 * 1024)
            }
            if data.isEmpty {
                throw UploaderError.connectionFailed("The server closed the connection.")
            }
            pendingReplies += parser.feed(Array(data))
        }
        return pendingReplies.removeFirst()
    }

    /// Enters passive mode and connects the data channel. Prefers EPSV (works over IPv6 and NAT),
    /// falling back to PASV.
    private func openDataStream() async throws -> any ByteStream {
        var endpoint: FTPPassiveEndpoint?
        if !epsvUnsupported {
            let epsv = try await command("EPSV")
            endpoint = FTPPassiveParser.parseEPSV(epsv)
            if endpoint == nil { epsvUnsupported = true }
        }
        if endpoint == nil {
            let pasv = try await command("PASV")
            endpoint = FTPPassiveParser.parsePASV(pasv)
            if endpoint == nil { throw Self.rejected(pasv) }
        }
        guard let endpoint else { throw UploaderError.connectionFailed("No passive mode.") }
        // Always reuse the control connection's host. Servers behind NAT often advertise
        // a private address in PASV replies that the client can't reach.
        return try await opener.open(host: host, port: endpoint.port)
    }

    /// Rejects values that would let a file name inject extra FTP commands.
    private static func validate(_ value: String) throws {
        // Check scalars, not Characters: "\r\n" is a single Character that equals neither "\r" nor "\n".
        if value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw UploaderError.invalidRemotePath
        }
    }

    private static func rejected(_ reply: FTPReply) -> UploaderError {
        .serverRejected(code: reply.code, message: reply.message.trimmingCharacters(in: .whitespaces))
    }
}

/// Parses directory listings from the data connection.
public enum FTPListing {
    /// `type=dir;modify=20260101000000; images` lines (RFC 3659 MLSD).
    public static func directoriesFromMLSD(_ text: String) -> [String] {
        let names = lines(text).compactMap { line -> String? in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let facts = line[..<space].lowercased().split(separator: ";")
            guard facts.contains("type=dir") else { return nil }
            return String(line[line.index(after: space)...])
        }
        return clean(names)
    }

    /// Unix `ls -l` style lines: `drwxr-xr-x  2 user group 4096 Sep 10 12:00 images`.
    public static func directoriesFromLIST(_ text: String) -> [String] {
        let names = lines(text).compactMap { line -> String? in
            guard line.first == "d" else { return nil }
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9 else { return nil }
            return String(fields[8])
        }
        return clean(names)
    }

    /// Every entry of an MLSD listing: folders, files and symbolic links, with size and modified time when given.
    public static func entriesFromMLSD(_ text: String) -> [RemoteEntry] {
        lines(text).compactMap { line -> RemoteEntry? in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[line.index(after: space)...])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                guard let equals = fact.firstIndex(of: "=") else { continue }
                facts[fact[..<equals].lowercased()] = String(fact[fact.index(after: equals)...])
            }
            let kind: RemoteEntry.Kind
            switch facts["type"]?.lowercased() {
            case "file": kind = .file
            case "dir": kind = .folder
            case let type? where type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink"): kind = .link
            default: return nil
            }
            return RemoteEntry(
                name: name,
                kind: kind,
                size: kind == .folder ? nil : facts["size"].flatMap { Int64($0) },
                modified: facts["modify"].flatMap(mlsdDate)
            )
        }
    }

    /// Every entry of a Unix `ls -l` style listing. Times in these listings carry no time zone, so they are read as UTC.
    public static func entriesFromLIST(_ text: String, now: Date = Date()) -> [RemoteEntry] {
        lines(text).compactMap { line -> RemoteEntry? in
            guard let type = line.first, "d-l".contains(type) else { return nil }
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9 else { return nil }
            var name = String(fields[8])
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            let kind: RemoteEntry.Kind = type == "d" ? .folder : (type == "l" ? .link : .file)
            return RemoteEntry(
                name: name,
                kind: kind,
                size: kind == .folder ? nil : Int64(fields[4]),
                modified: listDate(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now)
            )
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// `20260101120000` or `20260101120000.123`, always UTC.
    private static func mlsdDate(_ value: String) -> Date? {
        let digits = value.prefix { $0 != "." }
        guard digits.count == 14, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        let numbers = digits.map { Int(String($0))! }
        func number(_ range: Range<Int>) -> Int { numbers[range].reduce(0) { $0 * 10 + $1 } }
        return utc.date(from: DateComponents(
            year: number(0..<4), month: number(4..<6), day: number(6..<8),
            hour: number(8..<10), minute: number(10..<12), second: number(12..<14)
        ))
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `Sep 10 12:00` (this year, or last year if that would be in the future) or `Sep 10 2025`.
    private static func listDate(month: Substring, day: Substring, timeOrYear: Substring, now: Date) -> Date? {
        guard let monthIndex = months.firstIndex(of: month.lowercased()), let day = Int(day) else { return nil }
        var components = DateComponents(month: monthIndex + 1, day: day)
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            components.hour = parts[0]
            components.minute = parts[1]
            components.year = utc.component(.year, from: now)
            if let date = utc.date(from: components), date > now.addingTimeInterval(24 * 3600) {
                components.year = (components.year ?? 0) - 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return utc.date(from: components)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
    }

    /// Drops `.`, `..` and hidden folders, then sorts like Finder.
    private static func clean(_ names: [String]) -> [String] {
        names
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
