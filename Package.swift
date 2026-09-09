// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RimeBuffer",
    platforms: [.macOS("13.0")],
    dependencies: [
        .package(
            url: "https://github.com/AudioKit/AudioKit.git",
            exact: "5.7.2"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.20.0"
        ),
    ],
    targets: [
        .target(
            name: "CRimeBridge",
            path: "Sources/CRimeBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .executableTarget(
            name: "RimeBuffer",
            dependencies: [
                "CRimeBridge",
                .product(name: "AudioKit", package: "AudioKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/RimeBuffer",
            resources: [.copy("Resources/Music")],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Cocoa"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
