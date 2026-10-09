// swift-tools-version: 6.2
import PackageDescription

// The Budget API that runs on the Olares. It serves the same wire types the iPhone app decodes,
// by reusing BudgetKit (ledger engine, agent loop, adapters, decision models) from ../Packages.

// The browser dashboard's files (Sources/BudgetServerCore/Dashboard/). `.embedInCode` compiles each into
// the binary as `PackageResources.<name>` bytes (dots and dashes become underscores), so there is no
// resource bundle and deploy.sh keeps copying one binary. Names must be unique; a new file goes here and
// in `DashboardAssets.files` (Dashboard.swift).
let dashboardAssets = [
    "index.html", "tokens.css", "app.css",
    "app.js", "core.js", "providers.js", "overview.js", "accounts.js", "imports.js", "review.js", "groups.js", "rules.js", "categories.js", "settings.js", "transactions.js",
    "orders.js",
    "assistant.js",
    "icon-64.png", "icon-180.png",
]

let package = Package(
    name: "BudgetServer",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "BudgetServer", targets: ["BudgetServer"])],
    dependencies: [
        .package(path: "../Packages/BudgetCore"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "BudgetServerCore", dependencies: [
            .product(name: "BudgetKit", package: "BudgetCore"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Logging", package: "swift-log"),
        ], resources: dashboardAssets.map { .embedInCode("Dashboard/" + $0) }),
        .executableTarget(name: "BudgetServer", dependencies: ["BudgetServerCore"]),
        .testTarget(name: "BudgetServerTests", dependencies: [
            "BudgetServerCore",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
        ]),
    ]
)
