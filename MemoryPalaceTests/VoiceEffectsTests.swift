import XCTest
import ZIPFoundation
import AVFoundation
@testable import 记忆花园

private actor EffectSynthSpy {
    let clip: AudioClip
    private var words: [String] = []
    private var context: [VoiceSynthesisContext?] = []
    init(clip: AudioClip) { self.clip = clip }
    func synthesize(_ text: String, _ ctx: VoiceSynthesisContext?) -> AudioClip { words.append(text); context.append(ctx); return clip }
    func calls() -> [String] { words }
    func contexts() -> [VoiceSynthesisContext?] { context }
}

final class VoiceEffectsTests: XCTestCase {
    private var root: URL!
    private var library: VoiceEffectLibrary!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceEffectsTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root!
        library = VoiceEffectLibrary(base: { base.appendingPathComponent($0, isDirectory: true) },
                                     metadata: { base.appendingPathComponent("meta-\($0)", isDirectory: true) })
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        library = nil; root = nil
    }

    private func config(_ groups: [String: VoiceEffectGroupSettings], enabled: Bool = true) -> VoiceEffectConfiguration {
        var config = VoiceEffectConfiguration(); config.enabled = enabled; config.groups = groups
        return config
    }
    private var presets: VoiceEffectConfiguration {
        config(["亲吻": .init(mode: .insert, selected: ["x.wav"]), "水声": .init(mode: .bed, selected: ["y.wav"])])
    }

    func testExplicitCuesAndOrdinaryText() {
        let c = presets
        XCTAssertEqual(VoiceEffectScript.parts("亲一下，晚安。", configuration: c), [.speech("亲一下，晚安。", bed: nil)])
        XCTAssertEqual(VoiceEffectScript.parts("你好[sfx:kiss][sfx:water]晚安[/sfx:water]再见", configuration: c),
                       [.speech("你好", bed: nil), .insert("亲吻", kind: nil), .speech("晚安", bed: "水声"), .speech("再见", bed: nil)])
        // 别名 = 中文组名；不分大小写、两边空格忽略；种类跟在第二个冒号后
        XCTAssertEqual(VoiceEffectScript.parts("[SFX: Kiss ][sfx:亲吻:深][sfx:KISS: 轻 ]", configuration: c),
                       [.insert("亲吻", kind: nil), .insert("亲吻", kind: "深"), .insert("亲吻", kind: "轻")])
        XCTAssertEqual(VoiceEffectScript.textOnly("[softly]你好[sfx:unknown]晚安[sfx:ki"), "[softly]你好晚安")
        // 未知组 / 没配的组：吞掉不念不出声
        XCTAssertEqual(VoiceEffectScript.parts("你好[sfx:喘息]晚安[/sfx:喘息]", configuration: c),
                       [.speech("你好", bed: nil), .speech("晚安", bed: nil)])
    }

    func testOnlyOneBedAtATimeAndCallBedState() {
        var c = presets
        c.groups["雨声"] = .init(mode: .bed, selected: ["r.wav"])
        XCTAssertEqual(VoiceEffectScript.parts("a[sfx:雨声]b[sfx:water]c[/sfx:雨声]d[/sfx:水声]e", configuration: c),
                       [.speech("a", bed: nil), .speech("b", bed: "雨声"), .speech("c", bed: "水声"), .speech("d", bed: "水声"), .speech("e", bed: nil)])
        XCTAssertEqual(VoiceEffectScript.bedState(after: "[sfx:kiss]晚安", starting: "水声", configuration: c), "水声")
        XCTAssertNil(VoiceEffectScript.bedState(after: "[/sfx:water]", starting: "水声", configuration: c))
        XCTAssertEqual(VoiceEffectScript.bedState(after: "[sfx:雨声]", starting: "水声", configuration: c), "雨声")
        XCTAssertEqual(VoiceEffectScript.bedState(after: "[/sfx:水声]", starting: "雨声", configuration: c), "雨声")
        XCTAssertNil(VoiceEffectScript.bedState(after: "[sfx:未知]", starting: nil, configuration: c))
    }

    /// 金样：只有亲吻 / 水声、不分种类时三处文本逐字不变（10-08 改组前的原文）
    func testPromptGoldenTextUnchanged() {
        let head = "<本机音效>\n以下标记写在 voice 脚本中，由本机处理，不是要念的台词；缺素材时忽略，不要把标记解释成声音。\n"
        let kiss = "[sfx:kiss] 插入一段已选亲吻片段，一条最多一两下；它是独立片段，别用普通的亲字代替标记。\n"
        let water = "[sfx:water] 开始给后续台词垫水声，[/sfx:water] 结束；一条语音条最多垫一段水声，开一次关一次，不要整段都垫。\n"
        let callHead = "本通电话支持本机音效。标记写在普通回复里，不要包 voice 代码块，也不要念出标记。"
        let callKiss = " [sfx:kiss] 插入已选亲吻片段。", callWater = " [sfx:water] 给后续台词垫水声，[/sfx:water] 结束；缺素材就忽略。"
        let cases: [(kiss: Bool, water: Bool, prompt: String, call: String)] = [
            (true, false, head + kiss + "</本机音效>\n", callHead + callKiss),
            (false, true, head + water + "</本机音效>\n", callHead + callWater),
            (true, true, head + kiss + water + "</本机音效>\n", callHead + callKiss + callWater),
        ]
        let saved = (VoiceMessageWriter.serviceProvider, VoiceMessageWriter.serviceKeyProvider, VoiceMessageWriter.proactiveEnabledProvider)
        defer { (VoiceMessageWriter.serviceProvider, VoiceMessageWriter.serviceKeyProvider, VoiceMessageWriter.proactiveEnabledProvider) = saved }
        VoiceMessageWriter.serviceProvider = { $0 == "svc" ? VoiceService(id: $0, name: "服务", kind: .elevenLabs) : nil }
        VoiceMessageWriter.serviceKeyProvider = { _ in "k" }
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        var p = Profile(id: "p", name: "楼", emoji: "🌿", description: "", userName: "你", assistantName: "助手")
        p.voiceServiceId = "svc"; p.voiceId = "v"
        let base = VoicePromptInjector.ccInstructionsBlock(profile: p)
        for c in cases {
            var config = VoiceEffectConfiguration(); config.enabled = true; config.callEnabled = true
            if c.kiss { config.kissIDs = [UUID().uuidString, UUID().uuidString] }
            if c.water { config.waterID = UUID().uuidString }
            XCTAssertEqual(config.promptHint, c.prompt)
            XCTAssertEqual(config.callHint, c.call)
            p.voiceEffects = config
            XCTAssertEqual(VoicePromptInjector.ccInstructionsBlock(profile: p),
                           base + "\n" + c.prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- 通话：" + c.call)
            XCTAssertEqual(VoicePromptInjector.hint(profile: p),
                           String(VoicePromptInjector.tagsHintText.dropLast("</语音条>".count)) + c.prompt + "</语音条>")
            config.callEnabled = false
            XCTAssertNil(config.callHint)
            config.enabled = false
            XCTAssertNil(config.promptHint)
        }
        p.voiceEffects = nil
        XCTAssertEqual(VoicePromptInjector.hint(profile: p), VoicePromptInjector.tagsHintText)
    }

    func testPromptListsFreeGroupsAndKinds() {
        var c = config([
            "亲吻": .init(mode: .insert, selected: ["深/a.wav", "轻/b.wav", "c.wav"]),
            "喘息": .init(mode: .insert, selected: ["x.wav"]),
            "雨声": .init(mode: .bed, selected: ["r.wav"]),
            "空组": .init(mode: .insert),
        ])
        c.callEnabled = true
        XCTAssertEqual(c.promptHint, """
        <本机音效>
        以下标记写在 voice 脚本中，由本机处理，不是要念的台词；缺素材时忽略，不要把标记解释成声音。
        [sfx:kiss] 插入一段已选亲吻片段，一条最多一两下；它是独立片段，别用普通的亲字代替标记。可指定种类：[sfx:亲吻:深] [sfx:亲吻:轻]，不指定就随机。
        [sfx:喘息] 插入一段「喘息」音效，一条最多一两下。
        [sfx:雨声] 开始给后续台词垫「雨声」，[/sfx:雨声] 结束；一条最多垫一段，开一次关一次。
        </本机音效>

        """)
        XCTAssertEqual(c.callHint, "本通电话支持本机音效。标记写在普通回复里，不要包 voice 代码块，也不要念出标记。 [sfx:kiss] 插入已选亲吻片段。可指定种类：[sfx:亲吻:深] [sfx:亲吻:轻]，不指定就随机。 [sfx:喘息] 插入「喘息」音效。 [sfx:雨声] 给后续台词垫「雨声」，[/sfx:雨声] 结束。")
        // 亲吻被改成垫底：不再用 kiss 金样行
        c.groups = ["亲吻": .init(mode: .bed, selected: ["a.wav"])]
        XCTAssertTrue(c.promptHint!.contains("[sfx:亲吻] 开始给后续台词垫「亲吻」"))
    }

    func testDefaultsAndLegacyConfiguration() throws {
        let config = try JSONDecoder().decode(VoiceEffectConfiguration.self, from: Data("{}".utf8))
        XCTAssertFalse(config.enabled); XCTAssertFalse(config.callEnabled); XCTAssertNil(config.promptHint)
        var p = Profile(id: "p", name: "楼", emoji: "🌿", description: "", userName: "你", assistantName: "助手")
        p.voiceEffects = config
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p)).voiceEffects, config)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        old.removeValue(forKey: "voiceEffects")
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: old)).voiceEffects)
        // 老结构：kissIDs / waterID / waterDB 并进亲吻 / 水声；编码只写新结构
        let legacy = Data(#"{"enabled":true,"callEnabled":true,"kissIDs":["K1","K2"],"waterID":"W","waterDB":-12}"#.utf8)
        let decoded = try JSONDecoder().decode(VoiceEffectConfiguration.self, from: legacy)
        XCTAssertEqual(decoded.groups["亲吻"], VoiceEffectGroupSettings(mode: .insert, selected: ["K1", "K2"]))
        XCTAssertEqual(decoded.groups["水声"], VoiceEffectGroupSettings(mode: .bed, selected: ["W"], db: -12))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["enabled", "callEnabled", "groups"])
        XCTAssertEqual(try JSONDecoder().decode(VoiceEffectConfiguration.self, from: JSONEncoder().encode(decoded)), decoded)
        // 没选水声的老配置不凭空多出水声组；坏的用法值不拖垮整个楼层
        let noWater = try JSONDecoder().decode(VoiceEffectConfiguration.self, from: Data(#"{"waterDB":-18,"groups":{"雨声":{"mode":"???"}}}"#.utf8))
        XCTAssertNil(noWater.groups["水声"]); XCTAssertEqual(noWater.groups["雨声"]?.mode, .insert)
    }

    func testMixerRelativePeakAndHeadroomAndFade() {
        let mixed = VoiceEffectAudio.mix(Array(repeating: 0.5, count: 1000), water: [1], db: -6)
        XCTAssertEqual(mixed[500], 0.5 + 0.5 * Float(pow(10, -6.0 / 20)), accuracy: 0.001)
        let hot = VoiceEffectAudio.mix(Array(repeating: 0.9, count: 1000), water: [1], db: -6)
        XCTAssertLessThanOrEqual(hot.max() ?? 1, 0.9801)
        let faded = VoiceEffectAudio.faded(Array(repeating: Float(1), count: 1000))
        XCTAssertEqual(faded.first, 0); XCTAssertEqual(faded.last, 0); XCTAssertEqual(faded[500], 1)
        XCTAssertEqual(VoiceEffectAudio.mix([0.2], water: [], db: -18), [0.2])
    }

    func testImportNormalizesAndIsolatesFloorsAndDelete() async throws {
        let source = try fixture("脸颊轻亲")
        let item = try await library.importAudio(source, group: "亲吻", mode: .insert, profileID: "a")
        XCTAssertEqual(item.path, "脸颊轻亲.wav"); XCTAssertEqual(item.name, "脸颊轻亲")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/音效/亲吻/脸颊轻亲.wav").path))
        let found = try await library.groups(profileID: "a")
        XCTAssertEqual(found.map(\.name), ["水声", "亲吻"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(found.first { $0.name == "亲吻" }?.clips.map(\.path), ["脸颊轻亲.wav"])
        let other = try await library.groups(profileID: "b")
        XCTAssertTrue(other.allSatisfy(\.clips.isEmpty), "别的楼层只有空的预置组")
        let cross = try await library.clip(group: "亲吻", path: item.path, profileID: "b")
        XCTAssertNil(cross)
        let clip = try await library.clip(group: "亲吻", path: item.path, profileID: "a")
        let samples = try VoiceEffectAudio.canonicalSamples(XCTUnwrap(clip).data)
        XCTAssertEqual(Double(samples.count) / 24_000, 0.2, accuracy: 0.05)
        XCTAssertEqual(item.duration, Double(samples.count) / 24_000, accuracy: 0.001, "时长按文件大小算")
        XCTAssertEqual(samples.first, 0)
        // 重名加 (2)
        let again = try await library.importAudio(source, group: "亲吻", mode: .insert, profileID: "a")
        XCTAssertEqual(again.path, "脸颊轻亲 (2).wav")
        try await library.removeClip(group: "亲吻", path: item.path, profileID: "a")
        let removed = try await library.groups(profileID: "a")
        XCTAssertEqual(removed.first { $0.name == "亲吻" }?.clips.map(\.path), ["脸颊轻亲 (2).wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testInsertPicksKindFallsBackAndAvoidsRepeat() async throws {
        let deep1 = try await library.importAudio(fixture("d1", frequency: 220), group: "亲吻", kind: "深", mode: .insert, profileID: "p")
        let deep2 = try await library.importAudio(fixture("d2", frequency: 330), group: "亲吻", kind: "深", mode: .insert, profileID: "p")
        let light = try await library.importAudio(fixture("l1", frequency: 440), group: "亲吻", kind: "轻", mode: .insert, profileID: "p")
        XCTAssertEqual([deep1.path, light.path], ["深/d1.wav", "轻/l1.wav"])
        let lightClip = try await library.clip(group: "亲吻", path: light.path, profileID: "p")
        let lightData = try XCTUnwrap(lightClip).data
        let selected = [deep1.path, deep2.path, light.path]
        var previous: Data?
        for _ in 0..<8 {
            let picked = try await library.insert(group: "亲吻", kind: "深", selected: selected, profileID: "p")
            let pick = try XCTUnwrap(picked).data
            XCTAssertNotEqual(pick, lightData, "指定种类只从那个种类抽")
            if let previous { XCTAssertNotEqual(pick, previous) }
            previous = pick
        }
        // 种类一条没选 → 退回全组已选；种类名不分大小写
        let fallback = try await library.insert(group: "亲吻", kind: "没有", selected: [light.path], profileID: "p")
        XCTAssertEqual(fallback?.data, lightData)
        let none = try await library.insert(group: "亲吻", kind: nil, selected: [], profileID: "p")
        XCTAssertNil(none)
    }

    func testStereoInputIsReallyConvertedToMono24k() async throws {
        var pcm = Data()
        for i in 0..<3200 {
            let sample = Int16(sin(2 * .pi * 220 * Double(i) / 16_000) * 6000).littleEndian
            withUnsafeBytes(of: sample) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        let url = root.appendingPathComponent("stereo.wav")
        try AudioClip.wavWrapped(pcm16: pcm, sampleRate: 16_000, channels: 2).write(to: url)
        let samples = try await VoiceEffectAudio.decode(url, maxDuration: 1)
        XCTAssertEqual(Double(samples.count) / 24_000, 0.2, accuracy: 0.02)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.01)
    }

    func testConcurrentImportsOfSameNameBothLand() async throws {
        let a = try fixture("a"), library = self.library!
        async let first = library.importAudio(a, group: "亲吻", mode: .insert, profileID: "p")
        async let second = library.importAudio(a, group: "亲吻", mode: .insert, profileID: "p")
        let (one, two) = try await (first, second)
        XCTAssertEqual(Set([one.path, two.path]), ["a.wav", "a (2).wav"])
    }

    func testTooLongAndSilenceRejected() async throws {
        do {
            _ = try await library.importAudio(fixture("long", duration: 11), group: "亲吻", mode: .insert, profileID: "p")
            XCTFail("十秒以上的插入片段应拒绝")
        } catch { XCTAssertTrue(error is VoiceEffectError) }
        let bed = try await library.importAudio(fixture("long", duration: 11), group: "水声", mode: .bed, profileID: "p")
        XCTAssertEqual(bed.duration, 11, accuracy: 0.05, "垫底最多一分钟")
        let url = root.appendingPathComponent("silent.wav")
        try WAV.encode(Array(repeating: 0, count: 8000), sampleRate: 8000).write(to: url)
        do {
            _ = try await library.importAudio(url, group: "亲吻", mode: .insert, profileID: "p")
            XCTFail("静音素材应拒绝")
        } catch { XCTAssertTrue(error is VoiceEffectError) }
    }

    func testSymlinksAndPathEscapesRejected() async throws {
        let src = try fixture("a")
        _ = try await library.importAudio(src, group: "亲吻", mode: .insert, profileID: "p")
        let effects = root.appendingPathComponent("p/音效", isDirectory: true)
        // 组 / 种类 / 文件名里的 / 和 ..
        for bad in ["../x", "a/b", "..", ".hidden", "", "a:b", "x]"] {
            do { _ = try await library.createGroup(bad, profileID: "p"); XCTFail("组名 \(bad) 应拒绝") }
            catch { XCTAssertEqual(error as? VoiceEffectError, .badName) }
        }
        do { _ = try await library.importAudio(src, group: "../外面", mode: .insert, profileID: "p"); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceEffectError, .badName) }
        do { _ = try await library.importAudio(src, group: "亲吻", kind: "../深", mode: .insert, profileID: "p"); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceEffectError, .badName) }
        do { _ = try await library.moveClip(group: "亲吻", path: "a.wav", toKind: "../../x", profileID: "p"); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceEffectError, .badName) }
        let escaped = try await library.renameClip(group: "亲吻", path: "a.wav", to: "../../evil", profileID: "p")
        XCTAssertFalse(escaped.contains("/")); XCTAssertTrue(FileManager.default.fileExists(atPath: effects.appendingPathComponent("亲吻/\(escaped)").path))
        let outside = try await library.clip(group: "..", path: "p/音效/亲吻/\(escaped)", profileID: "p")
        XCTAssertNil(outside)
        let traversal = try await library.clip(group: "亲吻", path: "../../../a.wav", profileID: "p")
        XCTAssertNil(traversal)
        // 组里的软链文件 / 软链子文件夹都不认
        let foreign = root.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try canonicalWAV(seconds: 0.5).write(to: foreign.appendingPathComponent("x.wav"))
        try FileManager.default.createSymbolicLink(at: effects.appendingPathComponent("亲吻/link.wav"), withDestinationURL: foreign.appendingPathComponent("x.wav"))
        try FileManager.default.createSymbolicLink(at: effects.appendingPathComponent("亲吻/深"), withDestinationURL: foreign)
        try FileManager.default.createSymbolicLink(at: effects.appendingPathComponent("链接组"), withDestinationURL: foreign)
        let groups = try await library.groups(profileID: "p")
        XCTAssertEqual(groups.first { $0.name == "亲吻" }?.clips.map(\.path), [escaped])
        XCTAssertFalse(groups.contains { $0.name == "链接组" })
        let viaLink = try await library.clip(group: "亲吻", path: "link.wav", profileID: "p")
        XCTAssertNil(viaLink)
        let viaKindLink = try await library.clip(group: "亲吻", path: "深/x.wav", profileID: "p")
        XCTAssertNil(viaKindLink)
        // 整个「音效」是链接 → 整区拒绝
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("音效"), withDestinationURL: effects)
        do { _ = try await library.groups(profileID: "other"); XCTFail("拒绝跨目录链接") }
        catch { XCTAssertTrue(error is VoiceEffectError) }
    }

    func testScanFollowsExternalRenameDeleteAndConvertsForeignAudio() async throws {
        let item = try await library.importAudio(fixture("原名"), group: "亲吻", mode: .insert, profileID: "p")
        let effects = root.appendingPathComponent("p/音效", isDirectory: true)
        let fm = FileManager.default
        // 外面改名 / 新建文件夹 / 丢进别的格式
        try fm.moveItem(at: effects.appendingPathComponent("亲吻/\(item.path)"), to: effects.appendingPathComponent("亲吻/新名.wav"))
        try fm.createDirectory(at: effects.appendingPathComponent("雨声/夜"), withIntermediateDirectories: true)
        try fm.copyItem(at: fixture("rain", duration: 12), to: effects.appendingPathComponent("雨声/夜/rain.wav"))  // 8k，非标准
        try fm.createDirectory(at: effects.appendingPathComponent("喘息"), withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: effects.appendingPathComponent("喘息/坏.mp3"))
        try fm.copyItem(at: fixture("太长", duration: 61), to: effects.appendingPathComponent("喘息/太长.wav"))
        try canonicalWAV(seconds: 70).write(to: effects.appendingPathComponent("喘息/超长标准.wav"))
        try Data("笔记".utf8).write(to: effects.appendingPathComponent("喘息/说明.md"))
        try cafFixture(effects.appendingPathComponent("喘息/短.caf"))
        let groups = try await library.groups(profileID: "p")
        let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
        XCTAssertEqual(byName["亲吻"]?.clips.map(\.path), ["新名.wav"])
        let rain = try XCTUnwrap(byName["雨声"]?.clips.first)
        XCTAssertEqual(rain.path, "夜/rain.wav"); XCTAssertNil(rain.issue); XCTAssertEqual(rain.duration, 12, accuracy: 0.05)
        XCTAssertEqual(byName["雨声"]?.guessedMode, .bed, "最长那段 > 10 秒 → 垫底")
        let header = try Data(contentsOf: effects.appendingPathComponent("雨声/夜/rain.wav")).prefix(44)
        XCTAssertNotNil(VoiceEffectAudio.canonicalDuration(header: header, fileSize: rain.byteCount), "就地转成标准 WAV")
        let breath = try XCTUnwrap(byName["喘息"])
        XCTAssertEqual(Set(breath.clips.map(\.path)), ["坏.mp3", "太长.wav", "超长标准.wav", "短.wav"])
        XCTAssertNotNil(breath.clips.first { $0.path == "坏.mp3" }?.issue)
        XCTAssertNotNil(breath.clips.first { $0.path == "太长.wav" }?.issue)
        XCTAssertNotNil(breath.clips.first { $0.path == "超长标准.wav" }?.issue)
        XCTAssertNil(breath.clips.first { $0.path == "短.wav" }?.issue)
        XCTAssertFalse(fm.fileExists(atPath: effects.appendingPathComponent("喘息/短.caf").path), "转换后原件删掉")
        XCTAssertEqual(breath.guessedMode, .insert)
        // 外面删掉：不报错，只是少了
        try fm.removeItem(at: effects.appendingPathComponent("亲吻/新名.wav"))
        let after = try await library.groups(profileID: "p")
        XCTAssertEqual(after.first { $0.name == "亲吻" }?.clips, [])
        let gone = try await library.clip(group: "亲吻", path: "新名.wav", profileID: "p")
        XCTAssertNil(gone)
    }

    func testGroupAndClipManagement() async throws {
        let created = try await library.createGroup(" 喘息 ", profileID: "p")
        XCTAssertEqual(created, "喘息")
        do { _ = try await library.createGroup("喘息", profileID: "p"); XCTFail("同名组") }
        catch { XCTAssertEqual(error as? VoiceEffectError, .exists) }
        let clip = try await library.importAudio(fixture("x"), group: "喘息", mode: .insert, profileID: "p")
        let renamed = try await library.renameGroup("喘息", to: "呼吸", profileID: "p")
        XCTAssertEqual(renamed, "呼吸")
        let moved = try await library.moveClip(group: "呼吸", path: clip.path, toKind: "急", profileID: "p")
        XCTAssertEqual(moved, "急/x.wav")
        let named = try await library.renameClip(group: "呼吸", path: moved, to: "急促", profileID: "p")
        XCTAssertEqual(named, "急/急促.wav")
        let back = try await library.moveClip(group: "呼吸", path: named, toKind: nil, profileID: "p")
        XCTAssertEqual(back, "急促.wav")
        var groups = try await library.groups(profileID: "p")
        XCTAssertEqual(groups.first { $0.name == "呼吸" }?.kinds, ["急"], "空种类文件夹留着")
        try await library.removeGroup("呼吸", profileID: "p")
        groups = try await library.groups(profileID: "p")
        XCTAssertFalse(groups.contains { $0.name == "呼吸" })
        XCTAssertEqual(groups.map(\.name).sorted(), ["水声", "亲吻"].sorted(), "第一次建「音效」顺手建好预置两组")
        // 上限：16 组、每组 64 段
        for i in groups.count..<VoiceEffectLibrary.maxGroups { _ = try await library.createGroup("组\(i)", profileID: "p") }
        do { _ = try await library.createGroup("再一组", profileID: "p"); XCTFail("最多 16 组") }
        catch { XCTAssertEqual(error as? VoiceEffectError, .full) }
        let full = root.appendingPathComponent("p/音效/亲吻", isDirectory: true)
        let wav = canonicalWAV(seconds: 0.1)
        for i in 0..<VoiceEffectLibrary.maxClipsPerGroup { try wav.write(to: full.appendingPathComponent("\(i).wav")) }
        do { _ = try await library.importAudio(fixture("多"), group: "亲吻", mode: .insert, profileID: "p"); XCTFail("每组最多 64 段") }
        catch { XCTAssertEqual(error as? VoiceEffectError, .full) }
        try wav.write(to: full.appendingPathComponent("zz-外面多放的.wav"))
        let scanned = try await library.groups(profileID: "p")
        XCTAssertEqual(scanned.first { $0.name == "亲吻" }?.clips.filter { $0.issue != nil }.count, 1)
    }

    func testLegacyManifestMigratesFilesAndConfig() async throws {
        let old = root.appendingPathComponent("p/voice-effects", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let k1 = UUID().uuidString, k2 = UUID().uuidString, w = UUID().uuidString, ghost = UUID().uuidString
        let kissData = canonicalWAV(seconds: 0.3, frequency: 300), waterData = canonicalWAV(seconds: 2, frequency: 70)
        try kissData.write(to: old.appendingPathComponent(k1 + ".wav"))
        try canonicalWAV(seconds: 0.4).write(to: old.appendingPathComponent(k2 + ".wav"))
        try waterData.write(to: old.appendingPathComponent(w + ".wav"))
        try Data("orphan".utf8).write(to: old.appendingPathComponent("清单外.wav"))
        let manifest: [String: Any] = ["version": 1, "assets": [
            ["id": k1, "name": "亲1-脸颊轻亲", "kind": "kiss", "sourceNote": "", "duration": 0.3, "byteCount": kissData.count],
            ["id": k2, "name": "亲1-脸颊轻亲", "kind": "kiss", "sourceNote": "", "duration": 0.4, "byteCount": 1],
            ["id": w, "name": "水声1-海绵咕啾", "kind": "water", "sourceNote": "", "duration": 2, "byteCount": waterData.count],
            ["id": ghost, "name": "早没了", "kind": "kiss", "sourceNote": "", "duration": 1, "byteCount": 1],
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: old.appendingPathComponent("manifest.json"))
        // 模拟上次迁到一半：同名同内容的已经在新位置了 → 复用，不多出 (2)
        let kissDir = root.appendingPathComponent("p/音效/亲吻", isDirectory: true)
        try FileManager.default.createDirectory(at: kissDir, withIntermediateDirectories: true)
        try kissData.write(to: kissDir.appendingPathComponent("亲1-脸颊轻亲.wav"))

        let groups = try await library.groups(profileID: "p")
        let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName["亲吻"]?.clips.map(\.path) ?? []), ["亲1-脸颊轻亲.wav", "亲1-脸颊轻亲 (2).wav"])
        XCTAssertEqual(byName["水声"]?.clips.map(\.path), ["水声1-海绵咕啾.wav"])
        let table = await library.legacyMap(profileID: "p")
        XCTAssertEqual(table, [k1: "亲吻/亲1-脸颊轻亲.wav", k2: "亲吻/亲1-脸颊轻亲 (2).wav", w: "水声/水声1-海绵咕啾.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("meta-p/voice-effects-legacy.json").path))
        // 清单里的搬走、清单删掉；清单外的文件不动，所以旧目录还在
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.path), ["清单外.wav"])

        // 老配置（UUID 引用）照样能播
        var legacyConfig = VoiceEffectConfiguration(); legacyConfig.enabled = true
        legacyConfig.kissIDs = [k1]; legacyConfig.waterID = w
        let kiss = try await library.insert(group: "亲吻", kind: nil, selected: legacyConfig.kissIDs, profileID: "p")
        XCTAssertEqual(kiss?.data, kissData)
        let water = try await library.clip(group: "水声", path: w, profileID: "p")
        XCTAssertEqual(water?.data, waterData)
        let wrongGroup = try await library.clip(group: "亲吻", path: w, profileID: "p")
        XCTAssertNil(wrongGroup, "UUID 只认原来那一组")

        // 新开一个库实例（下次启动）：不重复迁移
        let base = root!
        let reopened = VoiceEffectLibrary(base: { base.appendingPathComponent($0, isDirectory: true) },
                                          metadata: { base.appendingPathComponent("meta-\($0)", isDirectory: true) })
        let again = try await reopened.groups(profileID: "p")
        XCTAssertEqual(again.first { $0.name == "亲吻" }?.clips.count, 2)
        let reopenedTable = await reopened.legacyMap(profileID: "p")
        XCTAssertEqual(reopenedTable, table)
    }

    func testLegacyMigrationFullyCleansAndBrokenManifestIsLeftAlone() async throws {
        let old = root.appendingPathComponent("p/voice-effects", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try canonicalWAV(seconds: 0.3).write(to: old.appendingPathComponent(id + ".wav"))
        let manifest: [String: Any] = ["version": 1, "assets": [["id": id, "name": "亲", "kind": "kiss", "sourceNote": "", "duration": 0.3, "byteCount": 1]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: old.appendingPathComponent("manifest.json"))
        _ = try await library.groups(profileID: "p")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "全搬完旧目录删掉")

        let broken = root.appendingPathComponent("q/voice-effects", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let junk = Data("broken".utf8)
        try junk.write(to: broken.appendingPathComponent("manifest.json"))
        try canonicalWAV(seconds: 0.3).write(to: broken.appendingPathComponent(UUID().uuidString + ".wav"))
        let groups = try await library.groups(profileID: "q")
        XCTAssertEqual(groups.map(\.clips.count), [0, 0], "清单坏了不迁，音效区照常")
        XCTAssertEqual(try Data(contentsOf: broken.appendingPathComponent("manifest.json")), junk)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: broken.path).count, 2, "一个文件都不动")
    }

    func testDisabledOrMissingAssetsPreservesBytesAndNeverSendsCues() async throws {
        let original = AudioClip(data: Data("opaque-audio".utf8), format: .mp3)
        let spy = EffectSynthSpy(clip: original)
        let off = try await VoiceEffectsRenderer.render("[softly]你好[sfx:kiss]晚安", configuration: .init(), profileID: "p", library: library) { await spy.synthesize($0, $1) }
        XCTAssertEqual(off, original)
        var config = VoiceEffectConfiguration(); config.enabled = true; config.kissIDs = [UUID().uuidString]
        let missing = try await VoiceEffectsRenderer.render("你好[sfx:kiss]晚安", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        XCTAssertEqual(missing, original)
        let unknown = try await VoiceEffectsRenderer.render("你好[sfx:喘息]晚安", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        XCTAssertEqual(unknown, original)
        let calls = await spy.calls()
        XCTAssertEqual(calls, ["[softly]你好晚安", "你好晚安", "你好晚安"])
    }

    func testPureKissMakesNoTTSRequestAndCompositeContainsBothTracks() async throws {
        let kiss = try await library.importAudio(fixture("kiss"), group: "亲吻", mode: .insert, profileID: "p")
        let water = try await library.importAudio(fixture("water", duration: 0.1, frequency: 70), group: "水声", mode: .bed, profileID: "p")
        let config = config(["亲吻": .init(mode: .insert, selected: [kiss.path]), "水声": .init(mode: .bed, selected: [water.path])])
        let voice = WAV.encode(Array(repeating: Float(0.3), count: 6000), sampleRate: 24_000)
        let spy = EffectSynthSpy(clip: AudioClip(data: voice, format: .wav))
        let only = try await VoiceEffectsRenderer.render("[sfx:kiss]", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        let initialCalls = await spy.calls()
        XCTAssertTrue(initialCalls.isEmpty); XCTAssertGreaterThan(only.data.count, 44)
        let mixed = try await VoiceEffectsRenderer.render("你好[sfx:kiss][sfx:water]晚安[/sfx:water]", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        let samples = try VoiceEffectAudio.canonicalSamples(mixed.data)
        XCTAssertEqual(Double(samples.count) / 24_000, 0.7, accuracy: 0.05)
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 1, 0.99)
        let calls = await spy.calls()
        XCTAssertEqual(calls, ["你好", "晚安"])
    }

    func testSegmentedSpeechPassesNeighborContextAndLeavesGap() async throws {
        let kiss = try await library.importAudio(fixture("kiss"), group: "亲吻", mode: .insert, profileID: "p")
        let water = try await library.importAudio(fixture("water", duration: 0.1, frequency: 70), group: "水声", mode: .bed, profileID: "p")
        let config = config(["亲吻": .init(mode: .insert, selected: [kiss.path]), "水声": .init(mode: .bed, selected: [water.path])])
        let voice = WAV.encode(Array(repeating: Float(0.3), count: 6000), sampleRate: 24_000)
        let spy = EffectSynthSpy(clip: AudioClip(data: voice, format: .wav))
        let gap = VoiceEffectsRenderer.speechGap
        XCTAssertEqual(gap, 2880, "120ms @24k")

        // 未知标记把台词切成两段干声：段间是纯静音，不再硬接
        let dry = try await VoiceEffectsRenderer.render("你好[sfx:pause]晚安[sfx:kiss]", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        let d = try VoiceEffectAudio.canonicalSamples(dry.data)
        XCTAssertTrue(d[6000..<6000 + gap].allSatisfy { $0 == 0 })
        XCTAssertNotEqual(d[5998], 0); XCTAssertNotEqual(d[6000 + gap + 1], 0)
        let contexts = await spy.contexts()
        XCTAssertEqual(contexts, [VoiceSynthesisContext(previous: nil, next: "晚安"), VoiceSynthesisContext(previous: "你好", next: nil)])

        // 干声 → 水声：静音归水声那侧，接缝里垫着水声
        let wet = try await VoiceEffectsRenderer.render("你好[sfx:water]晚安[/sfx:water]", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        let w = try VoiceEffectAudio.canonicalSamples(wet.data)
        XCTAssertEqual(w.count, 6000 * 2 + gap)
        XCTAssertGreaterThan(w[6000..<6000 + gap].filter { $0 != 0 }.count, gap / 2)
    }

    func testSwitchingBedBreaksRunAndUsesEachGroupsVolume() async throws {
        let rain = try await library.importAudio(fixture("rain", duration: 0.1, frequency: 90), group: "雨声", mode: .bed, profileID: "p")
        let water = try await library.importAudio(fixture("water", duration: 0.1, frequency: 70), group: "水声", mode: .bed, profileID: "p")
        let config = config(["雨声": .init(mode: .bed, selected: [rain.path], db: -6), "水声": .init(mode: .bed, selected: [water.path], db: -30)])
        let voice = WAV.encode(Array(repeating: Float(0.3), count: 6000), sampleRate: 24_000)
        let spy = EffectSynthSpy(clip: AudioClip(data: voice, format: .wav))
        let out = try await VoiceEffectsRenderer.render("[sfx:雨声]你好[sfx:水声]晚安[/sfx:水声]", configuration: config, profileID: "p", library: library) { await spy.synthesize($0, $1) }
        let s = try VoiceEffectAudio.canonicalSamples(out.data)
        let gap = VoiceEffectsRenderer.speechGap
        XCTAssertEqual(s.count, 6000 * 2 + gap)
        // 段中间（避开淡入淡出）离 0.3 的偏差：雨声 −6 dB 大，水声 −30 dB 小
        let swing = { (r: Range<Int>) in s[r].map { abs($0 - 0.3) }.max() ?? 0 }
        XCTAssertGreaterThan(swing(1000..<5000), 0.1)
        XCTAssertLessThan(swing((6000 + gap + 1000)..<(6000 + gap + 5000)), 0.02)
        // 换垫底断开另起一串：前一串在接缝处淡出到 0
        XCTAssertEqual(s[6000 + gap - 1], 0, accuracy: 0.001)
    }

    func testCancelledImportDoesNotCommitAsset() async throws {
        let url = try fixture("cancel", duration: 1), library = self.library!
        let job = Task {
            try Task.checkCancellation()
            return try await library.importAudio(url, group: "亲吻", mode: .insert, profileID: "p")
        }
        job.cancel()
        do { _ = try await job.value; XCTFail("已取消的导入不应成功") }
        catch { XCTAssertTrue(error is CancellationError) }
        let groups = try await library.groups(profileID: "p")
        XCTAssertTrue(groups.allSatisfy(\.clips.isEmpty))
    }

    func testGateDoesNotCutControlMarkerAtColonOrLengthBoundary() {
        var gate = StreamSpeechGate()
        let script = String(repeating: "啊", count: 209) + "[sfx:kiss]" + String(repeating: "好", count: 40)
        let released = gate.feed(script) + gate.flush()
        XCTAssertTrue(released.contains(where: { $0.contains("[sfx:kiss]") }))
        XCTAssertFalse(released.contains(where: { $0.hasSuffix("[sfx:") || $0.hasPrefix("kiss]") }))
    }

    func testZipExtractsOnlyAudioAndImportsEach() async throws {
        let wav = try Data(contentsOf: fixture("src"))
        let zip = try makeZip("pack", [("素材/亲亲一.wav", wav), ("b.WAV", wav), ("__MACOSX/素材/._亲亲一.wav", Data("x".utf8)),
                                       (".hidden.wav", wav), ("readme.txt", Data("hi".utf8))])
        let out = root.appendingPathComponent("out", isDirectory: true)
        let entries = try VoiceEffectZip.extractAudioEntries(zip, to: out)
        XCTAssertEqual(entries.map(\.url.lastPathComponent).sorted(), ["b.WAV", "亲亲一.wav"])
        XCTAssertTrue(entries.allSatisfy { $0.url.path.hasPrefix(out.path + "/") })
        let kinds = VoiceEffectZip.kinds(entries.map(\.path))
        for (index, entry) in entries.enumerated() {
            _ = try await library.importAudio(entry.url, group: "亲吻", kind: kinds[index], mode: .insert, profileID: "z")
        }
        let paths = try await library.groups(profileID: "z").first { $0.name == "亲吻" }?.clips.map(\.path).sorted()
        XCTAssertEqual(paths, ["b.wav", "素材/亲亲一.wav"])
    }

    func testZipKindsKeepOneLevelAndStripWrapperFolder() {
        XCTAssertEqual(VoiceEffectZip.kinds(["pack/深/a.wav", "pack/轻/b.wav"]), ["深", "轻"])
        XCTAssertEqual(VoiceEffectZip.kinds(["亲吻/a.wav", "亲吻/b.wav"]), [nil, nil], "Finder 压缩整个文件夹：外层不算种类")
        XCTAssertEqual(VoiceEffectZip.kinds(["深/a.wav", "c.wav", "x/y/z.wav", "../d.wav"]), ["深", nil, nil, nil])
    }

    func testZipRejectsPathEscapeAndCaps() throws {
        let wav = try Data(contentsOf: fixture("src"))
        let out = root.appendingPathComponent("out", isDirectory: true)
        let slip = try makeZip("slip", [("ok.wav", wav), ("../evil.wav", wav)])
        XCTAssertThrowsError(try VoiceEffectZip.extractAudio(slip, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.wav").path))
        let many = try makeZip("many", [("1.wav", wav), ("2.wav", wav), ("3.wav", wav)])
        XCTAssertThrowsError(try VoiceEffectZip.extractAudio(many, to: root.appendingPathComponent("o2"), maxCount: 2))
        XCTAssertThrowsError(try VoiceEffectZip.extractAudio(many, to: root.appendingPathComponent("o3"), maxBytes: wav.count * 2))
        XCTAssertThrowsError(try VoiceEffectZip.extractAudio(fixture("notzip"), to: root.appendingPathComponent("o4")))
    }

    private func makeZip(_ name: String, _ entries: [(String, Data)]) throws -> URL {
        let url = root.appendingPathComponent(name + ".zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }
        return url
    }

    private func fixture(_ name: String, duration: Double = 0.2, sampleRate: Int = 8000, frequency: Double = 220) throws -> URL {
        let url = root.appendingPathComponent(name + ".wav")
        let samples = (0..<Int(duration * Double(sampleRate))).map { Float(sin(2 * .pi * frequency * Double($0) / Double(sampleRate))) * 0.3 }
        try WAV.encode(samples, sampleRate: sampleRate).write(to: url)
        return url
    }

    /// 真正的非 WAV 容器（CAF），扫描时应就地转成标准 WAV
    private func cafFixture(_ url: URL, seconds: Double = 0.2) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 8000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 220 * Double(i) / 8000)) * 0.3 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// 我们自己写出的那种 24k 单声道 PCM16
    private func canonicalWAV(seconds: Double, frequency: Double = 220) -> Data {
        WAV.encode((0..<Int(seconds * 24_000)).map { Float(sin(2 * .pi * frequency * Double($0) / 24_000)) * 0.3 }, sampleRate: 24_000)
    }
}
