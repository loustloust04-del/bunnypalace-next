import Foundation

/// 终端首页「我的电脑」的信息（plan-terminal-3d §四）。来源是 hub 的 hello 帧（`CCBridgeWebSocketClient.hubInfo`）；这里只是值。
struct TerminalHostInfo: Equatable {
    var hostName: String?
    var modelId: String?
    var modelName: String?
    /// true 装了 / false 没装 / nil 不知道；只有 false 才算没装
    var claudeInstalled: Bool?
    var codexInstalled: Bool?

    var deviceClass: TerminalDeviceClass {
        .remote(modelId: modelId, modelName: modelName)
    }
}

extension TerminalHostInfo {
    /// hub `hello` 帧（#046）→ 首页要的那几样
    init(hello: HubHello) {
        self.init(hostName: hello.hostName, modelId: hello.hostModelId, modelName: hello.hostModelName,
                  claudeInstalled: hello.tools.claude, codexInstalled: hello.tools.codex)
    }
}
