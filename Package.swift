// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FCPLibraryCleaner",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FCPLibraryCleanerCore", targets: ["FCPLibraryCleanerCore"]),
        .executable(name: "fcp-library-scanner", targets: ["fcp-library-scanner"]),
        .executable(name: "FCP-Cleaner", targets: ["FCPLibraryCleanerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "FCPLibraryCleanerCore"),
        .executableTarget(
            name: "fcp-library-scanner",
            dependencies: ["FCPLibraryCleanerCore"]
        ),
        .executableTarget(
            name: "FCPLibraryCleanerApp",
            dependencies: [
                "FCPLibraryCleanerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "FCPLibraryCleanerCoreTests",
            dependencies: ["FCPLibraryCleanerCore"]
        ),
    ]
)
