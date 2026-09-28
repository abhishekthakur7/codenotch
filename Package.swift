// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools build path. Xcode continues to use project.yml.
let package = Package(
    name: "Codenotch",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Codenotch", targets: ["Codenotch"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", exact: "2.102.0"),
    ],
    targets: [
        .target(
            name: "CodenotchZstd",
            path: "Sources/Vendor/zstd",
            exclude: ["README.md", "LICENSE"],
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "Codenotch",
            dependencies: [
                "CodenotchZstd",
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources",
            exclude: ["Assets.xcassets", "Localizable.xcstrings", "Info.plist", "Resources",
                      "Codenotch-Bridging-Header.h", "Vendor"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
