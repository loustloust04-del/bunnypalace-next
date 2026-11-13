import XCTest
import SceneKit
import SwiftUI
import UIKit
@testable import 记忆花园

/// 终端首页 3D 停帧（research-terminal-3d-idle-render §3/§4）：停了以后每帧回调一个属性都不写（写了 SCNView 会自己续帧），叫醒后照常写。
/// 只测逻辑，测不了 GPU；真停没停看 mask 上 Metal System Trace
@MainActor
final class TerminalScene3DIdleTests: XCTestCase {
    private let input = TerminalSceneInput(local: .phone, localName: "iPhone", hosts: [
        TerminalSceneHost(id: CCHubRegistry.primaryId, primary: true, name: "我的电脑", link: .unplugged, device: .laptop,
                          modelName: nil, hostName: nil, claude: nil, codex: nil, screenTitle: "MY-COMPUTER", screenRows: [])
    ])

    func testHaltedFrameCallbackWritesNothingUntilWoken() throws {
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), options: nil)
        view.rendersContinuously = false
        view.isPlaying = false
        let controller = TerminalSceneController()
        controller.attach(view)

        controller.apply(input, focus: nil, active: true)
        XCTAssertTrue(view.isPlaying)
        XCTAssertFalse(controller.isHaltedForTesting)

        controller.apply(input, focus: nil, active: false)
        XCTAssertFalse(view.isPlaying)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertTrue(controller.isHaltedForTesting)
        // 建好还没画过：停着的第一次重画补画一帧静态，之后才一个属性都不写
        controller.renderer(view, updateAtTime: 0)

        let parts = try XCTUnwrap(controller.partsForTesting)
        let remote = try XCTUnwrap(parts.remotes.first)
        let bead = try XCTUnwrap(remote.beads.first?.geometry?.firstMaterial)
        let sentinel: SIMD3<Float> = [9, 9, 9]
        parts.camera.simdPosition = sentinel
        bead.emission.intensity = 42
        remote.threadMaterial.transparency = 0.5
        parts.penguin.eulerAngles.z = 0.25

        controller.renderer(view, updateAtTime: 0)
        XCTAssertEqual(parts.camera.simdPosition, sentinel, "停了：镜头不写")
        XCTAssertEqual(bead.emission.intensity, 42, "停了：珠子不写")
        XCTAssertEqual(remote.threadMaterial.transparency, 0.5, "停了：线不写")
        XCTAssertEqual(parts.penguin.eulerAngles.z, 0.25, "停了：企鹅不写")

        controller.apply(input, focus: nil, active: true)
        XCTAssertFalse(controller.isHaltedForTesting)
        XCTAssertTrue(view.isPlaying)
        controller.renderer(view, updateAtTime: 0)
        XCTAssertNotEqual(parts.camera.simdPosition, sentinel, "叫醒后恢复写")
        XCTAssertNotEqual(bead.emission.intensity, 42)
        XCTAssertNotEqual(remote.threadMaterial.transparency, 0.5)

        controller.detach()
    }

    func testBridgeCardTitleNamesTheComputerOnlyWhenGiven() {
        XCTAssertEqual(TerminalBridgeCard(issue: .disconnected, primary: {}, secondary: {}).title, "连不上我的电脑")
        XCTAssertEqual(TerminalBridgeCard(issue: .disconnected, computerName: "纽约", primary: {}, secondary: {}).title, "连不上纽约")
    }

    /// 11-05 Air 回归：场景在「看不见」（active=false）时建好，SCNView 上屏时补画的那帧被 halted 整段跳过，
    /// 新镜头停在原点（满屏大珠子）。真窗口真渲染：停着建好的场景，第一次重画就要摆好，而且只多画一两帧，不续帧
    func testSceneBuiltWhileStoppedIsPosedOnFirstRedraw() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 370, height: 340), options: nil)
        view.rendersContinuously = false
        view.isPlaying = false
        let controller = TerminalSceneController()
        controller.attach(view)
        let frames = FrameCounter(controller)
        view.delegate = frames

        controller.apply(input, focus: nil, active: false)
        XCTAssertTrue(controller.isHaltedForTesting)
        window.rootViewController?.view.addSubview(view)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let parts = try XCTUnwrap(controller.partsForTesting)
        XCTAssertNotEqual(parts.camera.simdPosition, SIMD3<Float>(0, 0, 0), "停着建好的场景上屏：镜头不能停在原点")
        let remote = try XCTUnwrap(parts.remotes.first)
        XCTAssertTrue(remote.beads[10].isHidden, "没接上：珠串只露前 6 颗")
        XCTAssertTrue(controller.isHaltedForTesting)
        XCTAssertFalse(view.isPlaying)
        XCTAssertGreaterThan(frames.count, 0)
        XCTAssertLessThanOrEqual(frames.count, 3, "补画一帧就停，不能续帧")
        controller.detach()
    }

    /// 11-05 Air：page2 子应用宿主（`Page2HostedContent`）拷的环境快照里 scenePhase 后台往返后停在 inactive，UIKit 早就 active——
    /// 看得见却 active=false，点设备 wake 被挡、镜头不聚焦。前后台改听 UIKit：快照说 inactive 照样出帧，真失活才停
    func testStaleScenePhaseSnapshotDoesNotHaltVisibleScene() throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "宿主 app 不在前台")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.rootViewController = UIHostingController(rootView:
            TerminalHomeScene(input: input, focus: .constant(nil), onAction: { _ in }, onManage: { _ in })
                .frame(width: 370, height: 340)
                .environment(\.scenePhase, .inactive))
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let view = try XCTUnwrap(Self.sceneView(in: window))
        XCTAssertTrue(view.isPlaying, "看得见、UIKit 在前台：环境 scenePhase 过期也要出帧")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(view.isPlaying, "失活：停帧")

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(view.isPlaying, "回前台：重新出帧")
    }

    private static func sceneView(in view: UIView) -> SCNView? {
        if let scn = view as? SCNView { return scn }
        return view.subviews.lazy.compactMap { sceneView(in: $0) }.first
    }

    private final class FrameCounter: NSObject, SCNSceneRendererDelegate {
        let target: TerminalSceneController
        private let lock = NSLock()
        private var n = 0
        init(_ target: TerminalSceneController) { self.target = target }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            lock.lock(); n += 1; lock.unlock()
            target.renderer(renderer, updateAtTime: time)
        }
    }
}
