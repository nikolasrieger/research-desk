// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResearchDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ResearchDesk", targets: ["ResearchDesk"])],
    targets: [
        .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources/SwiftTerm", exclude: ["Mac/README.md"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ResearchDesk", dependencies: ["SwiftTerm"]),
        .testTarget(name: "ResearchDeskTests", dependencies: ["ResearchDesk"])
    ]
)
