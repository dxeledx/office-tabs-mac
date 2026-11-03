// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OfficeTabs",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OfficeTabs", targets: ["OfficeTabs"])],
    targets: [.executableTarget(name: "OfficeTabs")]
)
