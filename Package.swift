// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Photos-Backup",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "export-originals",
            targets: ["ExportOriginals"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "ExportOriginals",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "Photos-BackupTests",
            dependencies: ["ExportOriginals"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
