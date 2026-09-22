// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "Vigil",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Vigil", targets: ["Vigil"]),
    .library(name: "VigilCore", targets: ["VigilCore"]),
  ],
  targets: [
    // Pure logic. No AppKit, no IOKit, no I/O — so it is fully unit-testable.
    .target(name: "VigilCore"),

    // The menu bar app.
    .executableTarget(
      name: "Vigil",
      dependencies: ["VigilCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    .testTarget(name: "VigilCoreTests", dependencies: ["VigilCore"]),
  ]
)
