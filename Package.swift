// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SaluteRemotePlus",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SaluteRemotePlusCore", targets: ["SaluteRemotePlusCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/salute-developers/jazz-ios-sdk.git", revision: "6d5f92869690fa22bb489a9089aa554d733c6936")
    ],
    targets: [
        .target(
            name: "SaluteRemotePlusCore",
            dependencies: [
                .product(name: "JazzSDK", package: "jazz-ios-sdk")
            ]
        )
    ]
)
