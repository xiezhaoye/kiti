// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kiti",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "kiti", path: "Sources/kiti")
    ]
)
