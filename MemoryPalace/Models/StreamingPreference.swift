import SwiftUI

/// 流式输出三档（设置 › API › 回复方式，权限页同款下拉行）：
/// 流式 = 请求 stream:true 边生成边显示；假流式 = 请求 stream:false 整包回来后按节奏打字显示（中转掐不断）；
/// 关闭 = 请求 stream:false 整包一次显示。与预设里的 `sampling.streaming`（酒馆 stream_openai）是
/// "任一非流式即非流式请求"，不是两个独立开关。非流式回包处理见 research-nonstream-chat。
enum StreamingMode: String, CaseIterable, Identifiable {
    case stream, paced, off
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stream: return "流式"
        case .paced: return "假流式"
        case .off: return "关闭流式"
        }
    }
    var iconName: String {
        switch self {
        case .stream: return "waveform"
        case .paced: return "keyboard"
        case .off: return "doc.plaintext"
        }
    }
    var summary: String {
        switch self {
        case .stream: return "边生成边显示"
        case .paced: return "等整段生成完再打字显示，不会被中转掐断"
        case .off: return "等整段生成完一次显示"
        }
    }
}

enum StreamingPreference {
    static let key = "streamingMode"

    static var mode: StreamingMode {
        get { StreamingMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .stream }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 请求侧：非流式档位把预设的 streaming 压成 false
    static func apply(_ p: SamplingParams) -> SamplingParams {
        guard mode != .stream else { return p }
        var q = p
        q.streaming = false
        return q
    }

    /// 显示侧：整包回来后一次显示还是打字显示
    static var instantDisplay: Bool { mode == .off }
}

/// 设置行（等待动画行同款，见 SettingsValueRowLabel）
struct StreamingModeRow: View {
    let fontSize: CGFloat
    let valueSize: CGFloat
    @AppStorage(StreamingPreference.key) private var modeRaw = StreamingMode.stream.rawValue

    private var mode: StreamingMode { StreamingMode(rawValue: modeRaw) ?? .stream }

    var body: some View {
        Menu {
            Picker("", selection: $modeRaw) {
                ForEach(StreamingMode.allCases) { m in
                    Label(m.displayName, systemImage: m.iconName).tag(m.rawValue)
                }
            }
        } label: {
            SettingsValueRowLabel(title: "流式输出", value: mode.displayName, fontSize: fontSize, valueSize: valueSize)
        }
        .buttonStyle(.plain)
    }
}
