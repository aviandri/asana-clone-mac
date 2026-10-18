// swift-tools-version:5.10
import PackageDescription

// Platform-neutral core of Mekari Project for Mac (SPEC-MAC §3). Kit and Features must build and
// test on Linux; the macOS app target (project.yml) is a thin SwiftUI layer on top.
// Check every Sendable claim (incl. @unchecked) at the "complete" level, ahead of Swift 6 mode.
let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "MekariProject",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MekariProjectKit", targets: ["MekariProjectKit"]),
        .library(name: "MekariProjectFeatures", targets: ["MekariProjectFeatures"]),
    ],
    targets: [
        .target(name: "MekariProjectKit", swiftSettings: strict),
        .target(name: "MekariProjectFeatures", dependencies: ["MekariProjectKit"], swiftSettings: strict),
        .testTarget(name: "MekariProjectKitTests", dependencies: ["MekariProjectKit"], swiftSettings: strict),
        .testTarget(name: "MekariProjectFeaturesTests", dependencies: ["MekariProjectFeatures"], swiftSettings: strict),
        // Hit a real seeded backend when MP_BASE_URL is set; skipped otherwise.
        .testTarget(name: "ContractTests", dependencies: ["MekariProjectKit"], swiftSettings: strict),
    ]
)
