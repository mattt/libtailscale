// swift-tools-version:5.9

// TailscaleKit for iMCP: a prebuilt macOS arm64 framework with a trimmed
// feature profile. See swift/IMCP.md.

import PackageDescription

let package = Package(
    name: "TailscaleKit",
    platforms: [
        .macOS("15.6")
    ],
    products: [
        .library(name: "TailscaleKit", targets: ["TailscaleKit"])
    ],
    targets: [
        .binaryTarget(
            name: "TailscaleKit",
            url: "https://github.com/mattt/libtailscale/releases/download/0.2.0-imcp.1/TailscaleKit.xcframework.zip",
            checksum: "8f9ad19e7bd81accaf622d168f16bccda442b8e50e3ef8ff896dfac48e6e867b"
        )
    ]
)
