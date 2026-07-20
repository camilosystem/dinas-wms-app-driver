// swift-tools-version:5.9
import PackageDescription

// App de Vendedores (Dinas WMS) — paquete SPM.
// El target apunta a la carpeta DinasDriver/ para respetar la estructura del CLAUDE.md.
// El .xcodeproj (target de app iOS) se genera/abre desde Xcode sobre este paquete.
let package = Package(
    name: "DinasDriver",
    platforms: [
        .iOS(.v16),
        // macOS solo habilita compilar/testear el paquete en el host (CI, `swift test`).
        // El objetivo real de distribución es iOS (iPad + iPhone).
        .macOS(.v13)
    ],
    products: [
        .library(name: "DinasDriver", targets: ["DinasDriver"])
    ],
    dependencies: [
        // Persistencia local SQLite (SQL-first).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "DinasDriver",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "DinasDriver",
            // Recursos que pertenecen al target de app iOS (.xcodeproj), no al paquete SPM.
            exclude: [
                "Resources/Info.plist",
                "Resources/Info-Dev.plist",
                "Resources/DinasDriver.entitlements",
                "Resources/Assets.xcassets"
            ]
        ),
        .testTarget(
            name: "DinasDriverTests",
            dependencies: ["DinasDriver"],
            path: "DinasDriverTests"
        )
    ]
)
