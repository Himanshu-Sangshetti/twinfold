// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Twinfold",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TwinfoldCore", targets: ["TwinfoldCore"]),
        .executable(name: "twinfold", targets: ["twinfold"]),
    ],
    targets: [
        .target(name: "TwinfoldCore"),
        .executableTarget(name: "twinfold", dependencies: ["TwinfoldCore"]),
        .executableTarget(name: "TwinfoldApp", dependencies: ["TwinfoldCore"]),
        .testTarget(name: "TwinfoldCoreTests", dependencies: ["TwinfoldCore"]),
    ],
    swiftLanguageModes: [.v5]
)
