import Foundation

/// A parsed reply from an FTP server's control connection (RFC 959 §4.2).
public struct FTPReply: Equatable, Sendable {
    public var code: Int
    public var lines: [String]

    public var message: String { lines.joined(separator: "\n") }

    public var isPositivePreliminary: Bool { (100..<200).contains(code) }
    public var isPositiveCompletion: Bool { (200..<300).contains(code) }
    public var isPositiveIntermediate: Bool { (300..<400).contains(code) }
    public var isNegative: Bool { code >= 400 }
}

/// Incrementally parses control-connection text into replies.
/// Feed it whatever bytes arrive; it returns the replies that are complete so far.
public struct FTPReplyParser: Sendable {
    private var buffer: [UInt8] = []
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    public init() {}

    public mutating func feed(_ text: String) -> [FTPReply] {
        feed(Array(text.utf8))
    }

    public mutating func feed(_ bytes: [UInt8]) -> [FTPReply] {
        buffer += bytes
        var replies: [FTPReply] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineBytes = buffer[buffer.startIndex..<newline]
            if lineBytes.last == UInt8(ascii: "\r") {
                lineBytes = lineBytes.dropLast()
            }
            buffer.removeSubrange(buffer.startIndex...newline)
            if let reply = consume(String(decoding: lineBytes, as: UTF8.self)) {
                replies.append(reply)
            }
        }
        return replies
    }

    private mutating func consume(_ line: String) -> FTPReply? {
        let code = Self.leadingCode(line)
        let separator = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
        let text = line.count > 4 ? String(line.dropFirst(4)) : ""

        if let open = pendingCode {
            // Inside a multi-line reply: it ends at "<same code><space>".
            if code == open, separator == " " {
                let reply = FTPReply(code: open, lines: pendingLines + [text])
                pendingCode = nil
                pendingLines = []
                return reply
            }
            pendingLines.append(code == open ? text : line)
            return nil
        }

        guard let code else { return nil }
        if separator == "-" {
            pendingCode = code
            pendingLines = [text]
            return nil
        }
        return FTPReply(code: code, lines: [text])
    }

    private static func leadingCode(_ line: String) -> Int? {
        let digits = line.prefix(3)
        guard digits.count == 3, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

/// Where to open the data connection for a transfer.
public struct FTPPassiveEndpoint: Equatable, Sendable {
    /// `nil` means "same host as the control connection" (EPSV, or a PASV reply we chose to ignore).
    public var host: String?
    public var port: Int
}

public enum FTPPassiveParser {
    /// Parses `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`.
    public static func parsePASV(_ reply: FTPReply) -> FTPPassiveEndpoint? {
        guard reply.code == 227 else { return nil }
        let numbers = reply.message
            .split(whereSeparator: { !$0.isNumber && $0 != "," })
            .last(where: { $0.filter { $0 == "," }.count == 5 })?
            .split(separator: ",")
            .compactMap { Int($0) }
        guard let numbers, numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let host = numbers[0..<4].map(String.init).joined(separator: ".")
        return FTPPassiveEndpoint(host: host, port: numbers[4] * 256 + numbers[5])
    }

    /// Parses `229 Entering Extended Passive Mode (|||6446|)` (RFC 2428).
    public static func parseEPSV(_ reply: FTPReply) -> FTPPassiveEndpoint? {
        guard reply.code == 229,
              let open = reply.message.firstIndex(of: "("),
              let close = reply.message.lastIndex(of: ")"),
              open < close
        else { return nil }
        let inner = reply.message[reply.message.index(after: open)..<close]
        guard let delimiter = inner.first else { return nil }
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        // "|||6446|" splits into ["", "", "", "6446", ""].
        guard fields.count == 5, let port = Int(fields[3]), (1...65535).contains(port) else { return nil }
        return FTPPassiveEndpoint(host: nil, port: port)
    }
}
