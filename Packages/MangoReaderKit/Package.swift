// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MangoReaderKit",
    defaultLocalization: "en",
    // Mac Catalyst consumes the iOS products. Readium's navigator is UIKit-based
    // and intentionally does not expose a native AppKit product.
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MangoReaderDomain", targets: ["MangoReaderDomain"]),
        .library(name: "MangoReaderData", targets: ["MangoReaderData"]),
        .library(name: "MangoReaderSources", targets: ["MangoReaderSources"]),
        .library(name: "MangoReaderExtensions", targets: ["MangoReaderExtensions"]),
        .library(name: "MangoReaderReaders", targets: ["MangoReaderReaders"]),
        .library(name: "MangoReaderSync", targets: ["MangoReaderSync"]),
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
        .target(name: "MangoReaderDomain"),
        .target(
            name: "MangoReaderData",
            dependencies: [
                "MangoReaderDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "MangoReaderSources",
            dependencies: [
                .product(name: "SwiftPublicSuffixList", package: "SwiftPublicSuffixList"),
                "MangoReaderDomain",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "ReadiumOPDS", package: "swift-toolkit"),
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "MangoReaderExtensions",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                "MangoReaderDomain",
                "MangoReaderSources",
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftPublicSuffixList", package: "SwiftPublicSuffixList"),
            ],
            linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("Security")]
        ),
        .target(
            name: "MangoReaderReaders",
            dependencies: [
                "MangoReaderDomain",
                "MangoReaderSources",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit"),
                .product(name: "ReadiumNavigator", package: "swift-toolkit"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(name: "MangoReaderSync", dependencies: ["MangoReaderDomain", "MangoReaderData"]),
    ],
    swiftLanguageModes: [.v6]
)
