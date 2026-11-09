// swift-tools-version: 6.0
import PackageDescription

// claudebar-probe (docs/plans/2026-11-03-wsl-design.md): ClaudeBar built for
// Linux, run inside a WSL distro by ClaudeBar for Windows. ClaudeBarShared
// is native/'s, built here from the same source at the same ClaudeBar
// commit: SwiftPM refuses two revisions of one package.
let package = Package(
    name: "ClaudeBarProbe",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "claudebar-probe", targets: ["ClaudeBarProbe"])],
    dependencies: [
        .package(path: "../native"),
        // The same commit as native/Package.swift, bumped together.
        .package(url: "https://github.com/tddworks/ClaudeBar.git", revision: "e5cda8a418244f11889e692de43b6d6b929da72e"),
    ],
    targets: [
        .target(name: "ProbeCore", dependencies: [
            .product(name: "ClaudeBarShared", package: "native"), .product(name: "ClaudeBarKit", package: "ClaudeBar"),
        ]),
        .executableTarget(name: "ClaudeBarProbe", dependencies: ["ProbeCore"]),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"], resources: [.copy("Fixtures")]),
        // Depends on the executable so `swift test` builds it: the runner tests
        // find it beside the test binary and run it as fixture users.
        .testTarget(name: "ProbeRunTests", dependencies: ["ClaudeBarProbe", "ProbeCore"]),
    ]
)
