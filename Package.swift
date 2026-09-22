// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "Vigil",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Vigil", targets: ["Vigil"]),
    .library(name: "VigilCore", targets: ["VigilCore"]),
  ],
  dependencies: [
    // Tiny, zero-non-Apple-dependency HTTP server. Used for its Unix-socket
    // support; hand-parsing HTTP from untrusted input is how listeners get CVEs.
    .package(url: "https://github.com/swhitty/FlyingFox", from: "0.27.0")
  ],
  targets: [
    // Pure logic. No AppKit, no IOKit, no I/O — so it is fully unit-testable.
    .target(
      name: "VigilCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // The menu bar app.
    .executableTarget(
      name: "Vigil",
      dependencies: [
        "VigilCore",
        .product(name: "FlyingFox", package: "FlyingFox"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    .testTarget(
      name: "VigilCoreTests",
      dependencies: ["VigilCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
