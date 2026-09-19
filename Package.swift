// swift-tools-version:5.9
// Menu-bar app that bundles the mstodo MCP server. Build the .app with scripts/build-app.sh.
import PackageDescription

let package = Package(
    name: "ToDoMCP",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ToDoMCP", path: "Sources/ToDoMCP")
    ]
)
