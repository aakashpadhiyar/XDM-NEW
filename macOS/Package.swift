// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XDMmacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XDMTest", targets: ["XDMTest"]),
        .executable(name: "XDMNativeHost", targets: ["XDMNativeHost"])
    ],
    targets: [
        .executableTarget(
            name: "XDMTest",
            path: "Sources/XDMmacOS",
            exclude: ["ContentView.swift", "XDMmacOSApp.swift"]
        ),
        .executableTarget(name: "XDMNativeHost", path: "Sources/XDMNativeHost")
    ]
)
