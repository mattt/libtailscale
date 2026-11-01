// swift-tools-version:5.9

// TailscaleKit for iMCP: a prebuilt universal macOS framework with a trimmed
// feature profile. See swift/IMCP.md.

import PackageDescription

let package = Package(
    name: "TailscaleKit",
    platforms: [
        .macOS("15.1")
    ],
    products: [
        .library(name: "TailscaleKit", targets: ["TailscaleKit"])
    ],
    targets: [
        .binaryTarget(
            name: "TailscaleKit",
            url: "https://github.com/mattt/libtailscale/releases/download/0.2.0-imcp.2/TailscaleKit.xcframework.zip",
            checksum: "69069897880f4076ce7cd7a0eb0b6290bd7714a7d1d9182909e29847d5e545f6"
        )
    ]
)
