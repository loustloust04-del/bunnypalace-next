// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MemoryCore",
    platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [
        .library(name: "MemoryCore", targets: ["MemoryCore"]),
        .executable(name: "memoryd", targets: ["memoryd"])
    ],
    targets: [
        .target(name: "MemoryCore"),
        .executableTarget(
            name: "memoryd",
            dependencies: ["MemoryCore"],
            resources: [.copy("web"), .copy("MemoryBench")]
        ),
        .testTarget(name: "MemoryCoreTests", dependencies: ["MemoryCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MemorydTests", dependencies: ["memoryd", "MemoryCore"])
    ]
)
