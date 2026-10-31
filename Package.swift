// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GhostTrace",
    platforms: [.macOS(.v26)],
    products: [
        // Consumed by the Xcode app target in App/GhostTrace.xcodeproj.
        .library(name: "GhostTraceKit", targets: ["RecorderCore", "Collectors", "EventStore", "InvestigationKit", "GhostTraceIPC"]),
        .executable(name: "ghosttrace", targets: ["GhostTraceCLI"]),
        .executable(name: "RecorderAgent", targets: ["RecorderAgent"]),
    ],
    targets: [
        .target(name: "RecorderCore"),
        .target(name: "Collectors", dependencies: ["RecorderCore"]),
        .target(name: "EventStore", dependencies: ["RecorderCore"]),
        .target(name: "InvestigationKit", dependencies: ["RecorderCore"]),
        .target(name: "GhostTraceIPC", dependencies: ["RecorderCore", "InvestigationKit"]),
        .executableTarget(name: "RecorderAgent", dependencies: ["RecorderCore", "Collectors", "EventStore", "InvestigationKit", "GhostTraceIPC"]),
        .target(name: "MCPBridge", dependencies: ["GhostTraceIPC", "RecorderCore"]),
        .executableTarget(name: "GhostTraceCLI", dependencies: ["GhostTraceIPC", "InvestigationKit", "MCPBridge", "RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
        .testTarget(name: "CollectorsTests", dependencies: ["Collectors"]),
        .testTarget(name: "EventStoreTests", dependencies: ["EventStore", "RecorderCore"]),
        .testTarget(name: "InvestigationKitTests", dependencies: ["InvestigationKit", "Collectors", "RecorderCore"]),
        .testTarget(name: "GhostTraceIPCTests", dependencies: ["GhostTraceIPC", "InvestigationKit", "RecorderCore"]),
        .testTarget(name: "MCPBridgeTests", dependencies: ["MCPBridge", "GhostTraceIPC", "InvestigationKit", "RecorderCore"]),
    ]
)
