import XCTest
import SwiftUI
import UIKit
@testable import 记忆花园

/// 工具，不是断言（docs/plan-重构.md §7）。新对话页要把 SF 符号画得和 SwiftUI 逐像素相同，
/// 而 SwiftUI 画 `Image(systemName:)` 的办法系统没公开：单层的符号是「形状图层 + 矢量轮廓」，有镂空的符号是一张位图。
/// 这里把一批符号真的用 SwiftUI 画出来，读出每个的排版大小、墨迹的位置、轮廓（或位图的透明度），写成 JSON；
/// `Packages/TranscriptKit/scripts/gen-symbols.py` 再把 JSON 变成 app 里的 Swift 表。
/// 要加符号：改 `names`，跑这条测试，再跑生成脚本。
@MainActor
final class SymbolOutlineDumpTests: XCTestCase {
    #if DEBUG
    /// 「名字@字号/字重」。字重只认 regular / medium / semibold
    private static let names = [
        "pencil@13/regular", "arrow.counterclockwise@13/regular", "doc.on.doc@13/regular", "star@13/regular",
        "star.fill@13/regular", "pin@13/regular", "pin.fill@13/regular", "trash@13/regular"
    ]
    private static let cell = CGSize(width: 80, height: 48)

    private static func parse(_ key: String) -> (name: String, size: CGFloat, weight: Font.Weight)? {
        let parts = key.split(separator: "@")
        guard parts.count == 2 else { return nil }
        let style = parts[1].split(separator: "/")
        guard style.count == 2, let size = Double(style[0]) else { return nil }
        let weights: [String: Font.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold]
        guard let weight = weights[String(style[1])] else { return nil }
        return (String(parts[0]), CGFloat(size), weight)
    }

    func testDumpSymbolOutlines() async throws {
        let host = try await ParityHost()
        let scale = host.window.traitCollection.displayScale
        let specs = Self.names.compactMap { key in Self.parse(key).map { (key: key, spec: $0) } }
        XCTAssertEqual(specs.count, Self.names.count, "有写错的符号名")

        // 黑字白底：位图那种符号的透明度 = 255 − 灰度
        let scene = MemoryPalaceIOSTestScene.shared
        defer { scene.content = AnyView(Color.clear) }
        scene.content = AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(specs.enumerated()), id: \.offset) { _, item in
                    Image(systemName: item.spec.name)
                        .font(.system(size: item.spec.size, weight: item.spec.weight))
                        .foregroundStyle(Color.black)
                        .frame(width: Self.cell.width, height: Self.cell.height, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
            .ignoresSafeArea()
        )
        try await Task.sleep(for: .milliseconds(800))
        host.window.layoutIfNeeded()
        let shot = try ParityImage(host.capture())

        var leaves: [Int: (frame: CGRect, path: String?)] = [:]
        func walk(_ layer: CALayer) {
            let kind = String(describing: type(of: layer))
            let frame = layer.convert(layer.bounds, to: host.window.layer)
            if kind.contains("ColorShapeLayer") || kind.contains("CGDrawingLayer"),
               frame.maxX <= Self.cell.width, frame.maxY <= Self.cell.height * CGFloat(specs.count) {
                var elements: [String]?
                if let shape = layer as? CAShapeLayer {
                    var list: [String] = []
                    shape.path?.applyWithBlock { element in
                        let points = element.pointee.points
                        func p(_ index: Int) -> String { String(format: "(%.7f, %.7f)", points[index].x, points[index].y) }
                        switch element.pointee.type {
                        case .moveToPoint: list.append("M\(p(0))")
                        case .addLineToPoint: list.append("L\(p(0))")
                        case .addQuadCurveToPoint: list.append("Q\(p(0))\(p(1))")
                        case .addCurveToPoint: list.append("C\(p(0))\(p(1))\(p(2))")
                        case .closeSubpath: list.append("Z")
                        @unknown default: break
                        }
                    }
                    elements = list
                }
                leaves[Int(frame.minY / Self.cell.height)] = (frame, elements?.joined(separator: " "))
            }
            layer.sublayers?.forEach(walk)
        }
        walk(host.window.layer)

        var output: [[String: Any]] = []
        for (index, item) in specs.enumerated() {
            guard let leaf = leaves[index] else {
                XCTFail("\(item.key) 没找到图层")
                continue
            }
            let layout = UIHostingController(rootView: Image(systemName: item.spec.name)
                .font(.system(size: item.spec.size, weight: item.spec.weight)))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000))
            let originY = CGFloat(index) * Self.cell.height
            var entry: [String: Any] = [
                "key": item.key, "scale": scale,
                "layout": [layout.width, layout.height],
                "ink": [leaf.frame.minX, leaf.frame.minY - originY, leaf.frame.width, leaf.frame.height]
            ]
            if let path = leaf.path {
                entry["path"] = path
            } else {
                // 位图：把那一块的透明度抠出来
                let x0 = Int((leaf.frame.minX * scale).rounded()), y0 = Int((leaf.frame.minY * scale).rounded())
                let width = Int((leaf.frame.width * scale).rounded()), height = Int((leaf.frame.height * scale).rounded())
                var alpha = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = ((y0 + y) * shot.width + x0 + x) * 4
                        alpha[y * width + x] = 255 - shot.rgba[offset]
                    }
                }
                entry["mask"] = Data(alpha).base64EncodedString()
                entry["maskSize"] = [width, height]
            }
            output.append(entry)
            print("[符号] \(item.key)：排版 \(layout)，墨迹 \(entry["ink"] ?? "")，\(leaf.path == nil ? "位图" : "形状")")
        }
        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("symbols@\(Int(scale))x.json"), options: .atomic)
    }

    private static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MP_PARITY_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("symbols", isDirectory: true)
        }
        return (TestHostIsolation.home ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("TranscriptParity-symbols", isDirectory: true)
    }
    #else
    func testDumpSymbolOutlines() throws {
        throw XCTSkip("要 Debug 宿主")
    }
    #endif
}
