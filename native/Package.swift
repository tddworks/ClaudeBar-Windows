// swift-tools-version: 6.0
import PackageDescription

// ClaudeBar for Windows' Swift side, over ClaudeBar's own package
// (ClaudeBarKit): the composition root, the DLL the C# app calls, and the
// uploader Task Scheduler runs every hour.
let package = Package(
    name: "ClaudeBarWindows",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClaudeBarNative", type: .dynamic, targets: ["ClaudeBarNative"]),
        .executable(name: "claudebar-upload", targets: ["ClaudeBarUpload"]),
    ],
    dependencies: [
        // ClaudeBar at a commit, bumped on purpose, never silently (CONTRIBUTING).
        .package(url: "https://github.com/tddworks/ClaudeBar.git", revision: "549efed7740d6c90587ad1e5496982b30a10f98f"),
    ],
    targets: [
        .target(name: "ClaudeBarWindows", dependencies: [.product(name: "ClaudeBarKit", package: "ClaudeBar")]),
        .target(name: "DispatchSPI"),
        .target(name: "ClaudeBarNative", dependencies: ["ClaudeBarWindows", "DispatchSPI"]),
        // A Windows app with no console, so the hourly run opens no window.
        .executableTarget(name: "ClaudeBarUpload", dependencies: ["ClaudeBarWindows"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]),
        .testTarget(name: "ClaudeBarWindowsTests", dependencies: ["ClaudeBarWindows"]),
    ]
)
