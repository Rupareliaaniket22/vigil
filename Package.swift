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

    // The app layer's own tests, kept apart from VigilCoreTests so that target
    // stays what AGENTS.md says it is: pure logic, no I/O, no waiting.
    //
    // AGENTS.md's rule is that wanting to test something in `Sources/Vigil`
    // means the logic belongs in `VigilCore`. It still does, and this target
    // is not a way around it. What lives here is the one thing that cannot
    // move down: `HookInstaller.uninstall()` decides whether to delete the
    // shared hook script by reading four settings files whose paths come from
    // the user's home directory, and the defect was in how an unreadable file
    // was counted. Moving that down would mean `VigilCore` opening files,
    // which the same document forbids in the same breath. So the seam is a
    // fake home rather than a protocol — see `Tests/VigilAppTests/FakeHome.swift`.
    //
    // Fast: no waiting, no sockets, no app. It belongs in `make test`.
    .testTarget(
      name: "VigilAppTests",
      dependencies: ["Vigil"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
