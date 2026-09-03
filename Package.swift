// swift-tools-version:6.0
// corvid-swift — Package manifest.
//
// Product `Corvid` (the Swift wrapper) over binary target `CorvidEngine`
// (the engine's prebuilt static library — CorvidEngine.xcframework from
// the PINNED engine release, checksum-pinned; the binary target's name
// must match the xcframework bundle name inside the zip). The pin is the
// URL's tag plus the checksum: the release cascade bumps both together
// (scripts/bindings/bump.sh in the engine repo), and the release gate
// (ci: .github/workflows/release.yml) verifies tag == .engine-pin ==
// this URL's version before tagging.
//
// Language mode: Swift 5 under the 6.0 tools manifest (docs/PLAN.md's
// ruling — the wrapper is @unchecked Sendable by the ABI's own thread
// contract, FFI.md §6; strict-mode annotations would be ceremony).
import PackageDescription

let package = Package(
    name: "Corvid",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "Corvid", targets: ["Corvid"]),
    ],
    targets: [
        .binaryTarget(
            name: "CorvidEngine",
            url: "https://github.com/corvid-db/corvid/releases/download/v0.4.1/corvid-swift-v0.4.1.zip",
            checksum: "e755303406dcc8e14c65c2308923cfd0edca62a33c152d869cb5c44e4ab84173"
        ),
        .target(
            name: "Corvid",
            dependencies: ["CorvidEngine"],
            path: "Sources/Corvid"
        ),
        .testTarget(
            name: "CorvidTests",
            dependencies: ["Corvid"],
            path: "Tests/CorvidTests"
        ),
    ]
)
