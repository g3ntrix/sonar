// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sonar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Sonar",
            path: "Sources/Sonar",
            exclude: ["Resources/Media"],
            resources: [.copy("Resources/Server"), .process("Resources/Localizable.xcstrings")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "SonarTests",
            dependencies: ["Sonar"],
            path: "Tests/SonarTests"
        ),
    ]
)
