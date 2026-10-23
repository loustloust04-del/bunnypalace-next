#if os(iOS)
import SceneKit
import SwiftUI
import UIKit

/// 首页 3D 小场景建好以后，动画和聚焦要摸的那些节点
struct TerminalSceneParts {
    let scene: SCNScene
    let camera: SCNNode
    /// 本机（手机 / 平板）+ 企鹅：点到哪个都算本机
    let local: SCNNode
    let localScreen: SCNNode
    let penguin: SCNNode
    /// 企鹅右边那只翅膀（接线时挥一下）
    let flipper: SCNNode
    let remote: SCNNode
    let remoteScreen: SCNNode
    let remoteScreenMaterial: SCNMaterial
    let led: SCNMaterial?
    let claudeSeat: SCNNode
    let codexSeat: SCNNode
    let beads: [SCNNode]
    let threadElement: SCNGeometryElement
    let threadMaterial: SCNMaterial
    let ghost: SCNNode
}

/// 首页 3D 小场景的程序化建模。尺寸、颜色、位置照 design-terminal-home.html v8 的 three.js 参数，单位直接沿用。
final class TerminalSceneBuilder {
    enum C {
        static let cream: UInt = 0xEFE8DA, creamMid: UInt = 0xE2D9C7, creamDark: UInt = 0xCBC1AD, seam: UInt = 0xB9AE98
        static let bezel: UInt = 0x2b2724
        static let mint: UInt = 0x87D6B0, berry: UInt = 0xFF8787
        static let bead: UInt = 0xD8D0C0, tuxBlack: UInt = 0x0e0d0c, tuxWhite: UInt = 0xF6F1E8, tuxOrange: UInt = 0xE8913F
    }

    static let beadCount = 34

    private var shapes: [String: SCNGeometry] = [:]

    private lazy var caseM = Self.std(C.cream, roughness: 0.5)
    private lazy var midM = Self.std(C.creamMid, roughness: 0.55)
    private lazy var darkM = Self.std(C.creamDark, roughness: 0.6)
    private lazy var wellM = Self.std(C.bezel, roughness: 0.8)
    private lazy var capM = Self.std(0xF5F0E6, roughness: 0.45)
    private lazy var inkM = Self.std(0x26231f, roughness: 0.3, metalness: 0.18)
    private lazy var inkDeepM = Self.std(0x121110, roughness: 0.7)
    private lazy var inkBumpM = Self.std(0x37332e, roughness: 0.28, metalness: 0.2)
    private lazy var inkLensM = Self.std(0x080707, roughness: 0.08, metalness: 0.6)
    private lazy var dockM = Self.std(C.creamMid, roughness: 0.55)

    func build(local: TerminalDeviceClass, remote: TerminalDeviceClass, remoteScreen: SCNMaterial) -> TerminalSceneParts {
        let scene = SCNScene()
        let root = scene.rootNode
        addLights(to: root)
        addGround(to: root)

        // 本机（黑）
        let localGroup = SCNNode()
        root.addChildNode(localGroup)
        let localNode = SCNNode()
        let localScreen: SCNNode
        let localPort: SIMD3<Float>
        if local == .tablet {
            localNode.simdPosition = [-1.45, 0, 0.45]
            localNode.simdScale = SIMD3(repeating: 0.6)
            localScreen = buildTablet(localNode)
            localPort = [0.78, 0.05, 0.12]
        } else {
            localNode.simdPosition = [-1.45, 0, 0.45]
            localNode.simdScale = SIMD3(repeating: 0.92)
            localScreen = buildPhone(localNode)
            localPort = [0.31, 0.06, 0.02]
        }
        localNode.eulerAngles.y = 0.32
        localGroup.addChildNode(localNode)

        let (penguin, flipper) = buildPenguin()
        penguin.simdPosition = [-2.2, 0, 1.15]
        penguin.eulerAngles.y = 0.12
        localGroup.addChildNode(penguin)

        // 外机（奶白）
        let remoteNode = SCNNode()
        remoteNode.simdPosition = [1.4, 0, -0.25]
        remoteNode.eulerAngles.y = -0.4
        root.addChildNode(remoteNode)
        let built = buildRemote(remote, in: remoteNode, screen: remoteScreen)

        // 珠串：手机 → 电脑侧后接口
        let phPort = localNode.simdConvertPosition(localPort, to: nil)
        let pcPort = remoteNode.simdConvertPosition(built.port, to: nil)
        let curve: [SIMD3<Float>] = [
            phPort, [phPort.x + 0.3, 0.04, phPort.z - 0.05], [-0.45, 0.04, -0.3],
            [0.15, 0.04, -0.75], [pcPort.x - 0.3, 0.05, pcPort.z + 0.05], pcPort,
        ]
        var beads: [SCNNode] = []
        let n = Self.beadCount
        for i in 0..<n {
            let big = i % 2 == 0
            let sphere = SCNSphere(radius: big ? 0.056 : 0.032)
            sphere.segmentCount = 18
            let m = Self.std(C.bead, roughness: 0.3, metalness: 0.1)
            m.emission.contents = Self.color(C.mint)
            m.emission.intensity = 0
            sphere.materials = [m]
            let bead = SCNNode(geometry: sphere)
            bead.simdPosition = Self.catmullRom(curve, Float(i) / Float(n - 1))
            root.addChildNode(bead)
            beads.append(bead)
        }
        let threadMaterial = Self.std(0xBFB6A6, roughness: 0.6)
        let samples = (0...120).map { Self.catmullRom(curve, Float($0) / 120) }
        let (threadGeometry, threadElement) = Self.tube(samples, radius: 0.009, material: threadMaterial)
        let thread = SCNNode(geometry: threadGeometry)
        root.addChildNode(thread)
        let plug = rbox(0.09, 0.06, 0.14, 0.02, Self.std(C.creamDark))
        plug.simdPosition = pcPort
        root.addChildNode(plug)
        plug.simdLook(at: Self.catmullRom(curve, 0.97), up: [0, 1, 0], localFront: [0, 0, 1])

        // 再接一台（虚线空位）
        let ghost = buildGhost()
        ghost.simdPosition = [-1.3, 0, -4.2]
        ghost.eulerAngles.y = 0.15
        ghost.simdScale = SIMD3(repeating: 0.85)
        root.addChildNode(ghost)

        let camera = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = 30
        cam.zNear = 0.1
        cam.zFar = 100
        camera.camera = cam
        root.addChildNode(camera)

        return TerminalSceneParts(
            scene: scene, camera: camera, local: localGroup, localScreen: localScreen,
            penguin: penguin, flipper: flipper, remote: remoteNode, remoteScreen: built.screen,
            remoteScreenMaterial: remoteScreen, led: built.led, claudeSeat: built.claudeSeat, codexSeat: built.codexSeat,
            beads: beads, threadElement: threadElement, threadMaterial: threadMaterial, ghost: ghost
        )
    }

    // MARK: 灯 / 地面

    private func addLights(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = Self.color(0xfff4e6)
        ambient.intensity = 520
        root.addChildNode(Self.lightNode(ambient, at: [0, 5, 0]))

        let key = SCNLight()
        key.type = .directional
        key.color = Self.color(0xfff0dc)
        key.intensity = 950
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowColor = UIColor.black.withAlphaComponent(0.38)
        key.shadowMapSize = CGSize(width: 1024, height: 1024)
        key.shadowRadius = 4
        key.shadowSampleCount = 8
        key.orthographicScale = 6
        key.zNear = 1
        key.zFar = 20
        root.addChildNode(Self.lightNode(key, at: [3.5, 7, 5]))

        let fill = SCNLight()
        fill.type = .directional
        fill.color = Self.color(0xffe7d0)
        fill.intensity = 250
        root.addChildNode(Self.lightNode(fill, at: [-5, 3, 4]))

        let rim = SCNLight()
        rim.type = .directional
        rim.color = Self.color(0x9fe0c2)
        rim.intensity = 350
        root.addChildNode(Self.lightNode(rim, at: [-3, 4, -5]))
    }

    private static func lightNode(_ light: SCNLight, at position: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.light = light
        node.simdPosition = position
        node.simdLook(at: .zero)
        return node
    }

    /// 地面：只接影子 + 花园点点
    private func addGround(to root: SCNNode) {
        let plane = SCNPlane(width: 30, height: 30)
        let shadow = SCNMaterial()
        shadow.lightingModel = .shadowOnly
        plane.materials = [shadow]
        let ground = SCNNode(geometry: plane)
        ground.eulerAngles.x = -.pi / 2
        ground.castsShadow = false
        root.addChildNode(ground)

        var points: [SCNVector3] = []
        var x: Float = -7
        while x <= 7 {
            var z: Float = -5
            while z <= 5 {
                points.append(SCNVector3(x, 0.002, z))
                z += 0.42
            }
            x += 0.42
        }
        let source = SCNGeometrySource(vertices: points)
        let element = SCNGeometryElement(indices: (0..<UInt32(points.count)).map { $0 }, primitiveType: .point)
        element.pointSize = 0.03
        element.minimumPointScreenSpaceRadius = 0.6
        element.maximumPointScreenSpaceRadius = 2
        let dots = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = Self.color(0x6f6a63).withAlphaComponent(0.5)
        m.writesToDepthBuffer = false
        dots.materials = [m]
        let node = SCNNode(geometry: dots)
        node.castsShadow = false
        root.addChildNode(node)
    }

    // MARK: 本机

    private func buildPhone(_ g: SCNNode) -> SCNNode {
        let tilt = add(SCNNode(), to: g, at: [0, 0.12, 0], rx: -0.2)
        add(rbox(0.76, 1.48, 0.14, 0.2, inkM, bevel: 0.05), to: tilt, at: [0, 0.74, 0])
        add(rbox(0.66, 1.38, 0.02, 0.14, inkDeepM, bevel: 0.008), to: tilt, at: [0, 0.74, 0.066])
        let screen = add(Self.screenPlane(0.6, 1.25, image: Self.cleanTerminal(width: 240, height: 500, radius: 34)),
                         to: tilt, at: [0, 0.74, 0.078])
        add(rbox(0.26, 0.26, 0.05, 0.09, inkBumpM, bevel: 0.018), to: tilt, at: [-0.16, 1.24, -0.08])
        add(cylinder(0.06, 0.02, inkLensM), to: tilt, at: [-0.16, 1.24, -0.107], rx: .pi / 2)
        for (x, y, h) in [(-0.385, 1.06, 0.14), (-0.385, 0.88, 0.14), (0.385, 0.98, 0.22)] as [(Float, Float, Float)] {
            add(rbox(0.025, h, 0.05, 0.012, inkBumpM, bevel: 0.008), to: tilt, at: [x, y, 0])
        }
        // 奶白小座：前面一条托 + 后面一块圆角撑板
        add(rbox(0.62, 0.12, 0.3, 0.05, dockM), to: g, at: [0, 0.06, 0.02])
        add(rbox(0.42, 1.0, 0.06, 0.15, dockM, bevel: 0.02), to: g, at: [0, 0.515, -0.435], rx: 0.37)
        return screen
    }

    private func buildTablet(_ g: SCNNode) -> SCNNode {
        add(rbox(1.5, 0.1, 0.34, 0.05, dockM), to: g, at: [0, 0.05, 0.12])
        let tilt = add(SCNNode(), to: g, at: [0, 0.1, 0.1], rx: -0.24)
        add(rbox(1.9, 1.32, 0.11, 0.22, inkM, bevel: 0.045), to: tilt, at: [0, 0.66, 0])
        add(rbox(1.76, 1.18, 0.02, 0.15, inkDeepM, bevel: 0.008), to: tilt, at: [0, 0.66, 0.052])
        let screen = add(Self.screenPlane(1.66, 1.1, image: Self.cleanTerminal(width: 400, height: 266, radius: 22)),
                         to: tilt, at: [0, 0.66, 0.064])
        add(cylinder(0.05, 0.02, inkLensM), to: tilt, at: [-0.76, 1.15, -0.062], rx: .pi / 2)
        add(rbox(1.0, 0.95, 0.07, 0.22, dockM, bevel: 0.025), to: g, at: [0, 0.45, -0.39], rx: 0.49)
        return screen
    }

    // MARK: 外机

    private struct Remote {
        let screen: SCNNode
        let led: SCNMaterial?
        let port: SIMD3<Float>
        let claudeSeat: SCNNode
        let codexSeat: SCNNode
    }

    private func buildRemote(_ kind: TerminalDeviceClass, in g: SCNNode, screen: SCNMaterial) -> Remote {
        switch kind {
        case .laptop: return buildLaptop(g, screen: screen)
        case .desktop: return buildDesktop(g, screen: screen)
        default: return buildRetroPc(g, screen: screen)
        }
    }

    private func seats(_ g: SCNNode, claude: SIMD3<Float>, codex: SIMD3<Float>) -> (SCNNode, SCNNode) {
        let crab = add(SCNNode(), to: g, at: claude)
        let cloud = add(SCNNode(), to: g, at: codex)
        cloud.eulerAngles.y = -0.08
        return (crab, cloud)
    }

    /// 一体机（iMac / 不知道型号）：小样那台复古一体机，去掉左下圆徽章
    private func buildRetroPc(_ pc: SCNNode, screen: SCNMaterial) -> Remote {
        add(rbox(1.9, 2.05, 1.05, 0.16, caseM), to: pc, at: [0, 1.12, 0.12])
        add(rbox(1.62, 1.72, 0.95, 0.22, midM), to: pc, at: [0, 1.2, -0.72])
        add(rbox(1.1, 1.15, 0.5, 0.18, darkM), to: pc, at: [0, 1.18, -1.28])
        add(rbox(1.82, 0.12, 1.0, 0.04, darkM), to: pc, at: [0, 0.06, 0.12])
        add(rbox(1.56, 1.2, 0.06, 0.12, Self.std(C.creamMid, roughness: 0.65)), to: pc, at: [0, 1.42, 0.66])
        add(rbox(1.42, 1.06, 0.05, 0.1, wellM), to: pc, at: [0, 1.42, 0.68])
        let crt = Self.crtGeometry()
        let screenNode = add(SCNNode(geometry: crt.copy() as? SCNGeometry), to: pc, at: [0, 1.42, 0.69])
        screenNode.geometry?.materials = [screen]
        screenNode.castsShadow = false
        let glassMaterial = SCNMaterial()
        glassMaterial.lightingModel = .blinn
        glassMaterial.diffuse.contents = UIColor.white
        glassMaterial.specular.contents = UIColor.white
        glassMaterial.shininess = 0.9
        glassMaterial.transparency = 0.08
        glassMaterial.writesToDepthBuffer = false
        crt.materials = [glassMaterial]
        let glass = add(SCNNode(geometry: crt), to: pc, at: [0, 1.42, 0.695])
        glass.castsShadow = false
        // 软驱槽 + 电源灯
        add(rbox(0.56, 0.05, 0.06, 0.02, Self.std(0x3a3532, roughness: 0.9)), to: pc, at: [0.35, 0.5, 0.66])
        add(rbox(0.66, 0.12, 0.03, 0.04, darkM), to: pc, at: [0.35, 0.5, 0.645])
        let led = Self.basic(C.mint)
        add(sphere(0.022, led, segments: 12), to: pc, at: [-0.52, 0.48, 0.665])
        // 侧面散热槽
        let vents = SCNNode()
        let ventM = Self.std(C.seam, roughness: 0.9)
        for i in 0..<7 {
            add(rbox(0.02, 0.05, 0.5, 0.01, ventM), to: vents, at: [0.955, 1.65 - Float(i) * 0.09, -0.05])
        }
        pc.addChildNode(vents.flattenedClone())
        add(rbox(0.06, 0.1, 0.22, 0.02, Self.std(0x2a2624)), to: pc, at: [-0.815, 0.32, -0.75])

        // 键盘：底板 + 4 排键帽 + 空格
        let kb = SCNNode()
        add(rbox(1.86, 0.1, 0.72, 0.06, caseM), to: kb, at: [0, 0.06, 0])
        let capDarkM = Self.std(C.creamDark, roughness: 0.5)
        for r in 0..<4 {
            let n = 12, x0 = -0.77 + Float(r) * 0.035
            for i in 0..<(n - (r > 0 ? 1 : 0)) {
                let dark = r == 0 && (i == 0 || i == n - 1)
                add(rbox(0.13, 0.06, 0.13, 0.025, dark ? capDarkM : capM), to: kb,
                    at: [x0 + Float(i) * 0.142, 0.135, -0.24 + Float(r) * 0.15])
            }
        }
        add(rbox(0.82, 0.06, 0.13, 0.025, capM), to: kb, at: [-0.05, 0.135, 0.36])
        add(kb.flattenedClone(), to: pc, at: [0.05, 0, 1.25], rx: 0.07)
        // 鼠标 + 线
        let mouse = add(SCNNode(), to: pc, at: [1.32, 0, 1.3])
        mouse.eulerAngles.y = -0.15
        add(sphere(0.17, caseM, segments: 28), to: mouse, at: [0, 0.07, 0]).simdScale = [0.85, 0.42, 1.25]
        add(rbox(0.2, 0.02, 0.1, 0.01, darkM), to: mouse, at: [0, 0.135, -0.11], rx: -0.25)
        let cable: [SIMD3<Float>] = [[1.32, 0.05, 1.08], [1.25, 0.02, 0.7], [1.0, 0.02, 0.62], [0.96, 0.2, 0.3]]
        let (cableGeometry, _) = Self.tube((0...40).map { Self.catmullRom(cable, Float($0) / 40) }, radius: 0.012,
                                           material: Self.std(C.creamDark))
        pc.addChildNode(SCNNode(geometry: cableGeometry))

        let (claude, codex) = seats(pc, claude: [-0.44, 2.145, 0.22], codex: [0.47, 2.145, 0.16])
        return Remote(screen: screenNode, led: led, port: [-0.86, 0.32, -0.75], claudeSeat: claude, codexSeat: codex)
    }

    /// 台式（Mac mini / Studio / Pro）：只画显示器 + 键盘 + 鼠标，不画主机盒
    private func buildDesktop(_ g: SCNNode, screen: SCNMaterial) -> Remote {
        let dk = add(SCNNode(), to: g, at: .zero)
        dk.simdScale = SIMD3(repeating: 0.9)
        add(flat(0.92, 0.6, 0.06, 0.26, midM, bevel: 0.02), to: dk, at: [0, 0.03, -0.42])
        add(rbox(0.2, 0.86, 0.07, 0.08, caseM, bevel: 0.025), to: dk, at: [0, 0.5, -0.5], rx: -0.1)
        let mon = add(SCNNode(), to: dk, at: [0, 1.28, -0.4], rx: -0.08)
        add(rbox(2.2, 1.36, 0.13, 0.2, caseM, bevel: 0.04), to: mon, at: .zero)
        add(rbox(0.9, 0.62, 0.1, 0.18, midM, bevel: 0.035), to: mon, at: [0, -0.06, -0.09])
        add(rbox(2.0, 1.16, 0.02, 0.12, wellM, bevel: 0.006), to: mon, at: [0, 0.03, 0.065])
        let screenNode = add(Self.screenPlane(1.9, 1.06, material: screen), to: mon, at: [0, 0.03, 0.077])
        let led = Self.basic(C.mint)
        add(sphere(0.022, led, segments: 12), to: mon, at: [0.86, -0.6, 0.06])
        add(keyboard(1.62), to: dk, at: [-0.12, 0, 0.62], rx: 0.05)
        let mouse = add(SCNNode(), to: dk, at: [1.0, 0, 0.66])
        mouse.eulerAngles.y = -0.15
        add(sphere(0.15, caseM, segments: 28), to: mouse, at: [0, 0.063, 0]).simdScale = [0.85, 0.42, 1.25]
        let (claude, codex) = seats(g, claude: [-0.5, 1.76, -0.41], codex: [0.5, 1.76, -0.41])
        return Remote(screen: screenNode, led: led, port: [-0.44, 0.03, -0.38], claudeSeat: claude, codexSeat: codex)
    }

    /// 笔记本（MacBook）：开着盖
    private func buildLaptop(_ g: SCNNode, screen: SCNMaterial) -> Remote {
        let lap = add(SCNNode(), to: g, at: [0, 0, 0.25])
        add(flat(2.1, 1.4, 0.11, 0.22, caseM, bevel: 0.04), to: lap, at: [0, 0.055, 0])
        add(flat(1.78, 0.66, 0.02, 0.1, midM, bevel: 0.006), to: lap, at: [0, 0.11, -0.17])
        let caps = SCNNode()
        for r in 0..<4 {
            for i in 0..<12 {
                add(flat(0.115, 0.115, 0.03, 0.03, capM, bevel: 0.01), to: caps,
                    at: [-0.77 + Float(i) * 0.14, 0.125, -0.42 + Float(r) * 0.14])
            }
        }
        add(flat(0.7, 0.1, 0.03, 0.03, capM, bevel: 0.01), to: caps, at: [0, 0.125, 0.12])
        lap.addChildNode(caps.flattenedClone())
        add(flat(0.66, 0.36, 0.012, 0.08, midM, bevel: 0.004), to: lap, at: [0, 0.112, 0.43])
        let hinge = add(cylinder(0.055, 1.6, darkM), to: lap, at: [0, 0.12, -0.66])
        hinge.eulerAngles.z = .pi / 2
        let lid = add(SCNNode(), to: lap, at: [0, 0.1, -0.64], rx: -0.33)
        add(rbox(2.1, 1.36, 0.08, 0.22, caseM, bevel: 0.03), to: lid, at: [0, 0.7, 0])
        add(rbox(1.9, 1.18, 0.02, 0.13, wellM, bevel: 0.006), to: lid, at: [0, 0.72, 0.04])
        let screenNode = add(Self.screenPlane(1.8, 1.1, material: screen), to: lid, at: [0, 0.72, 0.052])
        let (claude, codex) = seats(g, claude: [-0.5, 1.41, -0.84], codex: [0.5, 1.41, -0.84])
        return Remote(screen: screenNode, led: nil, port: [-1.08, 0.06, 0.0], claudeSeat: claude, codexSeat: codex)
    }

    /// 台式的奶白键盘：底板 + 4 排键帽 + 空格
    private func keyboard(_ w: Float) -> SCNNode {
        let kb = SCNNode()
        add(flat(w, 0.62, 0.09, 0.12, caseM, bevel: 0.03), to: kb, at: [0, 0.045, 0])
        let n = 11, step = (w - 0.3) / Float(n - 1)
        for r in 0..<4 {
            for i in 0..<n {
                add(flat(0.12, 0.11, 0.05, 0.03, capM, bevel: 0.012), to: kb,
                    at: [-(w - 0.3) / 2 + Float(i) * step, 0.11, -0.22 + Float(r) * 0.125])
            }
        }
        add(flat(0.66, 0.1, 0.05, 0.03, capM, bevel: 0.012), to: kb, at: [0, 0.11, 0.25])
        return kb.flattenedClone()
    }

    // MARK: 企鹅

    private func buildPenguin() -> (SCNNode, SCNNode) {
        let peng = SCNNode()
        let black = Self.std(C.tuxBlack, roughness: 0.32, metalness: 0.05)
        let white = Self.std(C.tuxWhite, roughness: 0.45)
        let orange = Self.std(C.tuxOrange, roughness: 0.4)
        // 身体 + 头：一条梨形轮廓旋转出来
        let profile: [SIMD2<Float>] = [[0, 0.06], [0.3, 0.08], [0.42, 0.22], [0.45, 0.42], [0.41, 0.62], [0.31, 0.8],
                                       [0.27, 0.9], [0.3, 1.02], [0.29, 1.14], [0.22, 1.25], [0.1, 1.31], [0, 1.32]]
        let body = SCNNode(geometry: Self.lathe((0...40).map { Self.spline(profile, Float($0) / 40) }, segments: 48, material: black))
        peng.addChildNode(body)
        // 白肚皮 + 白脸
        add(sphere(0.34, white, segments: 40), to: peng, at: [0, 0.43, 0.24]).simdScale = [0.98, 1.2, 0.72]
        var flipper = SCNNode()
        for s in [Float(-1), 1] {
            let patch = add(sphere(0.11, white, segments: 28), to: peng, at: [0.085 * s, 1.07, 0.235])
            patch.simdScale = [0.95, 1.35, 0.7]
            patch.eulerAngles.z = -0.15 * s
            add(sphere(0.042, black, segments: 20), to: peng, at: [0.09 * s, 1.08, 0.31]).simdScale = [0.8, 1.15, 0.6]
            add(sphere(0.012, Self.basic(0xffffff), segments: 10), to: peng, at: [0.1 * s + 0.01, 1.1, 0.335])
            // 翅膀
            let fl = add(sphere(0.16, black, segments: 28), to: peng, at: [0.42 * s, 0.52, 0])
            fl.simdScale = [0.28, 1.25, 0.75]
            fl.eulerAngles.z = 0.32 * s
            if s > 0 { flipper = fl }
            // 脚：扁掌 + 三个脚趾
            add(sphere(0.11, orange, segments: 24), to: peng, at: [0.15 * s, 0.035, 0.17]).simdScale = [1.25, 0.32, 1.55]
            for k in -1...1 {
                add(sphere(0.045, orange, segments: 14), to: peng, at: [0.15 * s + Float(k) * 0.06, 0.03, 0.32]).simdScale = [1, 0.6, 1.3]
            }
        }
        // 嘴：上下两片
        add(sphere(0.09, orange, segments: 24), to: peng, at: [0, 0.98, 0.32]).simdScale = [1.15, 0.42, 1.0]
        add(sphere(0.075, Self.std(0xD47A2E, roughness: 0.45), segments: 24), to: peng, at: [0, 0.945, 0.31]).simdScale = [1.05, 0.36, 0.85]
        return (peng, flipper)
    }

    // MARK: 再接一台

    private func buildGhost() -> SCNNode {
        let g = SCNNode()
        let dash = SCNMaterial()
        dash.lightingModel = .constant
        dash.diffuse.contents = Self.color(0x8a837b).withAlphaComponent(0.6)
        for (w, h, d, y, z) in [(1.9, 2.05, 1.05, 1.12, 0.12), (1.62, 1.72, 0.95, 1.2, -0.72)] as [(Float, Float, Float, Float, Float)] {
            let lines = SCNNode(geometry: Self.dashedBox(w, h, d, material: dash))
            lines.simdPosition = [0, y, z]
            lines.castsShadow = false
            g.addChildNode(lines)
        }
        let plus = SCNPlane(width: 0.55, height: 0.55)
        let plusM = SCNMaterial()
        plusM.lightingModel = .constant
        plusM.diffuse.contents = Self.plusImage()
        plusM.transparency = 0.85
        plusM.isDoubleSided = true
        plus.materials = [plusM]
        let sprite = add(SCNNode(geometry: plus), to: g, at: [0, 1.15, 0.7])
        sprite.constraints = [SCNBillboardConstraint()]
        sprite.castsShadow = false
        // 虚线点不中：透明盒子兜住点选
        let hit = SCNBox(width: 1.9, height: 2.05, length: 2.0, chamferRadius: 0)
        let hitM = SCNMaterial()
        hitM.colorBufferWriteMask = []
        hitM.writesToDepthBuffer = false
        hit.materials = [hitM]
        let hitNode = add(SCNNode(geometry: hit), to: g, at: [0, 1.12, -0.3])
        hitNode.castsShadow = false
        return g
    }

    // MARK: 零件

    @discardableResult
    private func add(_ node: SCNNode, to parent: SCNNode, at position: SIMD3<Float>, rx: Float = 0) -> SCNNode {
        node.simdPosition = position
        if rx != 0 { node.eulerAngles.x = rx }
        parent.addChildNode(node)
        return node
    }

    /// 圆角盒：圆角矩形截面挤出 + 圆倒角（小样 rbox，这一个撑起所有外壳）。
    /// three 的 r 是倒角前内轮廓的圆角，倒角再往外撑 b，所以外轮廓圆角 = r + b
    private func rbox(_ w: Float, _ h: Float, _ d: Float, _ r: Float, _ material: SCNMaterial, bevel: Float? = nil) -> SCNNode {
        let b = bevel ?? min(r, d / 2) * 0.6
        let key = "\(w)|\(h)|\(d)|\(r)|\(b)|\(ObjectIdentifier(material).hashValue)"
        if let geometry = shapes[key] { return SCNNode(geometry: geometry) }
        let radius = max(0.001, min(r, (w - 2 * b) / 2, (h - 2 * b) / 2)) + b
        let shape = SCNShape(path: Self.roundedRect(w, h, radius), extrusionDepth: CGFloat(d))
        shape.chamferRadius = CGFloat(min(b, d / 2))
        shape.materials = [material]
        shapes[key] = shape
        return SCNNode(geometry: shape)
    }

    /// 平放的圆角块：俯视四角大圆角
    private func flat(_ w: Float, _ d: Float, _ h: Float, _ r: Float, _ material: SCNMaterial, bevel: Float? = nil) -> SCNNode {
        let node = SCNNode()
        node.addChildNode(rbox(w, d, h, r, material, bevel: bevel))
        node.childNodes[0].eulerAngles.x = -.pi / 2
        return node
    }

    private func sphere(_ radius: CGFloat, _ material: SCNMaterial, segments: Int) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.segmentCount = segments
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func cylinder(_ radius: CGFloat, _ height: CGFloat, _ material: SCNMaterial) -> SCNNode {
        let geometry = SCNCylinder(radius: radius, height: height)
        geometry.radialSegmentCount = 28
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func roundedRect(_ w: Float, _ h: Float, _ radius: Float) -> UIBezierPath {
        let x = CGFloat(-w / 2), y = CGFloat(-h / 2), W = CGFloat(w), H = CGFloat(h), R = CGFloat(radius)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x + R, y: y))
        path.addLine(to: CGPoint(x: x + W - R, y: y))
        path.addQuadCurve(to: CGPoint(x: x + W, y: y + R), controlPoint: CGPoint(x: x + W, y: y))
        path.addLine(to: CGPoint(x: x + W, y: y + H - R))
        path.addQuadCurve(to: CGPoint(x: x + W - R, y: y + H), controlPoint: CGPoint(x: x + W, y: y + H))
        path.addLine(to: CGPoint(x: x + R, y: y + H))
        path.addQuadCurve(to: CGPoint(x: x, y: y + H - R), controlPoint: CGPoint(x: x, y: y + H))
        path.addLine(to: CGPoint(x: x, y: y + R))
        path.addQuadCurve(to: CGPoint(x: x + R, y: y), controlPoint: CGPoint(x: x, y: y))
        path.close()
        path.flatness = R * 0.02
        return path
    }

    static func color(_ hex: UInt) -> UIColor {
        UIColor(Color(hex: hex))
    }

    static func std(_ hex: UInt, roughness: CGFloat = 0.55, metalness: CGFloat = 0.02) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color(hex)
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    static func basic(_ hex: UInt) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color(hex)
        return m
    }

    private static func screenPlane(_ w: CGFloat, _ h: CGFloat, image: UIImage) -> SCNNode {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        return screenPlane(w, h, material: m)
    }

    private static func screenPlane(_ w: CGFloat, _ h: CGFloat, material: SCNMaterial) -> SCNNode {
        let plane = SCNPlane(width: w, height: h)
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.castsShadow = false
        return node
    }

    /// 本机屏幕：干净的终端字（不加扫描线），圆角，不画灵动岛
    private static func cleanTerminal(width: CGFloat, height: CGFloat, radius: CGFloat) -> UIImage {
        let tall = height > width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let cg = context.cgContext
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: radius).addClip()
            let colors = [color(0x1d2420).cgColor, color(0x121614).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
            }
            let font = UIFont(name: "Menlo", size: tall ? 15 : 16) ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
            let lines = ["~ $ uname -sm", "Linux aarch64", "~ $ ls", tall ? "notes  topics" : "notes  topics  garden", "~ $ █"]
            for (i, line) in lines.enumerated() {
                let ink = i % 2 == 1 ? color(0xd6d0c8) : color(C.mint)
                let baseline: CGFloat = tall ? 96 + CGFloat(i) * 26 : 58 + CGFloat(i) * 34
                (line as NSString).draw(at: CGPoint(x: tall ? 20 : 26, y: baseline - font.ascender),
                                        withAttributes: [.font: font, .foregroundColor: ink])
            }
            // 小企鹅图标
            let center = tall ? CGPoint(x: 120, y: 380) : CGPoint(x: 318, y: 150)
            let k: CGFloat = tall ? 1 : 1.15
            cg.setFillColor(color(0xe8e2d8).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - 26 * k, y: center.y - 32 * k, width: 52 * k, height: 64 * k))
            cg.setFillColor(color(0x1d1b19).cgColor)
            let head = UIBezierPath()
            head.addArc(withCenter: .zero, radius: 1, startAngle: .pi * 0.95, endAngle: .pi * 2.05, clockwise: true)
            head.apply(CGAffineTransform(translationX: center.x, y: center.y - 8 * k).scaledBy(x: 30 * k, y: 40 * k))
            head.fill()
            cg.setFillColor(color(C.tuxOrange).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - 7 * k, y: center.y - 28 * k - 4 * k, width: 14 * k, height: 8 * k))
        }
    }

    private static func plusImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { _ in
            let font = UIFont(name: "Georgia", size: 90) ?? .systemFont(ofSize: 90)
            let text = "+" as NSString
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: 64 - size.width / 2, y: 94 - font.ascender),
                      withAttributes: [.font: font, .foregroundColor: color(0x9a938a)])
        }
    }

    // MARK: 几何

    /// three.js CatmullRomCurve3（centripetal）的 getPoint(t)：按参数取点，不按弧长
    static func catmullRom(_ points: [SIMD3<Float>], _ t: Float) -> SIMD3<Float> {
        let l = points.count
        let p = Float(l - 1) * t
        var index = Int(p.rounded(.down))
        var weight = p - Float(index)
        if index >= l - 1 { index = l - 2; weight = 1 }
        let p0 = index > 0 ? points[index - 1] : 2 * points[0] - points[1]
        let p1 = points[index], p2 = points[index + 1]
        let p3 = index + 2 < l ? points[index + 2] : 2 * points[l - 1] - points[l - 2]
        var dt0 = pow(simd_distance_squared(p0, p1), 0.25)
        var dt1 = pow(simd_distance_squared(p1, p2), 0.25)
        var dt2 = pow(simd_distance_squared(p2, p3), 0.25)
        if dt1 < 1e-4 { dt1 = 1 }
        if dt0 < 1e-4 { dt0 = dt1 }
        if dt2 < 1e-4 { dt2 = dt1 }
        var t1 = (p1 - p0) / dt0 - (p2 - p0) / (dt0 + dt1) + (p2 - p1) / dt1
        var t2 = (p2 - p1) / dt1 - (p3 - p1) / (dt1 + dt2) + (p3 - p2) / dt2
        t1 *= dt1
        t2 *= dt1
        let c2 = -3 * p1 + 3 * p2 - 2 * t1 - t2
        let c3 = 2 * p1 - 2 * p2 + t1 + t2
        return p1 + t1 * weight + c2 * weight * weight + c3 * weight * weight * weight
    }

    /// three.js SplineCurve（均匀 Catmull-Rom）的 getPoint(t)
    private static func spline(_ points: [SIMD2<Float>], _ t: Float) -> SIMD2<Float> {
        let p = Float(points.count - 1) * t
        let index = Int(p.rounded(.down))
        let weight = p - Float(index)
        let p0 = points[index == 0 ? index : index - 1]
        let p1 = points[index]
        let p2 = points[min(index + 1, points.count - 1)]
        let p3 = points[min(index + 2, points.count - 1)]
        let v0 = (p2 - p0) * 0.5, v1 = (p3 - p1) * 0.5
        let w2 = weight * weight, w3 = w2 * weight
        let a: SIMD2<Float> = 2 * p1 - 2 * p2 + v0 + v1
        let b: SIMD2<Float> = -3 * p1 + 3 * p2 - 2 * v0 - v1
        return a * w3 + b * w2 + v0 * weight + p1
    }

    /// 细管：沿采样点一圈 8 个顶点。返回元素好按珠子数截一段画（primitiveRange）
    static func tube(_ points: [SIMD3<Float>], radius: Float, material: SCNMaterial) -> (SCNGeometry, SCNGeometryElement) {
        let ring = 8
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt32] = []
        for (i, point) in points.enumerated() {
            let ahead = points[min(i + 1, points.count - 1)], behind = points[max(i - 1, 0)]
            let tangent = simd_normalize(ahead - behind)
            let reference: SIMD3<Float> = abs(tangent.y) > 0.9 ? [1, 0, 0] : [0, 1, 0]
            let n = simd_normalize(simd_cross(tangent, reference))
            let b = simd_cross(tangent, n)
            for k in 0..<ring {
                let angle = Float(k) / Float(ring) * 2 * .pi
                let dir = cos(angle) * n + sin(angle) * b
                let v = point + dir * radius
                vertices.append(SCNVector3(v.x, v.y, v.z))
                normals.append(SCNVector3(dir.x, dir.y, dir.z))
            }
        }
        for i in 0..<(points.count - 1) {
            for k in 0..<ring {
                let a = UInt32(i * ring + k), b = UInt32(i * ring + (k + 1) % ring)
                let c = a + UInt32(ring), d = b + UInt32(ring)
                indices += [a, c, b, b, c, d]
            }
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [element])
        material.isDoubleSided = true
        geometry.materials = [material]
        return (geometry, element)
    }

    /// 旋转体（three LatheGeometry）：轮廓 (r, y) 绕 y 轴转一圈
    private static func lathe(_ profile: [SIMD2<Float>], segments: Int, material: SCNMaterial) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt32] = []
        for s in 0...segments {
            let angle = Float(s) / Float(segments) * 2 * .pi
            let sn = sin(angle), cs = cos(angle)
            for (i, p) in profile.enumerated() {
                let ahead = profile[min(i + 1, profile.count - 1)], behind = profile[max(i - 1, 0)]
                let tangent = ahead - behind
                let n2 = simd_normalize(SIMD2(tangent.y, -tangent.x))
                vertices.append(SCNVector3(p.x * sn, p.y, p.x * cs))
                normals.append(SCNVector3(n2.x * sn, n2.y, n2.x * cs))
            }
        }
        let rows = profile.count
        for s in 0..<segments {
            for i in 0..<(rows - 1) {
                let a = UInt32(s * rows + i), b = a + UInt32(rows)
                indices += [a, b, a + 1, b, b + 1, a + 1]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    /// 一体机的 CRT：中间鼓起来的屏（1.3 × 0.96，32 × 24 格）
    private static func crtGeometry() -> SCNGeometry {
        let cols = 32, rows = 24
        let w: Float = 1.3, h: Float = 0.96, bulge: Float = 0.06
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uvs: [CGPoint] = [], indices: [UInt32] = []
        for j in 0...rows {
            for i in 0...cols {
                let u = Float(i) / Float(cols), v = Float(j) / Float(rows)
                let px = (u - 0.5) * w, py = (0.5 - v) * h
                let x = px / 0.65, y = py / 0.48
                let fx = 1 - 0.55 * x * x, fy = 1 - 0.55 * y * y
                let dzdx = bulge * (-1.1 * x / 0.65) * fy, dzdy = bulge * fx * (-1.1 * y / 0.48)
                let n = simd_normalize(SIMD3(-dzdx, -dzdy, 1))
                vertices.append(SCNVector3(px, py, bulge * fx * fy))
                normals.append(SCNVector3(n.x, n.y, n.z))
                uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }
        for j in 0..<rows {
            for i in 0..<cols {
                let a = UInt32(j * (cols + 1) + i), b = a + 1, c = a + UInt32(cols + 1), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// 盒子的 12 条棱拆成虚线（dash 0.07 / gap 0.06）
    private static func dashedBox(_ w: Float, _ h: Float, _ d: Float, material: SCNMaterial) -> SCNGeometry {
        let x = w / 2, y = h / 2, z = d / 2
        let corners: [SIMD3<Float>] = [[-x, -y, -z], [x, -y, -z], [x, y, -z], [-x, y, -z], [-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var vertices: [SCNVector3] = []
        for (a, b) in edges {
            let start = corners[a], end = corners[b]
            let length = simd_distance(start, end), dir = (end - start) / length
            var s: Float = 0
            while s < length {
                let e = min(s + 0.07, length)
                let p = start + dir * s, q = start + dir * e
                vertices += [SCNVector3(p.x, p.y, p.z), SCNVector3(q.x, q.y, q.z)]
                s += 0.13
            }
        }
        let element = SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .line)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        geometry.materials = [material]
        return geometry
    }
}
#endif
