// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThermoBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ThermoBar", targets: ["ThermoBar"])],
    targets: [
        .target(
            name: "SensorBridge",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "ThermoBar",
            dependencies: ["SensorBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Charts"),
            ]
        ),
        .testTarget(name: "ThermoBarTests", dependencies: ["ThermoBar", "SensorBridge"]),
    ],
    swiftLanguageModes: [.v6]
)
