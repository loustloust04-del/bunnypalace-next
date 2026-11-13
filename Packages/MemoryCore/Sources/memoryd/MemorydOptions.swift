import Foundation

struct MemorydOptions: Equatable {
    var floor: URL
    var port: UInt16 = 8765
    var profileId: String = "memoryd"
    /// 测试 / 夹具用：目录不是 `memoryd-mount.sh` 拷出来的也照挂
    var allowUnmounted: Bool = false
    /// 要调模型的写手用哪个模型；key 走环境变量 `MEMORYD_MODEL_KEY`，不走参数
    var model: String? = nil
    /// 打分用的裁判模型；key 走 `MEMORYD_JUDGE_KEY`
    var judgeModel: String? = nil

    static let usage = """
    用法：memoryd --floor <楼层目录> [--port 8765] [--profile-id <id>] [--model <模型 id>] [--judge-model <模型 id>] [--allow-unmounted]

      --floor            必填，挂载的 memory/ 目录副本（里面有 wiki/、windows/、sessions/、timeline/…）
      --port             默认 8765；0 = 让系统分配
      --profile-id       默认 memoryd
      --model            要调模型的写手（C2）用哪个模型；key 从环境变量 MEMORYD_MODEL_KEY 读，
                         接口地址默认 Anthropic 官方，MEMORYD_MODEL_URL 可改。不给 = 不调模型
                         OpenAI 兼容接口（DeepSeek 这类）：MEMORYD_MODEL_WIRE=openai，地址必须给
      --judge-model      给碎片打分的裁判模型；对应 MEMORYD_JUDGE_KEY / MEMORYD_JUDGE_URL / MEMORYD_JUDGE_WIRE
      --allow-unmounted  不是 memoryd-mount.sh 做的副本也照挂（只给测试 / 夹具）

    recall 题（recall-24）按 America/Los_Angeles 记忆日重放；宿主时区不符时整份 run 记不可测。
    用 TZ=America/Los_Angeles 启动 memoryd。
    """

    enum ParseError: LocalizedError, Equatable {
        case missingFloor
        case unknown(String)
        case missingValue(String)
        case badPort(String)
        case notDirectory(String)
        case help

        var errorDescription: String? {
            switch self {
            case .missingFloor: return "缺 --floor <楼层目录>"
            case .unknown(let arg): return "不认识的参数：\(arg)"
            case .missingValue(let arg): return "\(arg) 后面缺值"
            case .badPort(let value): return "端口不是数字：\(value)"
            case .notDirectory(let path): return "--floor 不是目录：\(path)"
            case .help: return MemorydOptions.usage
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> MemorydOptions {
        var floor: String?
        var port: UInt16 = 8765
        var profileId: String? = nil
        var allowUnmounted = false
        var model: String? = nil
        var judgeModel: String? = nil
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                throw ParseError.help
            case "--allow-unmounted":
                allowUnmounted = true
                index += 1
            case "--floor":
                guard index + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                floor = arguments[index + 1]
                index += 2
            case "--port":
                guard index + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                let raw = arguments[index + 1]
                guard let value = UInt16(raw) else { throw ParseError.badPort(raw) }
                port = value
                index += 2
            case "--model":
                guard index + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                model = arguments[index + 1]
                index += 2
            case "--judge-model":
                guard index + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                judgeModel = arguments[index + 1]
                index += 2
            case "--profile-id":
                guard index + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                profileId = arguments[index + 1]
                index += 2
            default:
                throw ParseError.unknown(arg)
            }
        }
        guard let floor else { throw ParseError.missingFloor }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: floor, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ParseError.notDirectory(floor)
        }
        let url = URL(fileURLWithPath: floor, isDirectory: true).standardizedFileURL
        // 目录名能认就用它（`<楼层>/memory/` 取楼层名；副本目录取副本名），认不出用 memoryd
        var inferred = url.lastPathComponent
        if inferred == "memory" {
            inferred = url.deletingLastPathComponent().lastPathComponent
        }
        if inferred.isEmpty || inferred == "/" { inferred = "memoryd" }
        let resolved = (profileId?.isEmpty == false ? profileId : nil) ?? inferred
        return MemorydOptions(floor: url, port: port, profileId: resolved, allowUnmounted: allowUnmounted, model: model, judgeModel: judgeModel)
    }
}
