// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Junction",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Junction",
            path: "Sources/Junction",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
