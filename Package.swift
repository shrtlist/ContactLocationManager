// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ContactLocationManager",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ContactLocationManager",
            targets: ["ContactLocationManager"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/albertodebortoli/Skopelos.git", branch: "master"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.

        // Objective-C shim: CNContactStore's change history enumerator is unavailable from Swift (TN3149).
        .target(
            name: "ContactsChangeHistory"
        ),
        .target(
            name: "ContactLocationManager",
            dependencies: [
                "ContactsChangeHistory",
                .product(name: "Skopelos", package: "Skopelos"),
            ],
            resources: [
                .process("ContactLocationManager.xcdatamodeld"),
            ]
        ),
        .testTarget(
            name: "ContactLocationManagerTests",
            dependencies: ["ContactLocationManager"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
