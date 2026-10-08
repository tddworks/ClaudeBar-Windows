// swift-tools-version: 6.0
import PackageDescription

// ClaudeBarKit stand-in for the UI stack B spike: a DLL that C# loads.
// `Quotas` is ClaudeBar's real module, checked out at a pinned commit into
// vendor/ by build.ps1 (ClaudeBar has no root Package.swift yet, MODULAR_DESIGN §10 phase 1).
let package = Package(
    name: "ClaudeBarKitNative",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClaudeBarKitNative", type: .dynamic, targets: ["ClaudeBarKitNative"]),
    ],
    targets: [
        .target(name: "Quotas", path: "vendor/ClaudeBar/Modules/Quotas/Sources"),
        .target(name: "DispatchSPI"),
        .target(name: "ClaudeBarKitNative", dependencies: ["Quotas", "DispatchSPI"]),
    ]
)
