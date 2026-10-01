import Testing
@testable import DropUpCore

struct FTPReplyParserTests {
    @Test func parsesSingleLineReply() {
        var parser = FTPReplyParser()
        #expect(parser.feed("220 Welcome\r\n") == [FTPReply(code: 220, lines: ["Welcome"])])
    }

    @Test func waitsForCompleteLine() {
        var parser = FTPReplyParser()
        #expect(parser.feed("331 Pass").isEmpty)
        #expect(parser.feed("word required\r\n230 Logged in\r\n") == [
            FTPReply(code: 331, lines: ["Password required"]),
            FTPReply(code: 230, lines: ["Logged in"]),
        ])
    }

    @Test func parsesMultiLineReply() {
        var parser = FTPReplyParser()
        let replies = parser.feed("211-Features:\r\n EPSV\r\n UTF8\r\n211 End\r\n")
        #expect(replies == [FTPReply(code: 211, lines: ["Features:", " EPSV", " UTF8", "End"])])
    }

    @Test func multiLineReplyIgnoresOtherCodesInside() {
        var parser = FTPReplyParser()
        let replies = parser.feed("220-Hello\n230 not the end\n220 Ready\n")
        #expect(replies == [FTPReply(code: 220, lines: ["Hello", "230 not the end", "Ready"])])
    }

    @Test func classifiesReplies() {
        #expect(FTPReply(code: 150, lines: []).isPositivePreliminary)
        #expect(FTPReply(code: 226, lines: []).isPositiveCompletion)
        #expect(FTPReply(code: 331, lines: []).isPositiveIntermediate)
        #expect(FTPReply(code: 530, lines: []).isNegative)
    }
}

struct FTPPassiveParserTests {
    @Test func parsesPASV() {
        let reply = FTPReply(code: 227, lines: ["Entering Passive Mode (192,168,1,20,19,137)."])
        #expect(FTPPassiveParser.parsePASV(reply) == FTPPassiveEndpoint(host: "192.168.1.20", port: 19 * 256 + 137))
    }

    @Test func rejectsMalformedPASV() {
        #expect(FTPPassiveParser.parsePASV(FTPReply(code: 227, lines: ["Entering Passive Mode (1,2,3)"])) == nil)
        #expect(FTPPassiveParser.parsePASV(FTPReply(code: 227, lines: ["(300,1,1,1,1,1)"])) == nil)
        #expect(FTPPassiveParser.parsePASV(FTPReply(code: 500, lines: ["(1,2,3,4,5,6)"])) == nil)
    }

    @Test func parsesEPSV() {
        let reply = FTPReply(code: 229, lines: ["Entering Extended Passive Mode (|||6446|)"])
        #expect(FTPPassiveParser.parseEPSV(reply) == FTPPassiveEndpoint(host: nil, port: 6446))
    }

    @Test func rejectsMalformedEPSV() {
        #expect(FTPPassiveParser.parseEPSV(FTPReply(code: 229, lines: ["(|||abc|)"])) == nil)
        #expect(FTPPassiveParser.parseEPSV(FTPReply(code: 229, lines: ["no parens"])) == nil)
    }
}
