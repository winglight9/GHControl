// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GHControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GHControl", targets: ["GHControl"])
    ],
    targets: [
        .executableTarget(name: "GHControl")
    ]
)
