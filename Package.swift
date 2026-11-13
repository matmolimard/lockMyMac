// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LockMyMac",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique pure (aucune dépendance caméra/UI) : entièrement testable.
        .target(name: "LockMyMacCore"),
        .executableTarget(name: "LockMyMac", dependencies: ["LockMyMacCore"]),
        .testTarget(name: "LockMyMacCoreTests", dependencies: ["LockMyMacCore"]),
    ]
)
