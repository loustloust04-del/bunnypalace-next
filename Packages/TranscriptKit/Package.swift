// swift-tools-version: 6.0
import PackageDescription

// 对话页（docs/plan-重构.md §3）。TranscriptCore 只许依赖 Foundation / CoreGraphics：
// 行、排版、锚点、跟随、事务归约全是值类型，mac 上 `swift test` 直接跑。
let package = Package(
    name: "TranscriptKit",
    platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [
        .library(name: "TranscriptCore", targets: ["TranscriptCore"])
    ],
    targets: [
        .target(name: "TranscriptCore"),
        .testTarget(name: "TranscriptCoreTests", dependencies: ["TranscriptCore"])
    ]
)
