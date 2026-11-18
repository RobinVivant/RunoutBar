// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunoutBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "RunoutBar", targets: ["RunoutBar"]),
    ],
    targets: [
        .target(name: "RunoutCore"),
        .executableTarget(name: "RunoutBar", dependencies: ["RunoutCore"]),
        .testTarget(
            name: "RunoutCoreTests",
            dependencies: ["RunoutCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
