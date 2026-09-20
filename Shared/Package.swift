// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RimesCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "RimesCore", targets: ["RimesCore"])], targets: [.target(name: "RimesCore", resources: [.process("Resources")]), .testTarget(name: "RimesCoreTests", dependencies: ["RimesCore"])])
