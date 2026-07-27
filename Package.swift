// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RimeBuffer",
    platforms: [.macOS("13.0")],
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
            dependencies: ["CRimeBridge"],
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
