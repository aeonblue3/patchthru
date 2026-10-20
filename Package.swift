// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "patchthru",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "thru", path: "Sources/thru")
    ],
    swiftLanguageVersions: [.v5]
)
