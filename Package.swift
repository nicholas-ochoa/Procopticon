// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcessInformer",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ProcessInformer", targets: ["ProcessInformer"]),
        .executable(name: "informer-helper", targets: ["informer-helper"]),
    ],
    targets: [
        .target(
            name: "CSysInfo",
            path: "Sources/CSysInfo",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "InformerCore",
            dependencies: ["CSysInfo"],
            path: "Sources/InformerCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "informer-helper",
            dependencies: ["InformerCore"],
            path: "Sources/informer-helper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ProcessInformer",
            dependencies: ["InformerCore"],
            path: "Sources/ProcessInformer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .testTarget(
            name: "InformerCoreTests",
            dependencies: ["InformerCore"],
            path: "Tests/InformerCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
