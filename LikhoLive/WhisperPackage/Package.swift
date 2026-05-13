// swift-tools-version: 5.10
//
// Local SPM wrapper around the prebuilt whisper.cpp XCFramework.
//
// We pin to a tagged release of ggml-org/whisper.cpp and pull the official
// XCFramework artifact from the GitHub release. The XCFramework ships built
// with Metal (`GGML_USE_METAL`) and Apple's Accelerate framework, and exposes
// the C API (`whisper.h`) for Swift to call directly.
//
// This package is consumed by the LikhoLive Xcode project via XcodeGen's
// `packages` block in `project.yml`. SPM downloads the artifact on first
// build and verifies its SHA-256 against the checksum below.
//
// Bump procedure when upgrading the pinned whisper.cpp version:
//   1. Pick a new release at https://github.com/ggml-org/whisper.cpp/releases
//   2. Update `pinnedVersion` and the URL below
//   3. Get the artifact's SHA-256 from the GitHub release API:
//      curl -s https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/<tag> \
//        | jq -r '.assets[] | select(.name | endswith("-xcframework.zip")) | .digest'
//   4. Update `pinnedChecksum`
//   5. Re-run `xcodegen generate` and rebuild

import PackageDescription

// Pinned whisper.cpp release. Bump in lockstep with `pinnedURL` and `pinnedChecksum`.
private let pinnedVersion  = "v1.8.4"
private let pinnedURL      = "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip"
private let pinnedChecksum = "1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"

let package = Package(
    name: "WhisperPackage",
    platforms: [
        // The XCFramework's minimum macOS is 13.3 — the consuming target
        // (the LikhoLive app) enforces 13.3 via its build settings.
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: pinnedURL,
            checksum: pinnedChecksum
        )
    ]
)
