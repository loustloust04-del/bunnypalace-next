#if (DEBUG || PERF_BENCH) && os(macOS)
import XCTest
import AppKit
import SwiftUI
import Darwin
import os
@testable import 记忆花园

final class PerfHarnessMacTests: XCTestCase {
    func testConditionInvalidationRestartsTheWholeQuietWindow() {
        var gate = MacPerfReadyGate(deadline: 10)
        gate.poll(condition: true, at: 1)
        gate.poll(condition: false, at: 1.4)
        gate.poll(condition: true, at: 2)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.499), .waiting)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.5), .ready(2))
    }

    func testRepeatedLongTurnsResetQuietWindowAndReadyTimestamp() {
        var gate = MacPerfReadyGate(deadline: 10)
        gate.poll(condition: true, at: 1)
        gate.closedBusy(start: 1.2, end: 1.3)
        XCTAssertEqual(gate.afterClosedTurn(at: 1.7), .waiting)
        gate.closedBusy(start: 1.7, end: 1.9)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.3), .waiting)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.5), .ready(1.9))
    }

    func testFrameBeforeLongLayoutCannotConfirmReadiness() {
        var gate = MacPerfReadyGate(deadline: 10)
        gate.poll(condition: true, at: 1)
        // The frame observes true, but the same turn then performs a long layout.
        gate.poll(condition: true, at: 1.6)
        gate.closedBusy(start: 1.5, end: 2.1)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.1), .waiting)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.5), .waiting)
        XCTAssertEqual(gate.afterClosedTurn(at: 2.7), .ready(2.1))
    }

    func testShortTurnsDoNotMoveTheBusinessReadyTimestamp() {
        var gate = MacPerfReadyGate(deadline: 10)
        gate.poll(condition: true, at: 1)
        gate.closedBusy(start: 1.1, end: 1.12)
        gate.closedBusy(start: 1.3, end: 1.32)
        XCTAssertEqual(gate.afterClosedTurn(at: 1.5), .ready(1))
    }

    func testAbsoluteDeadlineWinsOverReadyAtTheSameBoundary() {
        var gate = MacPerfReadyGate(deadline: 10)
        gate.poll(condition: true, at: 1)
        XCTAssertEqual(gate.afterClosedTurn(at: 10), .timedOut)
        XCTAssertEqual(gate.afterClosedTurn(at: 11), .timedOut)
    }


    @MainActor func testConfigurationRejectsMissingIdentityInvalidScenariosAndRootEscape() throws {
        let root = "/tmp/mp-macperf-sol/bench-config-\(UUID().uuidString)"
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for child in ["home", "tmp"] {
            try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(child, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        let isolationEnvironment = ["MP_PERF_ROOT": root, "MP_PERF_RUN": "1", "MP_PERF_WINDOW_APPROVED": "1",
                                    "HOME": root + "/home", "CFFIXED_USER_HOME": root + "/home", "TMPDIR": root + "/tmp"]
        let isolation = try BenchIsolation.Configuration(environment: isolationEnvironment, bundleID: BenchIsolation.bundleIdentifier)
        let valid = ["MP_PERF_RUNID": "boundary-1", "MP_PERF_SOURCE_SHA": String(repeating: "a", count: 40)]
        _ = try PerfHarnessMac.Configuration(environment: valid, isolation: isolation)
        for changes in [["MP_PERF_SOURCE_SHA": ""], ["MP_PERF_SOURCE_SHA": String(repeating: "g", count: 40)],
                        ["MP_PERF_RUNID": "../outside"], ["MP_PERF_SCENARIOS": "M1,M1"],
                        ["MP_PERF_SCENARIOS": "M0"], ["MP_PERF_SCENARIOS": ""],
                        ["MP_PERF_FIXTURE": "/tmp/outside-fixture.json"], ["MP_PERF_LEVEL": "fake"]] {
            XCTAssertThrowsError(try PerfHarnessMac.Configuration(environment: valid.merging(changes) { _, new in new }, isolation: isolation))
        }
        XCTAssertThrowsError(try PerfHarnessMac.Configuration(environment: [:], isolation: isolation))
    }

    func testResourceRatesUseActualEndpointDurationAndRejectCounterRegression() {
        let before = MacPerfResource(at: 1, userCPUSeconds: 2, systemCPUSeconds: 1,
            logicalWriteBytes: 10, diskReadBytes: 20, diskWriteBytes: 30,
            footprintBytes: 100, lifetimeMaxFootprintBytes: 200)
        let after = MacPerfResource(at: 3, userCPUSeconds: 3, systemCPUSeconds: 2,
            logicalWriteBytes: 1_048_586, diskReadBytes: 40, diskWriteBytes: 60,
            footprintBytes: 150, lifetimeMaxFootprintBytes: 200)
        guard case .value(let delta) = MacPerfResourceDelta.between(.value(before), .value(after)) else {
            return XCTFail("valid rusage endpoints must produce rates")
        }
        XCTAssertEqual(delta.cpuPercent, 100, accuracy: 0.0001)
        XCTAssertEqual(delta.logicalWriteMiBPerHour, 1800, accuracy: 0.0001)
        XCTAssertEqual(delta.diskReadBytes, 20)
        guard case .failure = MacPerfResourceDelta.between(.value(after), .value(before)) else {
            return XCTFail("regressed endpoints must not wrap unsigned counters")
        }
        guard case .failure = MacPerfResourceDelta.between(.failure("denied"), .value(after)) else {
            return XCTFail("a missing endpoint must not produce a zero delta")
        }
    }

    func testActualCPUSecondsMatchGetrusageInsteadOfAssumingNanosecondTicks() throws {
        func cpu(_ value: rusage) -> Double {
            Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
                + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let value = try MacPerfResource.read()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let actual = value.userCPUSeconds + value.systemCPUSeconds
        XCTAssertGreaterThanOrEqual(actual, cpu(before) - 0.01)
        XCTAssertLessThanOrEqual(actual, cpu(after) + 0.01)
    }

    @MainActor func testSQLCounterExcludesBackgroundPrepares() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite")
        let count = OSAllocatedUnfairLock(initialState: 0)
        let reader = try CodingSessionIndex(url: url)
        reader.macPerfMainPrepare = { count.withLock { $0 += 1 } }
        _ = try reader.sessionCount()
        XCTAssertEqual(count.withLock { $0 }, 1)
        try await Task.detached {
            let worker = try CodingSessionIndex(url: url, readOnly: true)
            worker.macPerfMainPrepare = { count.withLock { $0 += 1 } }
            _ = try worker.sessionCount()
        }.value
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    @MainActor func testUnfocusedNativeFieldIsInputWithoutAnEditingTextView() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = window.contentView!
        let readonly = NSTextView(frame: NSRect(x: 10, y: 10, width: 100, height: 30))
        readonly.isEditable = false
        root.addSubview(readonly)
        let field = NSTextField(frame: NSRect(x: 10, y: 60, width: 200, height: 40))
        field.isEditable = true
        field.isEnabled = true
        root.addSubview(field)
        XCTAssertNil(field.currentEditor())
        XCTAssertTrue(PerfHarnessMacDriver.inputControl(in: root, within: root.bounds) === field)
        field.isEnabled = false
        XCTAssertNil(PerfHarnessMacDriver.inputControl(in: root, within: root.bounds))
    }

    @MainActor func testInputWitnessRejectsHiddenReadonlyAndOutOfComposerControls() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = window.contentView!
        let field = NSTextField(frame: NSRect(x: 180, y: 60, width: 100, height: 40))
        field.isEditable = true
        root.addSubview(field)
        let composer = CGRect(x: 0, y: 0, width: 150, height: 150)
        XCTAssertNil(PerfHarnessMacDriver.inputControl(in: root, within: composer),
                     "frame=\(field.frame) visible=\(field.visibleRect) converted=\(field.convert(field.visibleRect, to: root)) root=\(root.bounds) composer=\(composer)")
        field.frame.origin.x = 10
        field.isHidden = true
        XCTAssertNil(PerfHarnessMacDriver.inputControl(in: root, within: composer))
        field.isHidden = false
        field.isEditable = false
        XCTAssertNil(PerfHarnessMacDriver.inputControl(in: root, within: composer))
        let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 120, height: 30))
        editor.isEditable = true
        root.addSubview(editor)
        XCTAssertTrue(PerfHarnessMacDriver.inputControl(in: root, within: composer) === editor)
    }

    @MainActor func testActualSwiftUIFieldCanBecomeFirstResponderWithoutPreFocusing() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: TextField("发消息…", text: .constant(""), axis: .vertical)
            .textFieldStyle(.plain).frame(width: 280, height: 80))
        window.contentView = host
        var control: NSView?
        let deadline = Date().addingTimeInterval(1)
        repeat {
            host.layoutSubtreeIfNeeded()
            control = PerfHarnessMacDriver.inputControl(in: host, within: host.bounds)
            if control != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        guard let control else { return XCTFail("unfocused SwiftUI chat input was not recognized") }
        XCTAssertTrue(window.makeFirstResponder(control))
        XCTAssertTrue(window.firstResponder === control ||
            (control as? NSTextField)?.currentEditor() === window.firstResponder)
    }

}
#endif
