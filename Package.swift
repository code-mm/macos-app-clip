// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipRecord",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClipRecord", targets: ["ClipRecord"])],
    targets: [
        .target(name: "ClipCore"),
        .executableTarget(name: "ClipRecord", dependencies: ["ClipCore"],
                          resources: [.process("Resources")]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipRecordTests", dependencies: ["ClipRecord", "ClipCore"])
    ],
    swiftLanguageModes: [.v5]
)
