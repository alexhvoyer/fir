// swift-tools-version: 5.10
// Vendored from mozilla-mobile/firefox-ios (MPL-2.0) at fed7c3f, trimmed to the
// MozillaAppServices product; the Focus target and tests were removed. The binary comes
// from scripts/fetch-rust-components.sh, which patches in a missing Info.plist.
import PackageDescription

let package = Package(
    name: "MozillaRustComponentsSwift",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MozillaRustComponents", targets: ["MozillaAppServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mozilla/glean-swift", from: "70.1.0")
    ],
    targets: [
        .target(
            name: "MozillaAppServices",
            dependencies: [
                "MozillaRustComponents", .product(name: "Glean", package: "glean-swift"),
            ],
            path: "Sources/MozillaRustComponentsWrapper",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        .binaryTarget(
            name: "MozillaRustComponents",
            path: "MozillaRustComponents.xcframework"
        ),
    ]
)
