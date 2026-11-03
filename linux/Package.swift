// swift-tools-version: 6.0
import PackageDescription

// A spike (docs/plans/2026-11-03-wsl-design.md): ClaudeBar built for Linux, to
// run inside a WSL distro and print what ClaudeBar reads there, in the shapes
// the Windows C interface returns. Not shipped.
//
// ClaudeBarShared is the Windows client's portable Swift (the HUD's monitor and
// reading, the token logs, the settings reader), linked from native/ so both
// builds use one copy of each type.
let package = Package(
    name: "ClaudeBarProbe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "claudebar-probe", targets: ["ClaudeBarProbe"]),
    ],
    dependencies: [
        // The same commit as native/Package.swift.
        .package(url: "https://github.com/tddworks/ClaudeBar.git", revision: "da68b4a3e97381b2bd4f01408330c284860b71c4"),
    ],
    targets: [
        .target(name: "ClaudeBarShared", dependencies: [.product(name: "ClaudeBarKit", package: "ClaudeBar")]),
        .executableTarget(name: "ClaudeBarProbe", dependencies: [
            "ClaudeBarShared", .product(name: "ClaudeBarKit", package: "ClaudeBar"),
        ]),
    ]
)
