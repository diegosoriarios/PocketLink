// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketLinkCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LinkCore",
            targets: [
                "LinkProtocol",
                "LinkConnection",
                "LinkDiscovery",
                "LinkPairing",
                "LinkNotifications",
                "LinkClipboard",
                "LinkFiles",
                "LinkSecurity"
            ]
        )
    ],
    targets: [
        .target(name: "LinkProtocol"),
        .target(
            name: "LinkConnection",
            dependencies: ["LinkProtocol"]
        ),
        .target(name: "LinkDiscovery"),
        .target(
            name: "LinkPairing",
            dependencies: ["LinkProtocol"]
        ),
        .target(
            name: "LinkNotifications",
            dependencies: ["LinkProtocol"]
        ),
        .target(
            name: "LinkClipboard",
            dependencies: ["LinkProtocol"]
        ),
        .target(
            name: "LinkFiles",
            dependencies: ["LinkProtocol", "LinkSecurity", "LinkConnection"]
        ),
        .target(name: "LinkSecurity"),
        .testTarget(
            name: "LinkCoreTests",
            dependencies: [
                "LinkProtocol",
                "LinkConnection",
                "LinkDiscovery",
                "LinkPairing",
                "LinkNotifications",
                "LinkClipboard",
                "LinkFiles",
                "LinkSecurity"
            ]
        )
    ]
)
