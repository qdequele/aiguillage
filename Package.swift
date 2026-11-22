// swift-tools-version:6.0
import Foundation
import PackageDescription

// With Command Line Tools only (no Xcode), SwiftPM sometimes compiles the test target without the
// Swift Testing macro plugin path ("plugin for module 'TestingMacros' not found"). Pass it
// explicitly when it exists.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins)
    ? [.unsafeFlags(["-plugin-path", testingPlugins])] : []

let package = Package(
    name: "aiguillage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "aiguillage", targets: ["aiguillage"]),
        .executable(name: "aiguillage-menubar", targets: ["aiguillage-menubar"]),
        .library(name: "AiguillageCore", targets: ["AiguillageCore"]),
    ],
    targets: [
        .target(name: "AiguillageCore"),
        .executableTarget(
            name: "aiguillage",
            dependencies: ["AiguillageCore"],
            linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Network")]
        ),
        // Unprivileged AppKit status-bar app. A plain SwiftPM executable (no .app bundle, no Xcode):
        // it uses NSStatusItem with an accessory activation policy, so it runs without a bundle.
        .executableTarget(
            name: "aiguillage-menubar",
            dependencies: ["AiguillageCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "AiguillageCoreTests", dependencies: ["AiguillageCore"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
