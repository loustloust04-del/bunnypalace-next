#if os(iOS)
import DeviceKit
import UIKit

/// 终端首页 3D 的「这台手机」：类别看标识符前缀，名字取 DeviceKit（plan-terminal-3d §四）。
enum TerminalLocalDevice {
    /// 本机类别 + 给人看的名字（如「iPhone Air」）；DeviceKit 不认识的新机型回落到 UIDevice.current.model
    static var current: (deviceClass: TerminalDeviceClass, name: String) {
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? Device.identifier
        let device = Device.current.realDevice
        let name: String
        if case .unknown = device {
            name = UIDevice.current.model
        } else {
            name = device.description
        }
        return (.local(machineIdentifier: identifier), name)
    }
}
#endif
