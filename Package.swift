// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PCBrowserMac", platforms: [.macOS(.v14)],
    products: [.executable(name: "PCBrowserMac", targets: ["PCBrowserMac"])],
    targets: [
        .target(name: "PCRawIO", publicHeadersPath: "include", linkerSettings: [.linkedFramework("DiskArbitration"), .linkedFramework("CoreFoundation")]),
        .target(name: "PCBrowserCore"),
        .executableTarget(name: "PCBrowserMac", dependencies: ["PCBrowserCore", "PCRawIO"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVKit"), .linkedFramework("MapKit"), .linkedFramework("VideoToolbox"), .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreText")]),
        .testTarget(name: "PCBrowserCoreTests", dependencies: ["PCBrowserCore"])
    ])
