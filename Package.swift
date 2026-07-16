// swift-tools-version:5.9
import PackageDescription

// ScenarioKit — the shared declarative UI-scenario player (see STEPS.md).
// Link the library into a UI-test bundle only: it imports XCTest, so it is not
// meant for app targets. Consumed as a local package (xcodegen `packages:` or an
// XCLocalSwiftPackageReference in a raw project).
let package = Package(
    name: "ScenarioKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ScenarioKit", targets: ["ScenarioKit"])
    ],
    targets: [
        .target(name: "ScenarioKit", path: "Sources/ScenarioKit")
    ]
)
