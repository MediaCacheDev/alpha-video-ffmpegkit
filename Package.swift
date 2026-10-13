// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AlphaVideoFFmpegKit",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "AlphaVideoFFmpegKit", targets: ["AlphaVideoFFmpegKit"]),
    ],
    dependencies: [
        // FFmpegKit with a VP9-only FFmpeg, as dynamic XCFrameworks (LGPL: apps can replace them)
        .package(url: "https://github.com/MediaCacheDev/ffmpegkit-vp9", exact: "6.0.0"),
    ],
    targets: [
        .target(
            name: "AlphaVideoFFmpegKit",
            dependencies: [.product(name: "ffmpegkit-vp9", package: "ffmpegkit-vp9")],
            path: "ios/Sources/AlphaVideoFFmpegKit"
        ),
        .testTarget(
            name: "AlphaVideoFFmpegKitTests",
            dependencies: ["AlphaVideoFFmpegKit"],
            path: "ios/Tests/AlphaVideoFFmpegKitTests"
        ),
    ]
)
