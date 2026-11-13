import XCTest
@testable import memoryd

final class HTTPRequestParserTests: XCTestCase {
    func testParsesGetRequest() throws {
        var parser = HTTPRequestParser()
        let request = try parser.append(Data("GET /api/bench/sets HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: application/json\r\n\r\n".utf8))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.target, "/api/bench/sets")
        XCTAssertEqual(request?.version, "HTTP/1.1")
        XCTAssertEqual(request?.headers["host"], "127.0.0.1")
        XCTAssertEqual(request?.body.count, 0)
    }

    func testWaitsForFixedLengthBodyAcrossChunks() throws {
        var parser = HTTPRequestParser()
        let body = #"{"setId": "wiki-probe"}"#
        let head = Data("POST /api/bench/run HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n".utf8)
        XCTAssertNil(try parser.append(head))
        let partial = Data(#"{"setId": "wiki-"#.utf8)
        XCTAssertNil(try parser.append(partial))
        let request = try parser.append(Data(#"probe"}"#.utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(String(decoding: request?.body ?? Data(), as: UTF8.self), body)
    }

    func testOnlyTakesOneRequestPerConnection() throws {
        var parser = HTTPRequestParser()
        let first = try parser.append(Data("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(first?.target, "/a")
    }

    func testRejectsMalformedStartLine() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("nonsense\r\n\r\n".utf8)))
    }

    func testRejectsUnsupportedVersion() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("GET / HTTP/2.0\r\n\r\n".utf8)))
    }

    func testRejectsBadContentLength() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .badContentLength)
        }
    }

    func testRejectsSignedContentLength() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("POST / HTTP/1.1\r\nContent-Length: +22\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .badContentLength)
        }
    }

    func testRejectsConflictingDuplicateContentLength() {
        var parser = HTTPRequestParser()
        let head = "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 22\r\n\r\n"
        XCTAssertThrowsError(try parser.append(Data(head.utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .conflictingHeader("content-length"))
        }
    }

    func testAcceptsRepeatedIdenticalContentLength() throws {
        var parser = HTTPRequestParser()
        let request = try parser.append(Data("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}".utf8))
        XCTAssertEqual(request?.body.count, 2)
    }

    func testRejectsChunkedBody() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .unsupportedTransferEncoding)
        }
    }

    func testRejectsOversizedHeader() {
        var parser = HTTPRequestParser()
        let big = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes) + "\r\n"
        XCTAssertThrowsError(try parser.append(Data(big.utf8)))
    }

    func testAcceptsBareLineFeedHeaders() throws {
        var parser = HTTPRequestParser()
        let request = try parser.append(Data("GET /x HTTP/1.1\nHost: a\n\n".utf8))
        XCTAssertEqual(request?.target, "/x")
    }
}

final class RoutePathTests: XCTestCase {
    func testStripsQuery() {
        XCTAssertEqual(RoutePath.normalized("/api/bench/sets?x=1"), "/api/bench/sets")
    }

    func testPercentDecodes() {
        XCTAssertEqual(RoutePath.normalized("/api/wiki/page/%E5%9C%B0%E7%82%B9/%E4%BA%91%E6%A1%A5%E5%9F%8E"),
                       "/api/wiki/page/地点/云桥城")
    }

    func testRejectsTraversal() {
        XCTAssertNil(RoutePath.normalized("/api/wiki/page/../../etc/passwd"))
        XCTAssertNil(RoutePath.normalized("/api/wiki/page/%2e%2e/secret"))
        XCTAssertNil(RoutePath.normalized("/api/wiki/page/..%2Fsecret"))
    }

    func testRejectsBackslashAndRelative() {
        XCTAssertNil(RoutePath.normalized("api/wiki/index"))
        XCTAssertNil(RoutePath.normalized("/api\\wiki"))
    }

    func testRootStaysRoot() {
        XCTAssertEqual(RoutePath.normalized("/"), "/")
        XCTAssertEqual(RoutePath.segments("/").count, 0)
    }
}

final class MemorydOptionsTests: XCTestCase {
    func testParsesDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
        let options = try MemorydOptions.parse(["memoryd", "--floor", dir.path])
        XCTAssertEqual(options.port, 8765)
        XCTAssertEqual(options.profileId, dir.lastPathComponent, "默认从目录名推")
        XCTAssertEqual(options.floor.standardizedFileURL, dir.standardizedFileURL)
    }

    func testParsesPortAndProfile() throws {
        let dir = FileManager.default.temporaryDirectory
        let options = try MemorydOptions.parse(["memoryd", "--floor", dir.path, "--port", "9001", "--profile-id", "xingyan"])
        XCTAssertEqual(options.port, 9001)
        XCTAssertEqual(options.profileId, "xingyan")
    }

    func testMissingFloor() {
        XCTAssertThrowsError(try MemorydOptions.parse(["memoryd"]))
    }

    func testFloorNamedMemoryUsesParentName() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("星砚楼-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let floor = parent.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: floor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let options = try MemorydOptions.parse(["memoryd", "--floor", floor.path])
        XCTAssertEqual(options.profileId, parent.lastPathComponent)
    }

    func testHelpThrowsHelp() {
        XCTAssertThrowsError(try MemorydOptions.parse(["memoryd", "--help"])) { error in
            XCTAssertEqual(error as? MemorydOptions.ParseError, .help)
        }
    }

    func testBadPort() {
        XCTAssertThrowsError(try MemorydOptions.parse(["memoryd", "--floor", FileManager.default.temporaryDirectory.path, "--port", "abc"]))
    }
}
