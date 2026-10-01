// swift-tools-version: 6.2
import PackageDescription

// DesignSystem is SwiftUI (Apple platforms only); on Linux — the server — only BudgetKit builds.
#if os(Linux)
let appleOnlyProducts: [Product] = []
let appleOnlyTargets: [Target] = []
#else
let appleOnlyProducts: [Product] = [.library(name: "DesignSystem", targets: ["DesignSystem"])]
let appleOnlyTargets: [Target] = [
    // Visual language only. Knows nothing about money models or the server.
    .target(name: "DesignSystem"),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
]
#endif

let package = Package(
    name: "BudgetCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: appleOnlyProducts + [
        .library(name: "BudgetKit", targets: ["BudgetKit"]),
        .executable(name: "budget-assistant", targets: ["budget-assistant"]),
    ],
    targets: appleOnlyTargets + [
        // Models, the API contract, the ledger engine, sources, decisions and the agent loop — shared with the server.
        .target(name: "BudgetKit"),
        // `swift run budget-assistant tools|prompt|catalog|ask|decide|eval|backlog`
        .executableTarget(name: "budget-assistant", dependencies: ["BudgetKit"]),
        .testTarget(name: "BudgetKitTests", dependencies: ["BudgetKit"]),
    ]
)
