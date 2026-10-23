// swift-tools-version:5.9
// MP patch 0（#087）：入库后只留库和单测 target。上游的 SwiftTermFuzz / termcast / 基准 target 连同
// swift-argument-parser、swift-docc-plugin、package-benchmark 依赖一起去掉，免得 app 解析包时多拉三个仓库。

import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

#if os(Windows)
let resources: [Resource] = []
#else
let resources: [Resource] = [.process("Apple/Metal/Shaders.metal")]
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: platformExcludes + ["Mac/README.md"],
            resources: resources
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
