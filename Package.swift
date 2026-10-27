// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chaval",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Chaval", path: "Sources/Chaval",
                                linkerSettings: [.linkedFramework("Carbon")])]
)
