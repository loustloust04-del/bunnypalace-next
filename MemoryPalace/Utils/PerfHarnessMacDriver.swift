#if (DEBUG || PERF_BENCH) && os(macOS)
import AppKit
import SwiftUI
import SwiftData
import QuartzCore
import Darwin
import SQLite3

/// R1-3 produces this manifest inside the isolated root. IDs are expectations, never evidence.
/// Every referenced path is checked against BenchIsolation before it is opened.
struct MacPerfFixture: Decodable {
    struct Chat: Decodable {
        let name: String
        let profileID: String
        let conversationID: String
        let orderedPath: [String]
        let longNodeID: String
    }
    struct Code: Decodable { let name: String; let key: String; let path: String; let minimumBytes: UInt64 }
    struct File: Decodable { let path: String; let bytes: UInt64 }
    struct Load: Decodable {
        let level: String
        let pid: Int32
        let heartbeatPath: String
        let files: [String]
        let codeKey: String?
        let terminalTitle: String?
        let terminalMarker: String?
        let bridgeFramesPath: String?
        let backgroundConversationID: String?
        let ioBytesPerSecond: UInt64?
    }
    let revision: String
    let profiles: [String]
    let chats: [Chat]
    let code: [Code]
    let files: [File]
    let loads: [Load]
    let streamConversationID: String
    let streamPresetID: String
}

struct MacPerfFingerprint: Codable {
    struct Profile: Codable { let id: String; let conversations: Int; let messages: Int }
    struct LongText: Codable { let nodeID: String; let characters: Int; let utf8Bytes: Int }
    struct File: Codable { let path: String; let bytes: UInt64; let modified: Double }
    struct Page: Codable { let name: String; let type: String; let pages: Int64; let bytes: Int64; let unused: Int64 }
    let profiles: [Profile]
    let longTexts: [LongText]
    let codingPageCount: Int64
    let codingFreelistCount: Int64
    let codingPages: [Page]
    let files: [File]
}

@MainActor
enum PerfHarnessMacDriver {
    static weak var viewModel: ConversationViewModel?
    static weak var profiles: ProfileManager?
    static weak var tools: RightPanelToolManager?
    static var context: ModelContext?
    static var openConversation: ((Conversation) -> Void)?
    static var openSettings: (() -> Void)?
    static var sendStream: ((String, String) throws -> Void)?
    static var settingsTabs: [String] = []
    static var settingsAppeared: [String: UInt64] = [:]
    static var markdownPending = 0
    static var actionSequence: UInt64 = 0
    private static var fixture: MacPerfFixture?
    private static var anchors: [String: WeakView] = [:]
    private static var fullscreenSequence: UInt64 = 0
    private static var observers: [NSObjectProtocol] = []
    private final class WeakView { weak var value: NSView?; init(_ value: NSView) { self.value = value } }
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let text) = self { return text }; return "invalid fixture" }
    }
    static var loadEvidence: [String: String] = [:]
    private static var panelStableFrames = 0
    private static var panelLastFrame: CGRect?
    private static var panelAnimationComplete = false
    private static var samplingPanel = false

    static func displayFrame() {
        guard PerfHarnessMac.enabled, samplingPanel, panelAnimationComplete,
              let anchor = view("chatContent"), let content = anchor.window?.contentView else { return }
        let rect = anchor.convert(anchor.bounds, to: content)
        panelStableFrames = panelLastFrame == rect ? panelStableFrames + 1 : 1
        panelLastFrame = rect
    }

    static func register(_ view: NSView, key: String) {
        guard PerfHarnessMac.enabled, view.window != nil else { return }
        anchors[key] = WeakView(view)
        if key == "main", let window = view.window {
            PerfHarnessMac.mainWindow = window
            PerfHarnessMac.attach(view: view)
        }
    }
    static func action() { if PerfHarnessMac.enabled { actionSequence &+= 1 } }
    static func appeared(_ tab: String) {
        guard PerfHarnessMac.enabled else { return }
        settingsAppeared[tab, default: 0] &+= 1
    }
    private static func view(_ key: String) -> NSView? {
        guard let view = anchors[key]?.value, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view
    }
    private static weak var inputView: NSView?
    private static func firstDescendant<T: NSView>(_ root: NSView, type: T.Type, matching predicate: (T) -> Bool) -> T? {
        if let candidate = root as? T, predicate(candidate) { return candidate }
        for child in root.subviews {
            if let match = firstDescendant(child, type: type, matching: predicate) { return match }
        }
        return nil
    }
    private static func matchesInput(_ candidate: NSView, window: NSWindow, bounds: CGRect) -> Bool {
        if let field = candidate as? NSTextField {
            guard field.isEditable && field.isEnabled else { return false }
        } else if (candidate as? NSTextView)?.isEditable != true { return false }
        guard candidate.window === window, !candidate.isHiddenOrHasHiddenAncestor,
              candidate.acceptsFirstResponder, let root = window.contentView else { return false }
        let clipped = candidate.bounds.intersection(candidate.visibleRect)
        return !clipped.isEmpty && candidate.convert(clipped, to: root).intersects(bounds)
    }
    static func inputControl(in root: NSView, within bounds: CGRect) -> NSView? {
        guard let window = root.window else { return nil }
        return firstDescendant(root, type: NSView.self) { matchesInput($0, window: window, bounds: bounds) }
    }
    private static var input: NSView? {
        guard let anchor = view("composer"), let window = anchor.window, let root = window.contentView else { return nil }
        let bounds = anchor.convert(anchor.bounds, to: root)
        if let inputView, matchesInput(inputView, window: window, bounds: bounds) { return inputView }
        inputView = inputControl(in: root, within: bounds)
        return inputView
    }
    private static var inputReady: Bool {
        guard let input, let window = input.window else { return false }
        return window.isKeyWindow
    }
    private static var inputString: String? {
        if let field = input as? NSTextField { return field.currentEditor()?.string ?? field.stringValue }
        return (input as? NSTextView)?.string
    }
    private static func editingView(for control: NSView) -> NSTextView? {
        guard let window = control.window, window.makeFirstResponder(control) else { return nil }
        if let text = control as? NSTextView { return text }
        return (control as? NSTextField)?.currentEditor() as? NSTextView
    }
    private static func visible(_ key: String) -> Bool {
        guard let node = view(key), let window = node.window else { return false }
        let rect = node.convert(node.bounds.intersection(node.visibleRect), to: window.contentView)
        return !rect.isEmpty && rect.intersects(window.contentView?.bounds ?? .zero)
    }
    private static func pathURL(_ path: String) throws -> URL {
        guard PerfHarnessMac.enabled, let isolation = BenchIsolation.configuration else { throw Failure.invalid("isolation unavailable") }
        return try isolation.check(URL(fileURLWithPath: path))
    }
    private static func loadFixture() throws -> MacPerfFixture {
        guard let config = PerfHarnessMac.configuration else { throw Failure.invalid("missing configuration") }
        let fixtureURL = try pathURL(config.fixtureURL.path)
        let value = try JSONDecoder().decode(MacPerfFixture.self, from: Data(contentsOf: fixtureURL))
        guard value.revision == "macV1-r1-fixture", !value.profiles.isEmpty,
              Set(value.profiles).count == value.profiles.count,
              !value.files.isEmpty, value.files.allSatisfy({ $0.bytes > 0 }) else {
            throw Failure.invalid("fixture revision/profiles/files invalid")
        }
        guard Set(value.chats.map(\.name)).count == value.chats.count,
              Set(value.code.map(\.name)).count == value.code.count,
              value.chats.allSatisfy({ value.profiles.contains($0.profileID) }) else {
            throw Failure.invalid("fixture cases must be unique and scoped to declared floors")
        }
        return value
    }

    static func fingerprint() throws -> MacPerfFingerprint {
        guard PerfHarnessMac.enabled, let context, let fixture else { throw Failure.invalid("fingerprint requires registered context and decoded fixture") }
        var counts: [MacPerfFingerprint.Profile] = []
        var texts: [MacPerfFingerprint.LongText] = []
        for profile in fixture.profiles {
            let conversations = try context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == profile }))
            let messages = try context.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == profile }))
            counts.append(.init(id: profile, conversations: conversations, messages: messages))
        }
        for chat in fixture.chats {
            let id = chat.longNodeID
            guard let node = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })).first,
                  node.profileId == chat.profileID, node.conversationId == chat.conversationID else {
                throw Failure.invalid("missing long-text node \(id)")
            }
            texts.append(.init(nodeID: id, characters: node.content.count, utf8Bytes: node.content.utf8.count))
        }
        let index = try pathURL(CodingSessionIndex.defaultURL.path)
        var db: OpaquePointer?
        guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); throw Failure.invalid("fingerprint cannot open actual coding index")
        }
        defer { sqlite3_close(db) }
        func query(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.invalid("fingerprint SQL: \(String(cString: sqlite3_errmsg(db)))") }
            defer { sqlite3_finalize(statement) }
            var rows: [[String]] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw Failure.invalid("fingerprint SQL step failed") }
                rows.append((0..<sqlite3_column_count(statement)).map { col in
                    sqlite3_column_text(statement, col).map { String(cString: $0) } ?? "NULL"
                })
            }
        }
        func integer(_ sql: String) throws -> Int64 {
            guard let row = try query(sql).first, let raw = row.first, let value = Int64(raw) else { throw Failure.invalid("missing page metadata") }
            return value
        }
        let pages = try query("SELECT name,pagetype,count(*),sum(pgsize),sum(unused) FROM dbstat GROUP BY name,pagetype ORDER BY name,pagetype").map { row -> MacPerfFingerprint.Page in
            guard row.count == 5, let count = Int64(row[2]), let bytes = Int64(row[3]), let unused = Int64(row[4]) else { throw Failure.invalid("invalid dbstat row") }
            return .init(name: row[0], type: row[1], pages: count, bytes: bytes, unused: unused)
        }
        guard !pages.isEmpty else { throw Failure.invalid("dbstat unavailable or empty") }
        guard let configuration = PerfHarnessMac.configuration else { throw Failure.invalid("fingerprint configuration absent") }
        let paths = Set(fixture.files.map(\.path) + fixture.code.map(\.path) + fixture.loads.flatMap(\.files) + [configuration.fixtureURL.path])
        let files = try paths.sorted().map { path -> MacPerfFingerprint.File in
            let url = try pathURL(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let bytes = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else { throw Failure.invalid("missing file metadata") }
            return .init(path: url.path, bytes: bytes.uint64Value, modified: date.timeIntervalSince1970)
        }
        return try .init(profiles: counts, longTexts: texts, codingPageCount: integer("PRAGMA page_count"), codingFreelistCount: integer("PRAGMA freelist_count"), codingPages: pages, files: files)
    }

    static func run() async {
        guard PerfHarnessMac.enabled else { return }
        // Registration may follow App.init; no data/fixture read occurs until the real scene exists.
        let deadline = CACurrentMediaTime() + 10
        while (context == nil || viewModel == nil || profiles == nil || view("main") == nil
               || !NSApp.isActive || PerfHarnessMac.mainWindow?.isKeyWindow != true) && CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard context != nil, viewModel != nil, profiles != nil, view("main") != nil,
              NSApp.isActive, PerfHarnessMac.mainWindow?.isKeyWindow == true else {
            PerfHarnessMac.fail("driver: foreground main scene registration missing"); PerfHarnessMac.finish()
        }
        if PerfHarnessMac.configuration?.scenarios.contains("M1") == true { await coldStart() }
        do { fixture = try loadFixture() }
        catch { PerfHarnessMac.fail("fixture: \(error)"); PerfHarnessMac.finish() }
        PerfHarnessMac.captureFixtureBefore()
        guard let configuration = PerfHarnessMac.configuration, let fixture else { PerfHarnessMac.finish() }
        for scenario in configuration.scenarios {
            do {
                if scenario != "M9" { try requireWritersStopped(fixture) }
                switch scenario {
                case "M1": break // Already measured before fingerprint/fixture I/O.
                case "M2": try await conversations(fixture, caseName: configuration.caseName)
                case "M3": try await floors(fixture)
                case "M4": try await panels()
                case "M5": try await settings()
                case "M6": try await stream(fixture)
                case "M7": try await windows()
                case "M8": try await coding(fixture, caseName: configuration.caseName)
                case "M9": try await load(fixture, level: configuration.loadLevel)
                default: throw Failure.invalid("unknown scenario \(scenario)")
                }
                if scenario != "M9" { try requireWritersStopped(fixture) }
            } catch { PerfHarnessMac.fail("\(scenario): \(error)") }
        }
        PerfHarnessMac.finish()
    }
    private static func requireWritersStopped(_ fixture: MacPerfFixture) throws {
        for load in fixture.loads where load.level != "L0" && load.pid > 0 {
            guard kill(load.pid, 0) != 0 && errno == ESRCH else { throw Failure.invalid("M1-M8/L0 require stopped load PID \(load.pid)") }
        }
        guard !PerfHarnessMacStream.active else { throw Failure.invalid("previous synthetic stream still active") }
    }
    private static func coldStart() async {
        IPadPanelLayout.shared.leftShown = true
        let ready: () -> Bool = {
            guard let window = PerfHarnessMac.mainWindow, let vm = viewModel, let profiles else { return false }
            return NSApp.isActive && window.isKeyWindow && window.isVisible && inputReady
                && vm.isDraftConversation && sidebarVisible(profiles.currentProfile.id)
        }
        let deadline = (PerfHarnessMac.processStart ?? CACurrentMediaTime()) + 10
        while !ready() && CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !ready() {
            loadEvidence["M1.inputReady"] = String(inputReady)
            loadEvidence["M1.sidebarVisible"] = String(profiles.map { sidebarVisible($0.currentProfile.id) } ?? false)
            loadEvidence["M1.composerBounds"] = view("composer").map { NSStringFromRect($0.bounds) } ?? "missing"
            loadEvidence["M1.inputType"] = input.map { String(reflecting: type(of: $0)) } ?? "missing"
        }
        await PerfHarnessMac.measure("M1", t0: PerfHarnessMac.processStart, action: {}, condition: ready, assertions: {
            var failures: [String] = []
            if PerfHarnessMac.processStart == nil { failures.append("process start unavailable") }
            if viewModel?.isDraftConversation != true { failures.append("cold launch is not draft") }
            return failures
        })
    }
    private static func sidebarVisible(_ profile: String) -> Bool {
        anchors.contains { key, box in
            key.hasPrefix("chat:\(profile):") && box.value != nil && visible(key)
        }
    }
    private static func conversation(_ id: String, profile: String? = nil) throws -> Conversation {
        guard let context, let conversation = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first,
              profile == nil || conversation.profileId == profile else { throw Failure.invalid("conversation missing/wrong floor: \(id)") }
        return conversation
    }
    private static func switchFloor(_ id: String) throws {
        guard let profiles, let target = profiles.profiles.first(where: { $0.id == id }) else { throw Failure.invalid("fixture floor missing: \(id)") }
        profiles.switchTo(target)
    }
    private static func chatReady(_ chat: MacPerfFixture.Chat) -> Bool {
        guard let vm = viewModel, vm.selectedConversation?.id == chat.conversationID,
              !vm.isLoading, !vm.isDraftConversation, vm.currentPath.count == chat.orderedPath.count,
              zip(vm.currentPath, chat.orderedPath).allSatisfy({ $0.0.id == $0.1 }),
              let latest = chat.orderedPath.last else { return false }
        return visible("bubble:\(chat.conversationID):\(latest)") && markdownPending == 0 && inputReady
    }
    private static func conversations(_ fixture: MacPerfFixture, caseName: String) async throws {
        let chats = fixture.chats.filter { caseName == "all" || caseName == $0.name }
        guard !chats.isEmpty else { throw Failure.invalid("M2 fixture cases missing") }
        if caseName == "all", !Set(["A", "B", "C"]).isSubset(of: Set(chats.map(\.name))) {
            throw Failure.invalid("M2 all requires A/B/C")
        }
        for chat in chats {
            guard !chat.orderedPath.isEmpty, Set(chat.orderedPath).count == chat.orderedPath.count else { throw Failure.invalid("invalid ordered path") }
            guard let context else { throw Failure.invalid("M2 context missing") }
            let conversationID = chat.conversationID
            let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == conversationID }))
            let minimum = ["A": 50, "B": 250, "C": 1800][chat.name]
            guard let minimum, nodes.count >= minimum else { throw Failure.invalid("M2 A/B/C real fixture too small") }
            if chat.name == "B" {
                guard nodes.contains(where: { $0.id == chat.longNodeID && $0.content.count > 3000 }),
                      nodes.contains(where: { $0.childrenIds.count > 1 }) else {
                    throw Failure.invalid("B requires actual >3000-character text and branch")
                }
            }
            try switchFloor(chat.profileID)
            IPadPanelLayout.shared.leftShown = true
            await registration(profile: chat.profileID)
            for phase in ["cold", "hot", "same-id", "sendEvent"] {
                if phase == "hot" {
                    guard let other = fixture.chats.first(where: { $0.conversationID != chat.conversationID && $0.profileID == chat.profileID }) else {
                        throw Failure.invalid("hot reopen requires another actual conversation on the same floor")
                    }
                    openConversation?(try conversation(other.conversationID, profile: other.profileID))
                    await PerfHarnessMac.measure("M2.\(chat.name).hot-prerequisite", action: {}, condition: { chatReady(other) }, assertions: { chatReady(other) ? [] : ["intermediate conversation failed"] })
                }
                let target = try conversation(chat.conversationID, profile: chat.profileID)
                let previous = actionSequence
                if phase == "sendEvent" {
                    IPadPanelLayout.shared.leftShown = true
                    await requireVisible("chat:\(chat.profileID):\(chat.conversationID)")
                }
                await PerfHarnessMac.measure("M2.\(chat.name).\(phase)", action: {
                    guard let openConversation else { throw Failure.invalid("sidebar click function unavailable") }
                    if phase == "sendEvent" { try click("chat:\(chat.profileID):\(chat.conversationID)") }
                    else { openConversation(target) }
                }, condition: { actionSequence > previous && chatReady(chat) }, assertions: {
                    chatReady(chat) ? [] : ["id/path/latest mounted bubble/async layout/input mismatch"]
                })
            }
        }
    }
    private static func registration(profile: String) async {
        let end = CACurrentMediaTime() + 10
        while (profiles?.currentProfile.id != profile || !sidebarVisible(profile) || openConversation == nil) && CACurrentMediaTime() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func requireVisible(_ key: String) async {
        let end = CACurrentMediaTime() + 10
        while !visible(key) && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(20)) }
        if !visible(key) { PerfHarnessMac.fail("real UI target failed to mount: \(key)") }
    }
    private static func floors(_ fixture: MacPerfFixture) async throws {
        guard fixture.profiles.count >= 2 else { throw Failure.invalid("M3 requires small and large floors") }
        guard let context else { throw Failure.invalid("M3 context missing") }
        let counts = try fixture.profiles.map { id in
            try context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == id }))
        }
        guard counts.allSatisfy({ $0 > 0 }), Set(counts).count > 1 else { throw Failure.invalid("M3 requires actual nonempty small/large floors") }
        IPadPanelLayout.shared.leftShown = true
        for id in fixture.profiles {
            if profiles?.currentProfile.id == id, let other = fixture.profiles.first(where: { $0 != id }) {
                try switchFloor(other)
                await registration(profile: other)
            }
            await PerfHarnessMac.measure("M3.\(id)", action: { try switchFloor(id) }, condition: {
                profiles?.currentProfile.id == id && sidebarVisible(id) && viewModel?.isDraftConversation == true && inputReady
            }, assertions: { profiles?.currentProfile.id == id && viewModel?.isDraftConversation == true ? [] : ["floor/draft mismatch"] })
        }
    }
    private static func panels() async throws {
        guard view("main")?.window?.contentView != nil, let tools else { throw Failure.invalid("panel scene/catalog absent") }
        let layout = IPadPanelLayout.shared
        layout.apply(layout.factorySnapshot())
        for id in [IPadPanelLayout.convWindowId] + tools.allToolsSorted.map(\.id) {
            for opened in [true, false] {
                let actual = id == IPadPanelLayout.convWindowId ? layout.leftShown : layout.isOpen(id)
                if actual == opened {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if id == IPadPanelLayout.convWindowId { layout.leftShown = !opened }
                        else if opened { layout.close(id) } else { layout.open(id) }
                    }
                    panelAnimationComplete = true
                    panelLastFrame = nil
                    panelStableFrames = 0
                    samplingPanel = true
                    let end = CACurrentMediaTime() + 10
                    while panelStableFrames < 3 && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(20)) }
                    samplingPanel = false
                    guard panelStableFrames >= 3 else { throw Failure.invalid("panel prerequisite has no actual stable display frames") }
                }
                panelAnimationComplete = false
                panelLastFrame = nil
                panelStableFrames = 0
                samplingPanel = true
                await PerfHarnessMac.measure("M4.\(id).\(opened ? "open" : "close")", action: {
                    withAnimation(.easeInOut(duration: 0.25), completionCriteria: .removed) {
                        if id == IPadPanelLayout.convWindowId { layout.leftShown = opened }
                        else if opened { layout.open(id) } else { layout.close(id) }
                    } completion: { panelAnimationComplete = true }
                }, condition: {
                    let actual = id == IPadPanelLayout.convWindowId ? layout.leftShown : layout.isOpen(id)
                    let mounted = id == IPadPanelLayout.convWindowId
                        ? (profiles.map { sidebarVisible($0.currentProfile.id) } ?? false) : visible("panel:\(id)")
                    return panelAnimationComplete && actual == opened && mounted == opened && panelStableFrames >= 3
                }, assertions: { panelAnimationComplete && panelStableFrames >= 3 ? [] : ["panel animation/frame stability not observed"] })
                samplingPanel = false
                if id == "calendar" {
                    loadEvidence["M4.calendar.\(opened)"] = "mode=\(layout.mode.rawValue),dock=\(layout.dockShown),open=\(layout.isOpen(id)),visible=\(visible("panel:\(id)")),animation=\(panelAnimationComplete),stableFrames=\(panelStableFrames)"
                }
            }
        }
    }
    private static func settings() async throws {
        guard let openSettings else { throw Failure.invalid("openSettings action missing") }
        openSettings()
        let end = CACurrentMediaTime() + 10
        while settingsTabs.isEmpty && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(20)) }
        guard !settingsTabs.isEmpty else { throw Failure.invalid("settings window did not register pages") }
        for tab in settingsTabs {
            let previous = settingsAppeared[tab, default: 0]
            // A currently displayed page is first moved away so onAppear must be fresh.
            if let other = settingsTabs.first(where: { $0 != tab }), settingsAppeared[tab] != nil {
                SettingsView.requestMacTab(SettingsView.SettingsTab(rawValue: other)!)
                try? await Task.sleep(for: .milliseconds(50))
            }
            await PerfHarnessMac.measure("M5.\(tab)", action: {
                guard let target = SettingsView.SettingsTab(rawValue: tab) else { throw Failure.invalid("invalid settings tab") }
                SettingsView.requestMacTab(target)
            }, condition: { settingsAppeared[tab, default: 0] > previous && visible("settings:\(tab)") }, assertions: {
                settingsAppeared[tab, default: 0] > previous ? [] : ["settings page root never appeared"]
            })
        }
        view("settingsRoot")?.window?.close()
        PerfHarnessMac.mainWindow?.makeKeyAndOrderFront(nil)
    }
    private static func stream(_ fixture: MacPerfFixture) async throws {
        // Floor switching rebuilds the composer: take its send closure only after registration.
        let target = try conversation(fixture.streamConversationID)
        try switchFloor(target.profileId)
        IPadPanelLayout.shared.leftShown = true
        await registration(profile: target.profileId)
        guard let openConversation else { throw Failure.invalid("sidebar click missing") }
        openConversation(target)
        await PerfHarnessMac.measure("M6.prepare", action: {}, condition: {
            guard viewModel?.selectedConversation?.id == target.id, inputReady, viewModel?.isLoading == false,
                  let scroll = view("transcript")?.enclosingScrollView, let document = scroll.documentView else { return false }
            return document.bounds.height - scroll.contentView.bounds.height >= 500
        }, assertions: { [] })
        guard let sendStream else { throw Failure.invalid("real sendMessage registration missing") }
        try sendStream(fixture.streamConversationID, fixture.streamPresetID)
        let start = CACurrentMediaTime()
        while !PerfHarnessMacStream.active && CACurrentMediaTime() - start < 10 { try? await Task.sleep(for: .milliseconds(10)) }
        guard PerfHarnessMacStream.active else { throw Failure.invalid("router synthetic credential did not start") }
        loadEvidence["M6.provider"] = "synthetic local provider; one token = one Chinese character, not model tokenizer throughput"
        loadEvidence["M6.plannedCharactersPerSecond"] = "30"
        for phase in ["during", "after"] {
            if phase == "after" {
                while PerfHarnessMacStream.active && CACurrentMediaTime() - start < 115 { try? await Task.sleep(for: .milliseconds(30)) }
            }
            for step in 0..<5 {
                let text = "测\(phase)\(step)"
                weak var scrollWitness: NSScrollView?
                var expectedScrollY: CGFloat?
                func scrollLanded() -> Bool {
                    guard let scrollWitness, let expectedScrollY else { return false }
                    return abs(scrollWitness.contentView.bounds.origin.y - expectedScrollY) < 1
                }
                await PerfHarnessMac.measure("M6.\(phase).\(step)", action: {
                    guard let control = input, let editor = editingView(for: control), let window = editor.window,
                          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) else { throw Failure.invalid("native key event unavailable") }
                    guard !editor.string.contains(text) else { throw Failure.invalid("typing fixture already contains the injected token") }
                    window.sendEvent(event)
                    guard let anchor = view("transcript"), let scroll = anchor.enclosingScrollView,
                          let document = scroll.documentView else { throw Failure.invalid("native transcript scroll missing") }
                    let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    guard maxY >= 500 else { throw Failure.invalid("M6 fixture lacks a real scrollable history") }
                    var requested = scroll.contentView.bounds
                    requested.origin = NSPoint(x: 0, y: maxY * CGFloat(step + 1) / 6)
                    let landed = scroll.contentView.constrainBoundsRect(requested).origin
                    scroll.contentView.scroll(to: landed)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    scrollWitness = scroll
                    expectedScrollY = landed.y
                }, condition: {
                    inputString?.contains(text) == true && scrollLanded() && (phase == "during" ? PerfHarnessMacStream.active : !PerfHarnessMacStream.active)
                }, assertions: { inputString?.contains(text) == true && scrollLanded() ? [] : ["native typing/scroll did not land"] })
            }
        }
        await PerfHarnessMac.measure("M6.final-render", action: {
            guard let scroll = view("transcript")?.enclosingScrollView,
                  let document = scroll.documentView else { throw Failure.invalid("final transcript scroll unavailable") }
            let endY = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            var requested = scroll.contentView.bounds
            requested.origin = NSPoint(x: 0, y: endY)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(requested).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }, condition: {
            guard let vm = viewModel, let latest = vm.currentPath.last else { return false }
            return PerfHarnessMacStream.completedCharacters == 3000 && !PerfHarnessMacStream.active &&
                !vm.assistantTurnInFlight && latest.content == PerfHarnessMacStream.output &&
                visible("bubble:\(fixture.streamConversationID):\(latest.id)") && markdownPending == 0
        }, assertions: {
            PerfHarnessMacStream.completedCharacters == 3000 && viewModel?.currentPath.last?.content == PerfHarnessMacStream.output
                ? [] : ["synthetic 30 tokens/s × 3000 characters failed to render/finalize"]
        })
        loadEvidence["M6.deliveredCharacters"] = String(PerfHarnessMacStream.completedCharacters)
        loadEvidence["M6.maximumTokenLatenessSeconds"] = String(PerfHarnessMacStream.maximumLateness)
        loadEvidence["M6.final.markdownPending"] = String(markdownPending)
        loadEvidence["M6.final.turnInFlight"] = String(viewModel?.assistantTurnInFlight == true)
        if let latest = viewModel?.currentPath.last {
            loadEvidence["M6.final.bubbleVisible"] = String(visible("bubble:\(fixture.streamConversationID):\(latest.id)"))
        }
    }
    private static func windows() async throws {
        guard let window = PerfHarnessMac.mainWindow else { throw Failure.invalid("main window missing") }
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in MainActor.assumeIsolated { fullscreenSequence &+= 1 } })
        }
        defer { for observer in observers { center.removeObserver(observer) }; observers.removeAll() }
        for fullscreen in [true, false] {
            let previous = fullscreenSequence
            await PerfHarnessMac.measure("M7.fullscreen.\(fullscreen)", action: {
                guard window.styleMask.contains(.fullScreen) != fullscreen else { throw Failure.invalid("unexpected initial fullscreen state") }
                window.toggleFullScreen(nil)
            }, condition: { fullscreenSequence > previous && window.styleMask.contains(.fullScreen) == fullscreen }, assertions: { fullscreenSequence > previous ? [] : ["fullscreen notification missing"] })
        }
        let original = window.frame
        defer { window.setFrame(original, display: true) }
        guard let screen = window.screen else { throw Failure.invalid("resize ladder requires an actual display") }
        let contentMinimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let minimum = CGSize(width: max(window.minSize.width, contentMinimum.width),
                             height: max(window.minSize.height, contentMinimum.height))
        let maximum = CGSize(width: min(window.maxSize.width, screen.visibleFrame.width),
                             height: min(window.maxSize.height, screen.visibleFrame.height))
        guard maximum.width > minimum.width, maximum.height > minimum.height else {
            throw Failure.invalid("window/display constraints leave no real resize range")
        }
        for fraction in [0.25, 0.75, 0.5, 1.0] {
            let size = CGSize(width: minimum.width + (maximum.width - minimum.width) * fraction,
                              height: minimum.height + (maximum.height - minimum.height) * fraction)
            let target = CGRect(origin: screen.visibleFrame.origin, size: size).integral
            await PerfHarnessMac.measure("M7.resize.\(fraction)", action: { window.setFrame(target, display: true) }, condition: { window.frame == target }, assertions: { window.frame == target ? [] : ["window resize clamped or failed"] })
        }
    }
    private static func codeReady(_ key: String) -> Bool {
        let library = CodingSessionLibrary.shared
        guard library.isActive, library.selectedKey == key, case .loaded(let box) = library.detail else { return false }
        return box.transcript.meta.key == key && visible("code:\(key)") && visible("codeDetail:\(key)")
    }
    private static func coding(_ fixture: MacPerfFixture, caseName: String) async throws {
        let cases = fixture.code.filter { caseName == "all" || caseName == $0.name }
        guard !cases.isEmpty else { throw Failure.invalid("M8 code fixtures missing") }
        if caseName == "all", !Set(["small", "large"]).isSubset(of: Set(cases.map(\.name))) {
            throw Failure.invalid("M8 all requires small and 100MB large cases")
        }
        IPadPanelLayout.shared.leftShown = true
        for item in cases {
            let attributes = try FileManager.default.attributesOfItem(atPath: pathURL(item.path).path)
            guard let size = attributes[.size] as? NSNumber, size.uint64Value >= item.minimumBytes,
                  item.name != "large" || size.uint64Value >= 100_000_000 else { throw Failure.invalid("Code fixture below required size") }
            await PerfHarnessMac.measure("M8.\(item.name)", action: {
                MacLeftPanelGroup.select(.code)
                CodingSessionLibrary.shared.select(item.key)
            }, condition: { codeReady(item.key) }, assertions: { codeReady(item.key) ? [] : ["Code list/loaded detail mismatch"] })
            if case .loaded(let box) = CodingSessionLibrary.shared.detail,
               try pathURL(box.transcript.meta.filePath) != pathURL(item.path) {
                throw Failure.invalid("loaded Code file does not match actual fixture path")
            }
            guard let other = fixture.code.first(where: { $0.key != item.key }) else {
                throw Failure.invalid("Code sendEvent select cross-check requires second real session")
            }
            await PerfHarnessMac.measure("M8.\(item.name).event-prerequisite", action: {
                CodingSessionLibrary.shared.select(other.key)
            }, condition: { codeReady(other.key) }, assertions: { codeReady(other.key) ? [] : ["Code prerequisite not loaded"] })
            let before = actionSequence
            await PerfHarnessMac.measure("M8.\(item.name).sendEvent", action: { try click("code:\(item.key)") }, condition: {
                actionSequence > before && codeReady(item.key)
            }, assertions: { actionSequence > before ? [] : ["Code event did not reach row action"] })
        }
        MacLeftPanelGroup.select(.chats)
    }
    private static func loadIO(_ pid: Int32) throws -> (read: UInt64, written: UInt64) {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw Failure.invalid("cannot read actual load PID rusage") }
        return (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
    }
    private static func click(_ key: String) throws {
        guard let anchor = view(key), let window = anchor.window else { throw Failure.invalid("sendEvent target not mounted: \(key)") }
        let rect = anchor.convert(anchor.bounds.intersection(anchor.visibleRect), to: nil)
        guard rect.width > 0 && rect.height > 0 else { throw Failure.invalid("sendEvent target has no geometry") }
        let point = NSPoint(x: rect.minX + min(20, rect.width / 2), y: rect.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw Failure.invalid("cannot construct mouse event") }
            window.sendEvent(event)
        }
    }

    /// Load generators belong to R1-3. A PID/manifest alone is insufficient: each
    /// active load must keep a fresh heartbeat AND mutate its declared real files.
    private static func load(_ fixture: MacPerfFixture, level: String) async throws {
        let library = CodingSessionLibrary.shared
        var terminalID: UUID?
        defer { if let terminalID { LocalTerminalStore.shared.close(terminalID) } }
        if level == "L0" {
            try requireWritersStopped(fixture)
            MacLeftPanelGroup.select(.chats)
            loadEvidence["L0.writerState"] = "all declared PIDs verified stopped"
            await PerfHarnessMac.observe("M9.L0", duration: 600, condition: {
                guard !library.isActive else { return false }
                do { try requireWritersStopped(fixture); return true } catch { return false }
            }, assertions: { library.isActive ? ["Code open in L0"] : [] })
            return
        }
        guard let spec = fixture.loads.first(where: { $0.level == level }), spec.pid > 0,
              kill(spec.pid, 0) == 0, !spec.files.isEmpty else { throw Failure.invalid("R1-3 live load fixture missing: \(level)") }
        let heartbeat = try pathURL(spec.heartbeatPath)
        let files = try spec.files.map(pathURL)
        func sizes() throws -> [UInt64] {
            try files.map { url in
                guard let value = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { throw Failure.invalid("load file size missing") }
                return value.uint64Value
            }
        }
        let initial = try sizes()
        loadEvidence["\(level).pid"] = String(spec.pid)
        loadEvidence["\(level).files"] = files.map(\.path).joined(separator: "\n")
        loadEvidence["\(level).initialBytes"] = initial.map(String.init).joined(separator: ",")
        loadEvidence["\(level).heartbeat"] = heartbeat.path
        if ["L1a", "L1b", "L1c", "background"].contains(level) {
            let end = CACurrentMediaTime() + 10
            while !library.perfWatcherRunning && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(20)) }
        }
        if ["L1a", "L1b", "L1c", "background"].contains(level) {
            guard files.count == 3,
                  initial.sorted()[0] >= 5_000_000, initial.sorted()[1] >= 30_000_000,
                  initial.sorted()[2] >= 100_000_000 else { throw Failure.invalid("writer requires actual 5/30/100MB files") }
            guard library.perfWatcherRunning else { throw Failure.invalid("real FSEvents watcher not running") }
            let roots = try library.perfWatchedPaths.map(pathURL)
            guard files.allSatisfy({ file in roots.contains(where: { file.pathComponents.starts(with: $0.pathComponents) }) }) else {
                throw Failure.invalid("writer files are outside actual watched roots")
            }
        }
        switch level {
        case "L1a": MacLeftPanelGroup.select(.chats)
        case "L1b", "background":
            IPadPanelLayout.shared.leftShown = true
            guard library.selectedKey == nil else { throw Failure.invalid("L1b/background requires fresh list-only process, not a restored/previous detail") }
            MacLeftPanelGroup.select(.code)
            await PerfHarnessMac.measure("M9.\(level).list", action: {}, condition: {
                anchors.contains { $0.key.hasPrefix("code:") && visible($0.key) }
            }, assertions: { library.isActive ? [] : ["Code list not open"] })
        case "L1c":
            IPadPanelLayout.shared.leftShown = true
            guard let key = spec.codeKey, let large = fixture.code.first(where: { $0.key == key }), files.contains(try pathURL(large.path)),
                  initial[files.firstIndex(of: try pathURL(large.path))!] >= 100_000_000 else { throw Failure.invalid("L1c must select the actively written 100MB fixture") }
            MacLeftPanelGroup.select(.code)
            await PerfHarnessMac.measure("M9.L1c.open", action: { library.select(key) }, condition: { codeReady(key) }, assertions: { codeReady(key) ? [] : ["L1c detail not loaded (baseline timeout is a failure reading)"] })
        case "L-term":
            guard let title = spec.terminalTitle, let marker = spec.terminalMarker, !marker.isEmpty,
                  let feed = files.first else { throw Failure.invalid("L-term requires R1-3 real ANSI feed/title/marker") }
            let handle = try FileHandle(forReadingFrom: feed)
            let preamble = try handle.read(upToCount: 65_536) ?? Data()
            try handle.close()
            let ansi = String(decoding: preamble, as: UTF8.self)
            guard ansi.contains("\u{1b}[2J"), ansi.contains("\u{1b}[H"), ansi.contains(marker) else {
                throw Failure.invalid("L-term feed lacks actual full-screen ANSI redraw/marker")
            }
            terminalID = LocalTerminalStore.shared.present(directory: BenchIsolation.root?.path,
                command: LocalTerminalLaunch.benchTUIFilePrefix + feed.path, title: title, origin: .shell)
            await PerfHarnessMac.measure("M9.L-term.start", action: {}, condition: {
                guard let session = LocalTerminalStore.shared.sessions.first(where: { $0.id == terminalID }) else { return false }
                return session.state == .running && session.screenText.contains(marker) && session.view.window != nil
            }, assertions: {
                LocalTerminalStore.shared.sessions.contains(where: { $0.id == terminalID && $0.state == .running })
                    ? [] : ["actual local-terminal PTY feed failed"]
            })
        case "L-io":
            guard let dose = spec.ioBytesPerSecond, dose > 0, initial.contains(where: { $0 >= 100_000_000 }) else {
                throw Failure.invalid("L-io requires a declared fixed byte/s dose and real large dose file")
            }
        case "L2": break
        default: throw Failure.invalid("unsupported load \(level)")
        }
        struct BridgeFrame: Decodable { let offset: Double; let text: String }
        var bridgeTask: Task<Void, Never>?
        var bridgeNode: MessageNode?
        var bridgeLastContent = ""
        var bridgeSent = 0
        var bridgeExpectedFinal: String?
        var bridgeExpectedCount = 0
        if level == "L2" {
            guard let path = spec.bridgeFramesPath, let id = spec.backgroundConversationID,
                  id != viewModel?.selectedConversation?.id else { throw Failure.invalid("L2 must target a non-current fixture conversation") }
            _ = try conversation(id)
            let frames = try JSONDecoder().decode([BridgeFrame].self, from: Data(contentsOf: pathURL(path)))
            guard let first = frames.first,
                  let firstObject = try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as? [String: Any],
                  let ccID = firstObject["mp_msg_id"] as? String, let context else { throw Failure.invalid("L2 missing message identity") }
            let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == id }))
            guard nodes.count >= 1800, CCBridgeWebSocketClient.shared.onEditMessage != nil,
                  let target = nodes.first(where: { $0.ccMessageId == ccID }),
                  target.profileId == profiles?.currentProfile.id else { throw Failure.invalid("L2 requires a real large same-floor background message and attached router edit handler") }
            bridgeNode = target
            bridgeLastContent = target.content
            guard frames.count >= 4000, frames.first?.offset == 0,
                  frames.last!.offset >= 599, frames.last!.offset <= 600 else { throw Failure.invalid("L2 requires a full 600s protocol frame fixture") }
            guard let finalFrame = frames.last,
                  let finalObject = try JSONSerialization.jsonObject(with: Data(finalFrame.text.utf8)) as? [String: Any],
                  let finalContent = finalObject["content"] as? String else { throw Failure.invalid("L2 final payload missing") }
            bridgeExpectedFinal = finalContent
            bridgeExpectedCount = frames.count
            for (index, frame) in frames.enumerated() {
                guard frame.offset >= 0, index == 0 || (frame.offset > frames[index - 1].offset && frame.offset - frames[index - 1].offset <= 0.2),
                      let object = try JSONSerialization.jsonObject(with: Data(frame.text.utf8)) as? [String: Any],
                      object["chat_id"] as? String == id, object["type"] as? String == "edit",
                      object["streaming"] as? Bool == true, object["mp_msg_id"] as? String == ccID,
                      (object["content"] as? String)?.isEmpty == false else { throw Failure.invalid("L2 frame cadence/protocol/target invalid") }
            }
            bridgeTask = Task { @MainActor in
                let start = CACurrentMediaTime()
                for frame in frames {
                    let delay = frame.offset - (CACurrentMediaTime() - start)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled else { return }
                    CCBridgeWebSocketClient.shared.handleIncoming(frame.text)
                    bridgeSent += 1
                }
            }
        }
        defer { bridgeTask?.cancel() }
        let activationTarget = anchors.keys.sorted().first { $0.hasPrefix("code:") && visible($0) }
        if level == "background" {
            await PerfHarnessMac.measure("M9.background.prepare", action: { NSApp.hide(nil) }, condition: {
                !NSApp.isActive && PerfHarnessMac.mainWindow?.occlusionState.contains(.visible) == false
            }, assertions: { NSApp.isActive ? ["background setup remained active"] : [] })
        }
        var lastSizes = try sizes()
        loadEvidence["\(level).windowInitialBytes"] = lastSizes.map(String.init).joined(separator: ",")
        var lastProgress = CACurrentMediaTime()
        var perFileProgress = Array(repeating: lastProgress, count: files.count)
        var lastTerminalText = ""
        var terminalProgress = CACurrentMediaTime()
        var failure = ""
        let loadStarted = CACurrentMediaTime()
        let ioBefore = level == "L-io" ? try loadIO(spec.pid) : nil
        var previousIO = ioBefore
        let watcherBefore = PerfCountMac.snapshot()["watcherBatch"] ?? 0
        let flushBefore = library.incrementalFlushCount
        let detailBefore = library.detailRevision
        var nextLoadCheck = 0.0
        loadEvidence["\(level).loadWitnessCadenceSeconds"] = "1"
        await PerfHarnessMac.observe("M9.\(level)", duration: 600, condition: {
            do {
                let now = CACurrentMediaTime()
                guard failure.isEmpty else { return false }
                if now < nextLoadCheck { return true }
                nextLoadCheck = now + 1
                guard kill(spec.pid, 0) == 0,
                      let date = try FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate] as? Date,
                      abs(date.timeIntervalSinceNow) <= 6 else { throw Failure.invalid("load PID/heartbeat expired") }
                let current = try sizes()
                if level == "L-io" {
                    let io = try loadIO(spec.pid)
                    if let previousIO, io.read > previousIO.read || io.written > previousIO.written { lastProgress = now }
                    previousIO = io
                } else if level == "L2" {
                    guard bridgeNode?.conversationId == spec.backgroundConversationID,
                          viewModel?.selectedConversation?.id != spec.backgroundConversationID else { throw Failure.invalid("L2 target became current or disappeared") }
                    if let content = bridgeNode?.content, content != bridgeLastContent {
                        bridgeLastContent = content; lastProgress = now
                    }
                } else {
                    for index in current.indices where current[index] != lastSizes[index] {
                        if ["L1a", "L1b", "L1c", "background"].contains(level) {
                            guard current[index] > lastSizes[index] else { throw Failure.invalid("writer truncated fixture") }
                            let delta = current[index] - lastSizes[index]
                            let batches = max(1, ceil((now - perFileProgress[index]) / 3))
                            guard delta >= 2048, Double(delta) <= 20480 * batches else {
                                throw Failure.invalid("writer append outside 2–20KiB per 3s fixture cadence")
                            }
                        }
                        perFileProgress[index] = now
                        lastProgress = now
                    }
                    if ["L1a", "L1b", "L1c", "background"].contains(level) {
                        guard perFileProgress.allSatisfy({ now - $0 <= 6 }) else { throw Failure.invalid("one writer session stopped appending") }
                    }
                    lastSizes = current
                }
                guard now - lastProgress <= 6 else { throw Failure.invalid("load produced no real file/message progress") }
                if level == "L1a" { guard !library.isActive && library.perfWatcherRunning else { throw Failure.invalid("L1a Code/watcher state wrong") } }
                if ["L1b", "L1c", "background"].contains(level) { guard library.isActive else { throw Failure.invalid("Code unexpectedly closed") } }
                if level == "L1c" { guard library.selectedKey == spec.codeKey else { throw Failure.invalid("L1c lost selected written session") } }
                if level == "background" { guard !NSApp.isActive, PerfHarnessMac.mainWindow?.occlusionState.contains(.visible) == false else { throw Failure.invalid("background requires nonactive AND occluded window") } }
                if level == "L-term" {
                    guard let session = LocalTerminalStore.shared.sessions.first(where: { $0.id == terminalID }), session.state == .running else { throw Failure.invalid("terminal exited") }
                    let text = session.screenText
                    if text != lastTerminalText { terminalProgress = now; lastTerminalText = text }
                    guard now - terminalProgress <= 3, Date().timeIntervalSince(session.view.lastOutput) <= 3 else { throw Failure.invalid("terminal lacks sustained TUI redraw/actual PTY bytes") }
                }
                return true
            } catch { failure = String(describing: error); return false }
        }, assertions: { failure.isEmpty ? [] : [failure] })
        loadEvidence["\(level).finalBytes"] = lastSizes.map(String.init).joined(separator: ",")
        loadEvidence["\(level).bridgeFramesDispatched"] = String(bridgeSent)
        loadEvidence["\(level).failure"] = failure
        if ["L1a", "L1b", "L1c", "background"].contains(level) {
            let watcherAfter = PerfCountMac.snapshot()["watcherBatch"] ?? 0
            loadEvidence["\(level).actualWatcherBatches"] = String(watcherAfter &- watcherBefore)
            guard watcherAfter > watcherBefore else { throw Failure.invalid("writer changed real files but no actual watcher batch arrived") }
        }
        if ["L1b", "L1c", "background"].contains(level) {
            guard library.incrementalFlushCount > flushBefore else { throw Failure.invalid("visible Code never applied a real incremental batch") }
        }
        if level == "L1c" {
            guard library.detailRevision > detailBefore else { throw Failure.invalid("actively written large detail never advanced its actual revision") }
        }
        if level == "L2" {
            await bridgeTask?.value
            await PerfHarnessMac.measure("M9.L2.final-apply", action: {}, condition: {
                bridgeSent == bridgeExpectedCount && bridgeNode?.content == bridgeExpectedFinal
            }, assertions: {
                bridgeSent == bridgeExpectedCount && bridgeNode?.content == bridgeExpectedFinal
                    ? [] : ["L2 router did not apply the full real protocol replay"]
            })
        }
        if level == "L-io", let ioBefore, let dose = spec.ioBytesPerSecond {
            let after = try loadIO(spec.pid)
            guard after.read >= ioBefore.read, after.written >= ioBefore.written else {
                throw Failure.invalid("L-io PID rusage counters reset")
            }
            let read = after.read &- ioBefore.read
            let written = after.written &- ioBefore.written
            let rate = Double(read + written) / max(1, CACurrentMediaTime() - loadStarted)
            loadEvidence["L-io.actualReadBytes"] = String(read)
            loadEvidence["L-io.actualWrittenBytes"] = String(written)
            loadEvidence["L-io.actualBytesPerSecond"] = String(rate)
            guard rate >= Double(dose) * 0.75, rate <= Double(dose) * 1.25 else {
                throw Failure.invalid("L-io actual PID rusage outside fixed dose ±25%")
            }
        }
        if level == "background" {
            let previous = actionSequence
            await PerfHarnessMac.measure("M9.background.activate-first-event", action: {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                PerfHarnessMac.mainWindow?.makeKeyAndOrderFront(nil)
                guard let activationTarget else { throw Failure.invalid("activation Code row not mounted") }
                try click(activationTarget)
            }, condition: { NSApp.isActive && actionSequence > previous }, assertions: {
                NSApp.isActive && actionSequence > previous ? [] : ["activation/first real event failed"]
            })
        }
    }
}

/// A non-hit-testing AppKit witness of the actual SwiftUI subtree. Registration is
/// disabled in ordinary Debug sessions; Release contains none of these symbols.
struct MacPerfAnchor: NSViewRepresentable {
    let key: String
    final class Witness: NSView {
        var key = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); PerfHarnessMacDriver.register(self, key: key) }
    }
    func makeNSView(context: Context) -> Witness { let view = Witness(); view.key = key; return view }
    func updateNSView(_ view: Witness, context: Context) { view.key = key; PerfHarnessMacDriver.register(view, key: key) }
}
#endif
