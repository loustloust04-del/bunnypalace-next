#if os(macOS)
import XCTest
@testable import 记忆花园

/// 正文链接（N4-d3）：照抄 Wake `markdown_links.rs` 的 resolve_link 单测（本地文件 / 编码 / 行号 / 字面文件名优先 / 远程不碰本机 /
/// 无效路径不当外链 / 外链与锚点）
final class CodingLinkResolverTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func canonical(_ url: URL) -> String {
        url.standardized.resolvingSymlinksInPath().path
    }

    private func assertFile(_ target: CodingLinkResolver.Target, _ expected: URL, _ href: String, line: UInt = #line) {
        guard case .file(let path) = target else { return XCTFail("\(href): \(target)", line: line) }
        XCTAssertEqual(canonical(path), canonical(expected), href, line: line)
    }

    /// 文件 URL 的百分号编码 path（Rust `Url::path()`）
    private func encodedPath(_ url: URL) -> String {
        String(URL(fileURLWithPath: url.path).absoluteString.dropFirst("file://".count))
    }

    private func resolve(_ href: String, _ project: String, home: URL? = nil) -> CodingLinkResolver.Target {
        CodingLinkResolver.resolve(href, remote: false, projectPath: project) { home }
    }

    func testLocalFilesDirectoriesAndEncodedLinks() throws {
        let project = temp.appendingPathComponent("OpenSurge for Mac")
        let file = project.appendingPathComponent("internal/controlapi/mihomo_recovery.go")
        try touch(file)
        for href in [
            file.path,
            file.path.replacingOccurrences(of: " ", with: "%20"),
            URL(fileURLWithPath: file.path).absoluteString,
            "file:\(encodedPath(file))",
            "FILE://localhost\(encodedPath(file))",
            "internal/controlapi/mihomo_recovery.go",
            "./internal/controlapi/mihomo_recovery.go",
            "../OpenSurge for Mac/internal/controlapi/mihomo_recovery.go",
            "~/OpenSurge for Mac/internal/controlapi/mihomo_recovery.go",
        ] {
            assertFile(resolve(href, project.path, home: temp), file, href)
        }
        assertFile(resolve(project.path, ""), project, project.path)
    }

    func testLineNumberLinksResolveToExistingFiles() throws {
        let project = temp.appendingPathComponent("Wake with spaces")
        for (name, line) in [("markdown_links.rs", 11), ("workbench.rs", 7955)] {
            let file = project.appendingPathComponent("src").appendingPathComponent(name)
            try touch(file)
            for href in [
                "\(file.path):\(line)",
                "\(file.path.replacingOccurrences(of: " ", with: "%20")):\(line)",
                "\(URL(fileURLWithPath: file.path).absoluteString):\(line)",
                "src/\(name):\(line)",
                "./src/\(name):\(line)",
                "~/Wake with spaces/src/\(name):\(line)",
            ] {
                assertFile(resolve(href, project.path, home: temp), file, href)
            }
        }
    }

    func testBareFilenameLineLinksUseTheSessionProject() throws {
        let file = temp.appendingPathComponent("main.rs")
        try touch(file)
        assertFile(resolve("main.rs:11", temp.path), file, "main.rs:11")
        // 真有叫 main.rs:11 的文件时字面优先
        let literal = temp.appendingPathComponent("main.rs:11")
        try touch(literal)
        assertFile(resolve("main.rs:11", temp.path), literal, "main.rs:11 literal")
        XCTAssertEqual(resolve("missing.rs:11", temp.path), .unavailable)
        XCTAssertEqual(resolve("main.rs:11", ""), .unavailable)
    }

    func testLineNumbersPreserveLiteralNamesAndRequireAFile() throws {
        let file = temp.appendingPathComponent("source file.rs")
        let literal = temp.appendingPathComponent("source file.rs:11")
        // 即使去掉行号后两种拼法都存在，完整的解码文件名也优先
        for url in [file, literal, temp.appendingPathComponent("source%20file.rs")] { try touch(url) }
        for href in [literal.path, literal.path.replacingOccurrences(of: " ", with: "%20"), URL(fileURLWithPath: literal.path).absoluteString] {
            assertFile(resolve(href, ""), literal, href)
        }
        for suffix in [":0", ":+11", ":-11", ":line11", "%3A12", ":11#fragment"] {
            for base in [file.path, URL(fileURLWithPath: file.path).absoluteString] {
                XCTAssertEqual(resolve(base + suffix, ""), .unavailable, base + suffix)
            }
        }
        XCTAssertEqual(resolve("\(temp.path):11", ""), .unavailable, "目录带行号不算文件")
    }

    func testFilenamesAreNotReinterpretedOrDecodedTwice() throws {
        for name in ["中文 #1%.md", "literal%20space.md", "literal space.md", "name:42", "name#L42"] {
            let path = temp.appendingPathComponent(name)
            try touch(path)
            for href in [path.path, URL(fileURLWithPath: path.path).absoluteString] {
                assertFile(resolve(href, ""), path, href)
            }
        }
        try touch(temp.appendingPathComponent("once decoded.md"))
        XCTAssertEqual(resolve("once%2520decoded.md", temp.path), .unavailable, "只解码一次")
    }

    func testRemotePathsNeverResolveAgainstThisMac() throws {
        let file = temp.appendingPathComponent("exists.md")
        try touch(file)
        for href in [file.path, "\(file.path):11", "~/exists.md", "~/exists.md:11", "exists.md", "exists.md:11", "./exists.md:11",
                     "file:///tmp/exists.md", "file:///tmp/exists.md:11", "C:/work/a.rs"] {
            let target = CodingLinkResolver.resolve(href, remote: true, projectPath: temp.path) {
                XCTFail("remote path requested local HOME")
                return nil
            }
            XCTAssertEqual(target, .remote, href)
        }
    }

    func testInvalidOrUnavailablePathsNeverBecomeExternalURLs() {
        for href in ["/wake-link-test-missing/a.rs", "/wake-link-test-missing/a.rs:11", "missing.rs", "file:relative.rs",
                     "file://Users/example/a.rs", "file://server/share/a.rs", "file://server/share/a.rs:11", "file:///C:/work/a.rs",
                     "C:/work/a.rs", #"C:\work\a.rs"#, #"\\server\share\a.rs"#, "//server/share/a.rs", "file:///tmp/a.rs?x=1",
                     "file:///tmp/a.rs#L42", "file:///tmp/a%00.rs", "~someone/a.rs"] {
            XCTAssertEqual(resolve(href, temp.path), .unavailable, href)
        }
        // 会话基准缺席时不能拿进程当前目录兜底
        XCTAssertEqual(resolve("Cargo.toml", ""), .unavailable)
        XCTAssertEqual(resolve("Cargo.toml", "."), .unavailable)
    }

    func testExternalSchemesAndAnchorsKeepTheirOwnMeaning() {
        for remote in [false, true] {
            for href in ["https://example.com/a%20b?q=1#x", "http://example.com", "mailto:a@example.com", "vscode://file/tmp/a.rs",
                         "vscode://file/tmp/a.rs:11", "https://example.com/a.rs:11", "custom+app:value", "custom+app:11",
                         "org.example://open/main.rs:11", "x://example.com"] {
                let target = CodingLinkResolver.resolve(href, remote: remote, projectPath: "") {
                    XCTFail("URL requested local HOME")
                    return nil
                }
                XCTAssertEqual(target, .external, href)
            }
            for href in ["", "#section"] {
                XCTAssertEqual(CodingLinkResolver.resolve(href, remote: remote, projectPath: "") { nil }, .ignore, href)
            }
        }
    }
}
#endif
