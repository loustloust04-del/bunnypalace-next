import XCTest
import AVFoundation
import Speech

/// T0 spike（plan-voice-call）：SpeechAnalyzer zh-CN 文件转写——
/// 验证 ①locale 支持 ②AssetInventory 资产下载 ③volatile/final 结果语义。
/// 纯系统 API 探针，不 import app 模块；live-mic（自动重启/AudioSession）在 CallTranscriber 阶段真机验。
/// 音频用 `say` 现场生成，不进仓库。
final class SpeechAnalyzerSpikeTests: XCTestCase {

    func testZhCNFileTranscription() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer 需要 macOS 26") }

        // 1. 生成中文测试音频
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-zh-\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Eddy (Chinese (China mainland))", "-o", tmp.path, "今天天气真好，我们一起听一首歌吧。"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say 生成音频失败，跳过") }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 2. locale 支持
        let supported = await SpeechTranscriber.supportedLocales
        print("[SPIKE] supportedLocales: \(supported.map(\.identifier).sorted())")
        guard supported.contains(where: { $0.identifier.hasPrefix("zh") }) else {
            XCTFail("zh 不在 SpeechTranscriber.supportedLocales——T0 出口条件失败，改走 SFSpeechRecognizer")
            return
        }

        // 3. 建 transcriber + 资产
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "zh_CN"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("[SPIKE] 资产缺失，开始下载…")
            try await req.downloadAndInstall()
            print("[SPIKE] 资产下载完成")
        } else {
            print("[SPIKE] 资产已就绪")
        }

        // 4. 文件分析：results 消费与 analyzeSequence 并行
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: tmp)

        let collector = Task { () -> (finals: [String], volatileCount: Int) in
            var finals: [String] = []
            var volatileCount = 0
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finals.append(text)
                    print("[SPIKE] FINAL: \(text)")
                } else {
                    volatileCount += 1
                    print("[SPIKE] volatile: \(text)")
                }
            }
            return (finals, volatileCount)
        }

        if let last = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let (finals, volatileCount) = try await collector.value
        print("[SPIKE] finals=\(finals) volatiles=\(volatileCount)")
        let joined = finals.joined()
        XCTAssertFalse(joined.isEmpty, "应产出非空最终转写")
        XCTAssertTrue(joined.contains("天气") || joined.contains("听") || joined.contains("歌"),
                      "转写内容应命中关键词，实际：\(joined)")
    }
}
