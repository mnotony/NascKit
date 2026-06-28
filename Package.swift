// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NascKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NascKit", targets: ["NascKit"])
    ],
    targets: [
        .target(name: "NascKit"),
        .executableTarget(name: "nasckit-smoke", dependencies: ["NascKit"])
    ],
    // Transport harvested from RelayKit; passes JSON as [String: Any] across actor
    // boundaries — Swift 5 mode for now (modernize later).
    swiftLanguageModes: [.v5]
)
