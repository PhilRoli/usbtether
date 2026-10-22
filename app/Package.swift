// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsbTether",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UsbTetherCore", targets: ["UsbTetherCore"])
    ],
    targets: [
        .target(name: "UsbTetherCore"),
        .executableTarget(name: "UsbTether", dependencies: ["UsbTetherCore"]),
        .testTarget(name: "UsbTetherCoreTests", dependencies: ["UsbTetherCore"])
    ]
)
