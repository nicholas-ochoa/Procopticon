// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Procopticon",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Procopticon", targets: ["Procopticon"]),
        .executable(name: "procopticon-helper", targets: ["procopticon-helper"]),
    ],
    targets: [
        .target(
            name: "CSysInfo",
            path: "Sources/CSysInfo",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "ProcopticonCore",
            dependencies: ["CSysInfo"],
            path: "Sources/ProcopticonCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("CoreAudio"),
                             .linkedFramework("CoreMediaIO")]
        ),
        .executableTarget(
            name: "procopticon-helper",
            dependencies: ["ProcopticonCore"],
            path: "Sources/procopticon-helper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Procopticon",
            dependencies: ["ProcopticonCore"],
            path: "Sources/Procopticon",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .testTarget(
            name: "ProcopticonCoreTests",
            dependencies: ["ProcopticonCore"],
            path: "Tests/ProcopticonCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
