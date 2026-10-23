import XCTest
@testable import 记忆花园

/// #045 T2：小电脑交互 shell 的起始命令 / 环境 / 令牌 / 写泵（plan-terminal-t2 §2.4）。
final class LocalShellLaunchTests: XCTestCase {

    func testArgumentsCdThenLoginShell() {
        XCTAssertEqual(LocalShellLaunch.arguments(startDirectory: "/mnt/library/abc"),
                       ["/bin/sh", "-c", "cd '/mnt/library/abc' 2>/dev/null || cd /root; exec /bin/sh -l"])
    }

    func testSingleQuoteEscaping() {
        XCTAssertEqual(LocalShellLaunch.singleQuoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(LocalShellLaunch.arguments(startDirectory: "/x'y")[2],
                       "cd '/x'\\''y' 2>/dev/null || cd /root; exec /bin/sh -l")
    }

    func testEnvironmentIsTerminalFlavoredAndKeepsWhitelist() {
        let base = ["PATH": "/bin", "HOME": "/root", "TERM": "dumb", "NO_COLOR": "1", "LANG": "C.UTF-8"]
        let env = LocalShellLaunch.environment(base: base)
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertNil(env["NO_COLOR"])
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertEqual(env["HOME"], "/root")
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "TERM", "LANG"])
    }

    func testTokensAreNamespacedAndDistinct() {
        let a = LocalShellLaunch.token(sequence: 1)
        let b = LocalShellLaunch.token(sequence: 2)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(LocalShellLaunch.isToken(a))
        XCTAssertFalse(LocalShellLaunch.isToken(0))
        XCTAssertFalse(LocalShellLaunch.isToken(42))
    }

    func testBannerIsDimAndCarriesNote() {
        let plain = String(decoding: LocalShellLaunch.banner(note: nil), as: UTF8.self)
        XCTAssertTrue(plain.hasPrefix("\u{1b}[2m手机里的小电脑"))
        XCTAssertTrue(plain.hasSuffix("\u{1b}[0m\r\n"))
        let noted = String(decoding: LocalShellLaunch.banner(note: "这个楼层开了 iCloud"), as: UTF8.self)
        XCTAssertTrue(noted.contains("这个楼层开了 iCloud"))
        XCTAssertEqual(noted.components(separatedBy: "\r\n").count, 3)
    }

    // MARK: 写泵

    private func drain(_ data: Data, accept: @escaping (Int) -> Int, cancelAfter: Int = .max) -> (TerminalInputPump.Outcome, Data, Int) {
        var written = Data()
        var calls = 0
        var pauses = 0
        let outcome = TerminalInputPump.drain(data, again: -11, write: { buf in
            calls += 1
            let n = accept(buf.count)
            if n > 0 { written.append(contentsOf: buf.prefix(n)) }
            return n
        }, isCancelled: { calls >= cancelAfter }, pause: { pauses += 1 })
        return (outcome, written, pauses)
    }

    func testDrainWritesAllInOrderAcrossPartialWrites() {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        var turn = 0
        let (outcome, written, _) = drain(data, accept: { remaining in
            turn += 1
            if turn % 3 == 0 { return 0 }          // 满了
            if turn % 5 == 0 { return -11 }        // EAGAIN 也算满了
            return min(remaining, 700)
        })
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(written, data)
    }

    func testDrainGivesUpAfterStallsAndReportsRemaining() {
        var first = true
        let (outcome, written, pauses) = drain(Data(repeating: 1, count: 100), accept: { _ in
            if first { first = false; return 40 }
            return 0
        })
        XCTAssertEqual(outcome, .gaveUp(remaining: 60))
        XCTAssertEqual(written.count, 40)
        XCTAssertEqual(pauses, TerminalInputPump.maxStalls - 1)
    }

    func testDrainStopsOnHardError() {
        let (outcome, _, _) = drain(Data(repeating: 1, count: 10), accept: { _ in -5 })
        XCTAssertEqual(outcome, .failed(code: -5))
    }

    func testDrainHonorsCancel() {
        let (outcome, written, _) = drain(Data(repeating: 1, count: 100), accept: { _ in 10 }, cancelAfter: 3)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(written.count, 30)
    }

    func testPhoneEngineIsCellOne() {
        XCTAssertEqual(TerminalEngine.phone.cell, .phone)
        XCTAssertEqual(TerminalEngine.claude.cell, .agent)
        XCTAssertEqual(TerminalEngine.shell.cell, .computer)
    }
}
