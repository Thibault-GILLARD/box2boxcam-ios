// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKitCore",
    platforms: [.macOS(.v13), .iOS("18.5")],
    products: [.library(name: "DockKitCore", targets: ["DockKitCore"])],
    targets: [
        .target(name: "DockKitCore"),
        // A plain Swift executable also runs with Command Line Tools, without XCTest/Xcode.
        .executableTarget(name: "MotorControllerChecks", dependencies: ["DockKitCore"],
                          path: "Tests/DockKitCoreTests")
    ]
)
