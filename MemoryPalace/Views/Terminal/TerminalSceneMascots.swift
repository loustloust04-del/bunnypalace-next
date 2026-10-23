#if os(iOS)
import SceneKit
import UIKit

/// 吉祥物的脸：x.x = 没连上 / 正常 = 连着 / ^ ^ = 有事找你或跑完了
enum TerminalMascotFace {
    case dead, normal, happy
}

/// 坐在电脑上的吉祥物：外层 `root` 管浮动，里层 `body` 死掉时歪一点塌一点，三张脸只换眼睛那几格
final class TerminalMascotNode {
    let root = SCNNode()
    private let body = SCNNode()
    private let faces: [TerminalMascotFace: SCNNode]
    private let slump: Float
    private var face: TerminalMascotFace?

    private init(body parts: SCNNode, faces: [TerminalMascotFace: SCNNode], slump: Float) {
        self.faces = faces
        self.slump = slump
        root.addChildNode(body)
        body.addChildNode(parts)
        for node in faces.values { body.addChildNode(node) }
        setFace(.normal)
    }

    func setFace(_ new: TerminalMascotFace) {
        guard new != face else { return }
        face = new
        for (key, node) in faces { node.isHidden = key != new }
        body.eulerAngles.z = new == .dead ? slump : 0
        body.scale.y = new == .dead ? 0.94 : 1
    }

    // MARK: Clawd

    /// Clawd：Claude Code 2.1.291 启动画面的字符画（▐▛███▛█ / ▝▜█████▀ / ▝▝ ▝▝），四分块一格拆成一个像素；
    /// 身体色 clawd_body = rgb(215,119,87)。四分块像素是竖长的（终端字格 1:2），y 方向一格 = 2 个 x 单位
    private static let clawd = ["..#############..", "..##e#######e##..", "#################", "..#############..", "..#.#.......#.#.."]
    private static let eyeX = ["#.#", ".#.", "#.#"], eyeUp = [".#.", "#.#"]

    /// h = 身高（含腿）
    static func clawd(height h: Float) -> TerminalMascotNode {
        let ux = h / 10, uy = ux * 2
        let w = clawd[0].count, rows = clawd.count
        let body = linear(0xD77757)
        var boxes: [Voxel] = []
        for (y, row) in clawd.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                let depth: Float = (y == 2 && (x < 2 || x > 14) ? 5 : y == 4 ? 5 : 8) * ux
                boxes.append(Voxel(center: [(Float(x) - Float(w - 1) / 2) * ux, (Float(rows - 1 - y) + 0.5) * uy, 0],
                                   size: [ux, uy, depth], color: body))
            }
        }
        let black: SIMD3<Float> = .zero
        // 正常：原图那两道竖眼（一格四分块像素，1:2）
        let normal = [Float(4), 12].map { x in
            Voxel(center: [(x - 8) * ux, 3.5 * uy, 4 * ux], size: [ux, uy, ux * 0.3], color: black)
        }
        // × × / ^ ^：同一个眼位，用小一号的方块拼
        let px = ux * 0.62
        func eyes(_ pattern: [String], _ cy: Float) -> [Voxel] {
            [Float(-4), 4].flatMap { ex in
                stamp(pattern, 1, 1).map { i, j in
                    Voxel(center: [ex * ux + Float(i - 1) * px, cy * ux - Float(j - 1) * px, 4 * ux],
                          size: [px, px, ux * 0.3], color: black)
                }
            }
        }
        return TerminalMascotNode(
            body: SCNNode(geometry: voxelGeometry(boxes)),
            faces: [.normal: SCNNode(geometry: voxelGeometry(normal)),
                    .dead: SCNNode(geometry: voxelGeometry(eyes(eyeX, 7.3))),
                    .happy: SCNNode(geometry: voxelGeometry(eyes(eyeUp, 7.6)))],
            slump: 0.13)
    }

    // MARK: Codex companion

    /// Codex：ChatGPT.app 自带 codex-spritesheet-v6 第一帧（The original Codex companion），4px 一格取色
    private static let codex = [
        ".............oooo...................",
        "...........ooaaaaaoo..ooo...........",
        "..........oaaaaaaaaaooaaaoo.........",
        ".........oaaaaaaaaaaaaaaaaao........",
        "........oaaaaaaaaaaaaaaaaaaao.......",
        "........aaaaaaaaaaaaaaaaaaaaao......",
        ".......oaaaaaaaaaaaaaaaaaaaaaao.....",
        ".....ooobaaaaaaaaaaaaaaaaaaaaao.....",
        "....oaaaaaaaaaaaaaaaaaaaaaaaaaoo....",
        "...aaaaaaaaaaaaaaaaaaaaaaaaaaaaao...",
        "..oaaaaaaaaaaaaaaaaaaaaaaaaaaaaaao..",
        ".obbaaaaaaaaaaaaaaaaaaaaaaaaaaaaaao.",
        ".obbbaaaaaasssssssssssssssssaaaaaao.",
        "ocbbbbaaaasssssssssssssssssssaaaaaao",
        "ocbbbbbaassssssssssssssssssssoaaaaao",
        "occbbbbbbssssysssssssssssssssoaaaaao",
        "occcbbbbbssssyyssssssssssssssoobbbbo",
        "occcbbbbbsssssyysssssssssssssoobbbbo",
        "occccccbcssssssyyssssssssssssobbbbbo",
        "ooccccbbbssssssyyssssssssssssobbbbco",
        ".oocbbbbbssssyyyssssssyyyyyssobbbbo.",
        "..ocbbbbbssssyyssssssssssssssobbbbo.",
        "..ocbbbbbssssssssssssssssssssobbbbo.",
        "..occcbbbssssssssssssssssssssobbbco.",
        "..occcccbbosssssssssssssssssobbbbco.",
        "...occcccbbcoooooooooooooosbbbbcco..",
        "....occccccbbbbbbbbbbbbbbbbbbccco...",
        "....oocccccccbbbbbbbbbbbbbccccco....",
        "......ooocccccccccccccccccccoo......",
        "........oooooooooooooooooooo........",
        ".......occcoccccccccccccccdco.......",
        "......occbcocbbbwbbbbbbbbbocbo......",
        ".....oocbboccbbbbwwbbbbbbbocbbo.....",
        ".....ocbbbocccbbbwwbwwwwbbocbbo.....",
        ".....ccbbbdcccbbwbbbbbbbbbocbbbo....",
        "....occbbboccccbbbbbbbbbbbocbbbo....",
        "....occbbcodcccccccccccccooccbbo....",
        ".....occco.occcccccccccoso.occo.....",
        "......ooo..occcoooooosocco..ooo.....",
        "...........ocbbbco.occbbco..........",
        "...........ocbbbbo.occbco...........",
        "...........odcccc..odccco...........",
        "............ooooo..oooooo...........",
    ]
    private static let codexPalette: [Character: UInt] = [
        "a": 0x6c99fa, "b": 0x5a85f7, "c": 0x486ce4, "d": 0x2c4092, "o": 0x0c0e28, "s": 0x232d66, "y": 0x9dfcff, "w": 0xf6fafe,
    ]
    private static let codexX = ["##..##", ".####.", "..##..", ".####.", "##..##"], codexUp = ["..##..", ".####.", "##..##"]

    static func codex(height h: Float) -> TerminalMascotNode {
        let u = h / Float(codex.count)
        let w = codex[0].count, rows = codex.count
        let dist = edgeDistance(codex)
        func depth(_ x: Int, _ y: Int) -> Float { min(24, 3 + Float(dist[y][x]) * 2.4) * u }
        func voxel(_ x: Int, _ y: Int, _ color: SIMD3<Float>, grow: Float) -> Voxel {
            Voxel(center: [(Float(x) - Float(w - 1) / 2) * u, (Float(rows - 1 - y) + 0.5) * u, 0],
                  size: [u, u, depth(x, y) + grow], color: color)
        }
        var base: [Voxel] = [], screenFace: [Voxel] = []
        let cyan = linear(0x9dfcff)
        for (y, row) in codex.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                // 屏上的青色 > _ 抽出来当「正常脸」，底图那几格还原成面罩色
                if ch == "y" {
                    screenFace.append(voxel(x, y, cyan, grow: u * 0.15))
                    base.append(voxel(x, y, linear(codexPalette["s"] ?? 0), grow: 0))
                } else {
                    base.append(voxel(x, y, linear(codexPalette[ch] ?? 0), grow: 0))
                }
            }
        }
        func eyes(_ pattern: [String]) -> [Voxel] {
            (stamp(pattern, 14, 18) + stamp(pattern, 24, 18)).map { voxel($0.0, $0.1, cyan, grow: u * 0.15) }
        }
        return TerminalMascotNode(
            body: SCNNode(geometry: voxelGeometry(base)),
            faces: [.normal: SCNNode(geometry: voxelGeometry(screenFace)),
                    .dead: SCNNode(geometry: voxelGeometry(eyes(codexX))),
                    .happy: SCNNode(geometry: voxelGeometry(eyes(codexUp)))],
            slump: -0.11)
    }

    // MARK: 体素

    private struct Voxel {
        let center: SIMD3<Float>
        let size: SIMD3<Float>
        let color: SIMD3<Float>
    }

    private static func stamp(_ pattern: [String], _ cx: Int, _ cy: Int) -> [(Int, Int)] {
        pattern.enumerated().flatMap { j, row in
            row.enumerated().compactMap { i, ch in
                ch == "#" ? (cx - row.count / 2 + i, cy - pattern.count / 2 + j) : nil
            }
        }
    }

    /// 到轮廓的格数（4 邻域），给 Codex 一个鼓起来的厚度
    private static func edgeDistance(_ rows: [String]) -> [[Int]] {
        let grid = rows.map(Array.init)
        let h = grid.count, w = grid[0].count
        var d = grid.map { $0.map { $0 == "." ? 0 : 99 } }
        for pass in 0..<2 {
            for y in 0..<h {
                for x in 0..<w {
                    let yy = pass == 1 ? h - 1 - y : y, xx = pass == 1 ? w - 1 - x : x
                    guard d[yy][xx] != 0 else { continue }
                    let neighbours = pass == 1 ? [(yy + 1, xx), (yy, xx + 1)] : [(yy - 1, xx), (yy, xx - 1)]
                    for (a, b) in neighbours {
                        let outside = a < 0 || b < 0 || a >= h || b >= w
                        d[yy][xx] = min(d[yy][xx], outside ? 1 : d[a][b] + 1)
                    }
                }
            }
        }
        return d
    }

    /// 原图是 sRGB 色值，换成线性才对得上原色
    private static func linear(_ hex: UInt) -> SIMD3<Float> {
        func channel(_ shift: UInt) -> Float {
            let c = Float((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return [channel(16), channel(8), channel(0)]
    }

    /// 同一只的所有方块并成一个几何（顶点色），几百格也只是一个节点、一次绘制
    private static func voxelGeometry(_ voxels: [Voxel]) -> SCNGeometry {
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        var positions: [SCNVector3] = [], normals: [SCNVector3] = [], colors: [Float] = [], indices: [UInt32] = []
        positions.reserveCapacity(voxels.count * 24)
        for voxel in voxels {
            let half = voxel.size / 2
            for face in faces {
                let base = UInt32(positions.count)
                let center = voxel.center + face.normal * half
                for (su, sv) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                    let p = center + face.u * half * su + face.v * half * sv
                    positions.append(SCNVector3(p.x, p.y, p.z))
                    normals.append(SCNVector3(face.normal.x, face.normal.y, face.normal.z))
                    colors += [voxel.color.x, voxel.color.y, voxel.color.z]
                }
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count / 3,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), colorSource],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor.white
        material.roughness.contents = 0.62
        material.metalness.contents = 0.02
        geometry.materials = [material]
        return geometry
    }
}
#endif
