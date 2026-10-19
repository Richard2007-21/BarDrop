// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BarDrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BarDrop",
            path: "Sources/BarDrop",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .testTarget(
            name: "BarDropTests",
            dependencies: ["BarDrop"],
            path: "Tests/BarDropTests"
        )
    ]
)
