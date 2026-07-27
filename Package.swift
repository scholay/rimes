// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RimeBuffer",
    platforms: [.macOS("13.0")],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
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
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/RimeBuffer",
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Cocoa"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
