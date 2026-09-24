// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CopilotMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CopilotMonitor", targets: ["CopilotMonitor"]),
        .executable(name: "CopilotMonitorSelfTest", targets: ["CopilotMonitorSelfTest"])
    ],
    targets: [
        .target(name: "CopilotMonitorCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CopilotMonitor", dependencies: ["CopilotMonitorCore"]),
        .executableTarget(name: "CopilotMonitorSelfTest", dependencies: ["CopilotMonitorCore"])
    ]
)
