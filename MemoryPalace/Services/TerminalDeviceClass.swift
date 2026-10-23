import Foundation

/// 终端首页 3D 场景里设备的外形类别（plan-terminal-3d §四）。本机：手机 / 平板；外机：台式 / 笔记本 / 一体机。
enum TerminalDeviceClass: Equatable {
    case phone, tablet, desktop, laptop, allInOne
}

extension TerminalDeviceClass {
    /// 本机：iPhone… → .phone，iPad… → .tablet（模拟器传 SIMULATOR_MODEL_IDENTIFIER 的值）
    static func local(machineIdentifier: String) -> TerminalDeviceClass {
        machineIdentifier.hasPrefix("iPad") ? .tablet : .phone
    }

    /// 外机：Apple Silicon 的 `MacNN,N` 不带类别，先看 product-name 文本；Intel 老号按 hw.model 前缀；判不出 → 一体机
    static func remote(modelId: String?, modelName: String?) -> TerminalDeviceClass {
        if let modelName {
            if modelName.contains("MacBook") { return .laptop }
            if modelName.contains("iMac") { return .allInOne }
            if modelName.contains("Mac mini") || modelName.contains("Mac Studio") || modelName.contains("Mac Pro") { return .desktop }
        }
        if let modelId {
            if modelId.hasPrefix("MacBook") { return .laptop }
            if modelId.hasPrefix("iMac") { return .allInOne }
            if modelId.hasPrefix("Macmini") || modelId.hasPrefix("MacStudio") || modelId.hasPrefix("MacPro") { return .desktop }
        }
        return .allInOne
    }

    var isLocal: Bool {
        switch self {
        case .phone, .tablet: true
        case .desktop, .laptop, .allInOne: false
        }
    }
}
