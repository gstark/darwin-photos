// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shoebox",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ShoeboxCore", targets: ["ShoeboxCore"]),
        .library(name: "ShoeboxS3", targets: ["ShoeboxS3"]),
        .executable(name: "shoebox", targets: ["shoebox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "1.8.0"),
        .package(url: "https://github.com/smithy-lang/smithy-swift", from: "0.258.0"),
    ],
    targets: [
        .target(
            name: "ShoeboxCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // The AWS SDK is large and slow to compile, so it has its own module.
        .target(
            name: "ShoeboxS3",
            dependencies: [
                "ShoeboxCore",
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
                .product(name: "SmithyIdentity", package: "smithy-swift"),
            ]
        ),
        .executableTarget(
            name: "shoebox",
            dependencies: [
                "ShoeboxCore",
                "ShoeboxS3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed an Info.plist so that macOS can show the Photos usage
                // description. PhotoKit needs it.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/shoebox/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "ShoeboxCoreTests",
            dependencies: [
                "ShoeboxCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "ShoeboxS3Tests",
            dependencies: [
                "ShoeboxS3",
                "ShoeboxCore",
                .product(name: "AWSS3", package: "aws-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "ShoeboxCLITests",
            dependencies: ["shoebox"]
        ),
    ]
)
