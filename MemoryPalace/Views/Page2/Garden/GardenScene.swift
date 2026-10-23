import Foundation

// 花园四季壁纸的体素场景：照 docs/design-garden-seasons-wallpaper.html 逐项移植，哈希按位对齐 JS（Math.imul = UInt32 &*）
typealias GardenRGB = SIMD3<Double>

enum GardenMath {
    static func hash(_ x: Int, _ y: Int, _ z: Int = 0, _ k: Int = 0) -> Double {
        var h = (UInt32(truncatingIfNeeded: x) &* 374_761_393)
            ^ (UInt32(truncatingIfNeeded: y) &* 668_265_263)
            ^ (UInt32(truncatingIfNeeded: z) &* 1_440_662_683)
            ^ (UInt32(truncatingIfNeeded: k) &* 2_246_822_519)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }
    static func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, v)) }
    static func smooth(_ e0: Double, _ e1: Double, _ v: Double) -> Double {
        let t = clamp((v - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }
    static func mix(_ a: GardenRGB, _ b: GardenRGB, _ t: Double) -> GardenRGB { a + (b - a) * t }
    static func hex(_ s: String) -> GardenRGB {
        let v = Int(s.dropFirst(), radix: 16) ?? 0
        return GardenRGB(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF)) / 255
    }
}

enum GardenMat: Int, CaseIterable {
    case grass, tufa, trav, trav2, water, marble, marble2, statue, plinth, brick, brick2, trunk, spine, spine2, cypress, box, almond, almond2, bronze, fire
}

struct GardenMaterial {
    let colors: [GardenRGB]
    var snowy = false
    var grass = false
    var water = false
    var leaf = false
    var glow: GardenRGB?

    func color(_ sw: GardenSeasonWeights) -> GardenRGB {
        colors.count == 1 ? colors[0] : GardenMath.mix(colors[sw.i0], colors[sw.i1], sw.w)
    }

    static let table: [GardenMaterial] = GardenMat.allCases.map { m in
        let h = { (s: [String]) in s.map(GardenMath.hex) }
        switch m {
        case .grass: return GardenMaterial(colors: h(["#c2d0b2", "#b9c8a9", "#cdc1a8", "#c5c6bb"]), snowy: true, grass: true)
        case .tufa: return GardenMaterial(colors: h(["#cfc1aa"]))
        case .trav: return GardenMaterial(colors: h(["#ede5d5"]), snowy: true)
        case .trav2: return GardenMaterial(colors: h(["#e3d9c7"]), snowy: true)
        case .water: return GardenMaterial(colors: h(["#a8c4a9", "#9fbea0", "#b0bba5", "#bcc3c0"]), water: true)
        case .marble: return GardenMaterial(colors: h(["#f4f0e7"]))
        case .marble2: return GardenMaterial(colors: h(["#e5ded0"]), snowy: true)
        case .statue: return GardenMaterial(colors: h(["#f7f3eb"]), snowy: true)
        case .plinth: return GardenMaterial(colors: h(["#d8cfc0"]), snowy: true)
        case .brick: return GardenMaterial(colors: h(["#bf8a73"]), snowy: true)
        case .brick2: return GardenMaterial(colors: h(["#ab7864"]), snowy: true)
        case .trunk: return GardenMaterial(colors: h(["#8d7160"]))
        case .spine: return GardenMaterial(colors: h(["#8ba690", "#84a18b", "#87a18c", "#89a18d"]), snowy: true)
        case .spine2: return GardenMaterial(colors: h(["#97b09b", "#90ab96", "#93ab97", "#95ab98"]), snowy: true)
        case .cypress: return GardenMaterial(colors: h(["#809b87", "#7b9783", "#7d9684", "#7f9786"]), snowy: true)
        case .box: return GardenMaterial(colors: h(["#a2bb9c", "#9ab696", "#a5b097", "#a6af9e"]), snowy: true)
        case .almond: return GardenMaterial(colors: h(["#f1cad0", "#a9c59f", "#d99b7b", "#d99b7b"]), snowy: true, leaf: true)
        case .almond2: return GardenMaterial(colors: h(["#e7b5bd", "#9dbd95", "#cc8681", "#cc8681"]), snowy: true, leaf: true)
        case .bronze: return GardenMaterial(colors: h(["#8e7360"]))
        case .fire: return GardenMaterial(colors: h(["#9c7d68"]), glow: GardenMath.hex("#f4b88b"))
        }
    }
}

struct GardenVoxel {
    let x: Int, y: Int, z: Int
    var mat: GardenMat
    let r: Double
    var obj: Bool
    let cell: Int
}

struct GardenFlower {
    let a: Double, b: Double, ox: Double, oy: Double
}

final class GardenScene: Sendable {
    static let shared = GardenScene()

    static let n = 112, zOff = 4, zSize = 32
    static func cell(_ x: Int, _ y: Int, _ z: Int) -> Int { ((z + zOff) * n + y) * n + x }
    static func inBounds(_ x: Int, _ y: Int, _ z: Int) -> Bool { x >= 0 && y >= 0 && x < n && y < n && z >= -zOff && z < zSize - zOff }

    let terrain: [GardenVoxel]
    let objects: [GardenVoxel]
    let mirror: [GardenVoxel]
    let staticOcc: [UInt8]
    let leaves: [(cell: Int, r: Double)]
    let flowers: [Int: GardenFlower]
    let isPool: [Bool]
    let fires: [SIMD3<Double>]
    let waterCells: [(x: Int, y: Int)]
    let waterU: (lo: Int, hi: Int)

    private enum Tag { case none, pool, trav, col, statue, brazier, tree, ruin, hedge, bed }

    private init() {
        let n = Self.n
        var vmap: [Int: GardenVoxel] = [:]
        var topH = Array(repeating: Array(repeating: 0, count: n), count: n)
        var tag = Array(repeating: Array(repeating: Tag.none, count: n), count: n)
        func hash(_ x: Int, _ y: Int, _ z: Int = 0, _ k: Int = 0) -> Double { GardenMath.hash(x, y, z, k) }
        func tagAt(_ x: Int, _ y: Int) -> Tag? { x >= 0 && y >= 0 && x < n && y < n ? tag[x][y] : nil }
        func put(_ x: Int, _ y: Int, _ z: Int, _ m: GardenMat, _ obj: Bool = false) {
            guard Self.inBounds(x, y, z) else { return }
            let i = Self.cell(x, y, z)
            if var v = vmap[i] { v.mat = m; v.obj = obj; vmap[i] = v; return }
            vmap[i] = GardenVoxel(x: x, y: y, z: z, mat: m, r: hash(x, y, z, 11), obj: obj, cell: i)
        }
        func putO(_ x: Int, _ y: Int, _ z: Int, _ m: GardenMat) { put(x, y, z, m, true) }
        func free(_ x: Int, _ y: Int, _ z: Int) -> Bool { Self.inBounds(x, y, z) && vmap[Self.cell(x, y, z)] == nil }

        // 池子：x 12..38、y 12..29 的长方形，左端接半圆
        let pc = (12.0, 21.0)
        func terrH(_ y: Int) -> Int { y >= 7 ? 0 : min(5, Int((Double(7 - y) / 1.4).rounded(.up))) }
        func isWater(_ x: Int, _ y: Int) -> Bool {
            (x >= 12 && x <= 38 && y >= 12 && y <= 29)
                || (x < 12 && pow(Double(x) + 0.5 - pc.0, 2) + pow(Double(y) + 0.5 - pc.1, 2) < 81)
        }
        for x in 0..<n { for y in 0..<n {
            if isWater(x, y) { put(x, y, -1, .water); topH[x][y] = -1; tag[x][y] = .pool; continue }
            let h = terrH(y)
            for z in 0...h { put(x, y, z, z == h ? .grass : .tufa) }
            topH[x][y] = h
        } }
        for x in 0..<n { for y in 0..<n {
            guard tag[x][y] == .none else { continue }
            var near = false
            for dx in -2...2 where !near { for dy in -2...2 where tagAt(x + dx, y + dy) == .pool { near = true; break } }
            let onAxis = x >= 24 && x <= 26 && y >= 32
            if near || onAxis { put(x, y, topH[x][y], (x + y) % 2 == 1 ? .trav : .trav2); tag[x][y] = .trav }
        } }

        // 柱子：底座 + 6 节柱身 + 柱头；返回梁的高度
        func column(_ x: Int, _ y: Int) -> Int {
            let b = topH[x][y] + 1
            putO(x, y, b, .marble2)
            for z in (b + 1)...(b + 6) { putO(x, y, z, .marble) }
            putO(x, y, b + 7, .marble2)
            tag[x][y] = .col
            return b + 8
        }
        func statue(_ x: Int, _ y: Int) {
            let b = topH[x][y] + 1
            putO(x, y, b, .plinth)
            for z in (b + 1)...(b + 4) { putO(x, y, z, .statue) }
            if hash(x, y, 0, 15) < 0.5 { putO(x + 1, y, b + 3, .statue) } else { putO(x, y + 1, b + 3, .statue) }
            tag[x][y] = .statue
        }
        // 远侧长边柱廊：拱（高）与平梁（低）交替
        let lx = [12, 17, 22, 27, 32, 37, 42]
        var beam = 13
        for x in lx { beam = column(x, 9) }
        let top = beam + 2
        for k in 0..<(lx.count - 1) {
            let x0 = lx[k]
            if k % 2 == 0 {
                let open = [0, beam, beam + 1, beam + 1, beam, 0]
                for i in 0...5 { for z in (i == 0 || i == 5 ? beam : open[i])...top { putO(x0 + i, 9, z, .marble2) } }
            } else {
                for i in 0...5 { putO(x0 + i, 9, beam, .marble2) }
                statue(x0 + 2, 9)
            }
        }
        // 左端半圆柱廊
        var ring: [(x: Int, y: Int, a: Double)] = []
        for x in 0..<15 { for y in 6..<38 {
            if Double(x) + 0.5 >= pc.0 + 0.2 || tag[x][y] == .col { continue }
            let d = hypot(Double(x) + 0.5 - pc.0, Double(y) + 0.5 - pc.1)
            if d >= 11.6 && d < 12.6 {
                let a = (atan2(Double(y) + 0.5 - pc.1, Double(x) + 0.5 - pc.0) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
                ring.append((x, y, a))
            }
        } }
        ring.sort { $0.a < $1.a }
        for (i, c) in ring.enumerated() {
            if i % 3 == 0 { _ = column(c.x, c.y) }
            putO(c.x, c.y, beam, .marble2)
            if (i / 3) % 2 == 0 && i % 3 != 0 { putO(c.x, c.y, beam + 1, .marble2); putO(c.x, c.y, beam + 2, .marble2) }
        }
        for deg in [140.0, 170, 200, 230] {
            let a = deg * .pi / 180
            statue(Int((pc.0 + 10.4 * cos(a)).rounded(.down)), Int((pc.1 + 10.4 * sin(a)).rounded(.down)))
        }
        statue(18, 31); statue(33, 31)
        // 池中那只石鳄鱼
        for x in 23...27 { putO(x, 20, 0, .statue) }
        putO(28, 20, 0, .plinth); putO(22, 20, 0, .plinth)
        // 火盆
        for (x, y) in [(15, 31), (36, 31)] { putO(x, y, 1, .bronze); putO(x, y, 2, .bronze); putO(x, y, 3, .fire); tag[x][y] = .brazier }

        // 伞松：高树干微斜，顶上一张扁平的冠
        func stonePine(_ tx: Int, _ ty: Int, _ lean: (Int, Int)) {
            let b = topH[tx][ty] + 1; tag[tx][ty] = .tree
            var x = tx, y = ty
            for k in 0..<15 { if k == 6 || k == 11 { x += lean.0; y += lean.1 }; putO(x, y, b + k, .trunk) }
            let c = (Double(x) + 0.5, Double(y) + 0.5, Double(b + 16))
            for dx in -7...7 { for dy in -7...7 { for dz in -2...3 {
                let X = x + dx, Y = y + dy, Z = b + 15 + dz
                guard free(X, Y, Z) else { continue }
                let e = pow((Double(X) + 0.5 - c.0) / 6.2, 2) + pow((Double(Y) + 0.5 - c.1) / 6.2, 2) + pow((Double(Z) + 0.5 - c.2) / 2.1, 2)
                if e < 1 - hash(X, Y, Z, 5) * 0.3 { putO(X, Y, Z, hash(X, Y, Z, 6) < 0.5 ? .spine : .spine2) }
            } } }
        }
        // 柏树：细高的火苗形
        func cypress(_ tx: Int, _ ty: Int, _ len: Int) {
            let b = topH[tx][ty] + 1; tag[tx][ty] = .tree
            putO(tx, ty, b, .trunk)
            for k in 1...len {
                let z = b + k, f = Double(k) / Double(len)
                putO(tx, ty, z, .cypress)
                if f > 0.08 && f < 0.8 {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where hash(tx + dx, ty + dy, z, 9) > 0.15 && free(tx + dx, ty + dy, z) { putO(tx + dx, ty + dy, z, .cypress) }
                }
                if f > 0.2 && f < 0.6 {
                    for (dx, dy) in [(1, 1), (-1, 1), (1, -1), (-1, -1)] where hash(tx + dx, ty + dy, z, 10) > 0.55 && free(tx + dx, ty + dy, z) { putO(tx + dx, ty + dy, z, .cypress) }
                }
            }
        }
        // 杏树：会开花、会落叶
        func almond(_ tx: Int, _ ty: Int) {
            let b = topH[tx][ty] + 1; tag[tx][ty] = .tree
            for z in b...(b + 4) { putO(tx, ty, z, .trunk) }
            for (dx, dy, dz) in [(1, 0, 5), (-1, 0, 5), (0, 1, 6), (0, -1, 6), (2, 0, 6), (-1, 1, 7)] { putO(tx + dx, ty + dy, b + dz, .trunk) }
            let c = (Double(tx) + 0.5, Double(ty) + 0.5, Double(b) + 7.5)
            for dx in -5...5 { for dy in -5...5 { for dz in -3...4 {
                let X = tx + dx, Y = ty + dy, Z = b + 7 + dz
                guard free(X, Y, Z) else { continue }
                let d = (pow(Double(X) + 0.5 - c.0, 2) + pow(Double(Y) + 0.5 - c.1, 2) + pow((Double(Z) + 0.5 - c.2) * 1.25, 2)).squareRoot()
                if d < 3.6 + hash(X, Y, Z, 7) * 0.9 { putO(X, Y, Z, hash(X, Y, Z, 8) < 0.5 ? .almond : .almond2) }
            } } }
        }
        // 砖墙废墟（后坡上那堵）
        for x in 24...33 { for y in 1...4 {
            let ruinTop = 17 - Int((hash(x, y, 0, 12) * 4).rounded(.down)) - (x == 33 || y == 1 ? 3 : 0) - (x >= 31 ? 2 : 0)
            if topH[x][y] + 1 <= ruinTop {
                for z in (topH[x][y] + 1)...ruinTop {
                    let niche = y == 4 && [26, 27, 29, 30].contains(x) && z >= 8 && z <= 12
                    if !niche { putO(x, y, z, hash(x, y, z, 13) < 0.6 ? .brick : .brick2) }
                }
            }
            if hash(x, y, 0, 14) < 0.35 { putO(x, y, ruinTop + 1, .box) }
            tag[x][y] = .ruin
        } }
        stonePine(18, 3, (1, 0))
        stonePine(45, 3, (0, 1))
        stonePine(3, 5, (1, 1))
        for (i, p) in [(9, 6), (14, 5), (39, 5), (50, 6), (56, 9), (0, 3)].enumerated() { cypress(p.0, p.1, 17 - (i % 3) * 2) }
        almond(47, 18)
        almond(6, 40)
        // 花坛：黄杨矮篱围一圈，里面点点花，中间一棵圆锥修剪树
        func parterre(_ x0: Int, _ y0: Int, _ w: Int) {
            for x in x0...(x0 + w) { for y in y0...(y0 + w) {
                if x == x0 || x == x0 + w || y == y0 || y == y0 + w { putO(x, y, 1, .box); tag[x][y] = .hedge } else { tag[x][y] = .bed }
            } }
            let cx = x0 + w / 2, cy = y0 + w / 2
            for z in 1...4 { putO(cx, cy, z, .box) }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { putO(cx + dx, cy + dy, 1, .box); putO(cx + dx, cy + dy, 2, .box) }
            tag[cx][cy] = .hedge
        }
        parterre(14, 36, 8)
        parterre(29, 36, 8)

        // 点点花
        var flowers: [Int: GardenFlower] = [:]
        for x in 0..<n { for y in 0..<n {
            let tg = tag[x][y]
            if tg != .none && tg != .bed { continue }
            if topH[x][y] < 0 { continue }
            if hash(x, y, 0, 21) < (tg == .bed ? 0.7 : 0.05) {
                flowers[Self.cell(x, y, topH[x][y])] = GardenFlower(a: hash(x, y, 0, 22), b: hash(x, y, 0, 23), ox: hash(x, y, 0, 24) - 0.5, oy: hash(x, y, 0, 25) - 0.5)
            }
        } }

        let all = Array(vmap.values)
        let order: (GardenVoxel, GardenVoxel) -> Bool = { a, b in
            let ka = a.x + a.y + a.z, kb = b.x + b.y + b.z
            return ka != kb ? ka < kb : a.z < b.z
        }
        terrain = all.filter { !$0.obj }.sorted(by: order)
        objects = all.filter { $0.obj }.sorted(by: order)
        mirror = objects.sorted { ($0.x + $0.y - $0.z) < ($1.x + $1.y - $1.z) }
        var occ = [UInt8](repeating: 0, count: n * n * Self.zSize)
        for v in all where !GardenMaterial.table[v.mat.rawValue].leaf { occ[v.cell] = 1 }
        staticOcc = occ
        leaves = all.filter { GardenMaterial.table[$0.mat.rawValue].leaf }.map { ($0.cell, $0.r) }
        self.flowers = flowers
        isPool = (0..<(n * n)).map { tag[$0 % n][$0 / n] == .pool }
        fires = all.filter { GardenMaterial.table[$0.mat.rawValue].glow != nil }.map { SIMD3(Double($0.x) + 0.5, Double($0.y) + 0.5, Double($0.z) + 0.7) }
        let water = terrain.filter { $0.mat == .water }
        waterCells = water.map { ($0.x, $0.y) }
        waterU = (water.map { $0.x + $0.y }.min() ?? 0, water.map { $0.x + $0.y }.max() ?? 1)
    }

    func pool(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < Self.n && y < Self.n && isPool[y * Self.n + x]
    }
}
