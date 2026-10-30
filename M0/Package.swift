// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "M0Verify",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "m0verify",
            path: "Sources/m0verify"
        )
    ]
)
