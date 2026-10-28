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
            url: "https://github.com/mattt/libtailscale/releases/download/imcp-0.1.0/TailscaleKit.xcframework.zip",
            checksum: "cfc48d0c99f7094113d9890075f2e5309149f605376429cbcb1d533c5f0b890f"
        )
    ]
)
