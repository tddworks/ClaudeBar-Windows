// swift-tools-version: 6.0
import PackageDescription

// ClaudeBar for Windows' Swift side, over ClaudeBar's own package
// (ClaudeBarKit): the composition root, the DLL the C# app calls, and the
// uploader Task Scheduler runs every hour. ClaudeBarShared, the HUD's
// portable Swift, is built by linux/ too, into claudebar-probe, at the same
// ClaudeBar commit: linux/ depends on this package by path.
let package = Package(
    name: "ClaudeBarWindows",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClaudeBarNative", type: .dynamic, targets: ["ClaudeBarNative"]),
        .executable(name: "claudebar-upload", targets: ["ClaudeBarUpload"]),
        // The HUD's portable Swift, which linux/ builds into claudebar-probe.
        .library(name: "ClaudeBarShared", targets: ["ClaudeBarShared"]),
    ],
    dependencies: [
        // ClaudeBar at a commit, bumped on purpose, never silently (CONTRIBUTING).
        .package(url: "https://github.com/tddworks/ClaudeBar.git", revision: "e5cda8a418244f11889e692de43b6d6b929da72e"),
    ],
    targets: [
        .target(name: "ClaudeBarShared", dependencies: [.product(name: "ClaudeBarKit", package: "ClaudeBar")]),
        .target(name: "ClaudeBarWindows", dependencies: ["ClaudeBarShared", .product(name: "ClaudeBarKit", package: "ClaudeBar")]),
        .target(name: "DispatchSPI"),
        .target(name: "ClaudeBarNative", dependencies: ["ClaudeBarShared", "ClaudeBarWindows", "DispatchSPI"]),
        // A Windows app with no console, so the hourly run opens no window.
        .executableTarget(name: "ClaudeBarUpload", dependencies: ["ClaudeBarWindows"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]),
        .testTarget(name: "ClaudeBarWindowsTests", dependencies: ["ClaudeBarShared", "ClaudeBarWindows"]),
    ]
)
