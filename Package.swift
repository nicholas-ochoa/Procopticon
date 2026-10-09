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
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedFramework("CoreServices")]
        ),
        // QuickJS-ng (quickjs/, unmodified) and a bridge to it, for filter, highlight and alert
        // expressions. Only the app links it (through ProcopticonExpressions), not the root helper.
        .target(
            name: "CQuickJS",
            path: "Sources/CQuickJS",
            exclude: ["quickjs/LICENSE", "quickjs/VERSION"],
            // The engine's sources draw a few hundred warnings from Swift's default flags. Optimized
            // for size in debug builds too: unoptimized, it's several times slower and its deep frames
            // fit few nested calls into the stack limit.
            cSettings: [.define("_GNU_SOURCE"), .define("QUICKJS_NG_BUILD"), .unsafeFlags(["-w", "-Os"])]
        ),
        .target(
            name: "ProcopticonCore",
            dependencies: ["CSysInfo"],
            path: "Sources/ProcopticonCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("CoreAudio"),
                             .linkedFramework("CoreMediaIO")]
        ),
        .target(
            name: "ProcopticonExpressions",
            dependencies: ["ProcopticonCore", "CQuickJS"],
            path: "Sources/ProcopticonExpressions",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "procopticon-helper",
            dependencies: ["ProcopticonCore"],
            path: "Sources/procopticon-helper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Procopticon",
            dependencies: ["ProcopticonCore", "ProcopticonExpressions"],
            path: "Sources/Procopticon",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .testTarget(
            name: "ProcopticonCoreTests",
            dependencies: ["ProcopticonCore", "ProcopticonExpressions"],
            path: "Tests/ProcopticonCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
