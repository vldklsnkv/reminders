// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "RemindersPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reminders-mcp", targets: ["RemindersMCP"])
    ],
    targets: [
        .executableTarget(
            name: "RemindersMCP",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("CoreLocation")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
