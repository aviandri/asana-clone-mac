// swift-tools-version:5.10
import PackageDescription

// Platform-neutral core of Mekari Project for Mac (SPEC-MAC §3). Kit and Features must build and
// test on Linux; the macOS app target (project.yml) is a thin SwiftUI layer on top.
let package = Package(
    name: "MekariProject",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MekariProjectKit", targets: ["MekariProjectKit"]),
        .library(name: "MekariProjectFeatures", targets: ["MekariProjectFeatures"]),
    ],
    targets: [
        .target(name: "MekariProjectKit"),
        .target(name: "MekariProjectFeatures", dependencies: ["MekariProjectKit"]),
        .testTarget(name: "MekariProjectKitTests", dependencies: ["MekariProjectKit"]),
        .testTarget(name: "MekariProjectFeaturesTests", dependencies: ["MekariProjectFeatures"]),
        // Hit a real seeded backend when MP_BASE_URL is set; skipped otherwise.
        .testTarget(name: "ContractTests", dependencies: ["MekariProjectKit"]),
    ]
)
