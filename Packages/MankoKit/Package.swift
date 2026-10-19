// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MankoKit",
    defaultLocalization: "en",
    // Mac Catalyst consumes the iOS products. Readium's navigator is UIKit-based
    // and intentionally does not expose a native AppKit product.
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MankoDomain", targets: ["MankoDomain"]),
        .library(name: "MankoData", targets: ["MankoData"]),
        .library(name: "MankoSources", targets: ["MankoSources"]),
        .library(name: "MankoExtensions", targets: ["MankoExtensions"]),
        .library(name: "MankoReaders", targets: ["MankoReaders"]),
        .library(name: "MankoSync", targets: ["MankoSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.4.1", traits: ["MultiThread"]),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/kean/Nuke.git", exact: "13.0.6"),
        .package(url: "https://github.com/readium/swift-toolkit.git", exact: "3.10.0"),
        .package(url: "https://github.com/readium/ZIPFoundation.git", exact: "3.0.1"),
        .package(url: "https://github.com/ekscrypto/SwiftPublicSuffixList.git", exact: "3.1.12"),
    ],
    targets: [
        .target(name: "MankoDomain"),
        .target(
            name: "MankoData",
            dependencies: [
                "MankoDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "MankoSources",
            dependencies: [
                .product(name: "SwiftPublicSuffixList", package: "SwiftPublicSuffixList"),
                "MankoDomain",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "ReadiumOPDS", package: "swift-toolkit"),
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "MankoExtensions",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                "MankoDomain",
                "MankoSources",
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftPublicSuffixList", package: "SwiftPublicSuffixList"),
            ],
            linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("Security")]
        ),
        .target(
            name: "MankoReaders",
            dependencies: [
                "MankoDomain",
                "MankoSources",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit"),
                .product(name: "ReadiumNavigator", package: "swift-toolkit"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(name: "MankoSync", dependencies: ["MankoDomain", "MankoData"]),
    ],
    swiftLanguageModes: [.v6]
)
