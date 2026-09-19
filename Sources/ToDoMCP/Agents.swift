import Foundation

/// An AI agent (MCP client) the app can register the `mstodo` server with.
struct Agent: Identifiable {
    enum State: Equatable {
        case notInstalled
        case notConnected
        case connected
        case otherCopy(String)  // registered, but pointing at a different mstodo-mcp
    }

    let id: String
    let name: String
    let restartNote: String?
    let isInstalled: () -> Bool
    let registeredCommand: () -> String?
    let connect: (String) throws -> Void
    let disconnect: () throws -> Void

    func state(for command: String) -> State {
        guard isInstalled() else { return .notInstalled }
        guard let current = registeredCommand() else { return .notConnected }
        return current == command ? .connected : .otherCopy(current)
    }
}

struct AgentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Agents {
    static let serverName = "mstodo"

    static let all: [Agent] = [claudeCode, codex, claudeDesktop, cursor, gemini]

    // MARK: CLI-managed clients

    static let claudeCode = Agent(
        id: "claude-code", name: "Claude Code", restartNote: "Start a new Claude Code session to use it.",
        isInstalled: { exists(".claude.json") || Shell.commandExists("claude") },
        registeredCommand: {
            let config = readJSON(Shell.home.appendingPathComponent(".claude.json"))
            let servers = config?["mcpServers"] as? [String: Any]
            return (servers?[serverName] as? [String: Any])?["command"] as? String
        },
        connect: { command in
            _ = Shell.runInLoginShell(["claude", "mcp", "remove", serverName, "-s", "user"])
            try check(Shell.runInLoginShell(["claude", "mcp", "add", "--scope", "user", serverName, "--", command]))
        },
        disconnect: { try check(Shell.runInLoginShell(["claude", "mcp", "remove", serverName, "-s", "user"])) }
    )

    static let codex = Agent(
        id: "codex", name: "Codex CLI", restartNote: "Start a new Codex session to use it.",
        isInstalled: { exists(".codex") || Shell.commandExists("codex") },
        registeredCommand: { codexCommand() },
        connect: { command in
            _ = Shell.runInLoginShell(["codex", "mcp", "remove", serverName])
            try check(Shell.runInLoginShell(["codex", "mcp", "add", serverName, "--", command]))
        },
        disconnect: { try check(Shell.runInLoginShell(["codex", "mcp", "remove", serverName])) }
    )

    /// Reads `command = "..."` from the `[mcp_servers.mstodo]` table of ~/.codex/config.toml.
    private static func codexCommand() -> String? {
        let url = Shell.home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inTable = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inTable = line == "[mcp_servers.\(serverName)]"
            } else if inTable, line.hasPrefix("command") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                return parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    // MARK: Clients configured through an `mcpServers` JSON file

    static let claudeDesktop = jsonFileAgent(
        id: "claude-desktop", name: "Claude Desktop",
        file: "Library/Application Support/Claude/claude_desktop_config.json",
        installedIf: ["/Applications/Claude.app", "~/Applications/Claude.app"],
        restartNote: "Quit and reopen Claude Desktop to load it."
    )

    static let cursor = jsonFileAgent(
        id: "cursor", name: "Cursor", file: ".cursor/mcp.json",
        installedIf: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"],
        restartNote: "Restart Cursor to load it."
    )

    static let gemini = jsonFileAgent(
        id: "gemini", name: "Gemini CLI", file: ".gemini/settings.json",
        installedIf: ["~/.gemini"], restartNote: "Start a new Gemini CLI session to use it."
    )

    private static func jsonFileAgent(
        id: String, name: String, file: String, installedIf: [String], restartNote: String
    ) -> Agent {
        let url = Shell.home.appendingPathComponent(file)
        return Agent(
            id: id, name: name, restartNote: restartNote,
            isInstalled: {
                installedIf.contains { FileManager.default.fileExists(atPath: Shell.expand($0)) }
            },
            registeredCommand: {
                let servers = readJSON(url)?["mcpServers"] as? [String: Any]
                return (servers?[serverName] as? [String: Any])?["command"] as? String
            },
            connect: { command in
                try editJSON(url) { config in
                    var servers = config["mcpServers"] as? [String: Any] ?? [:]
                    servers[serverName] = ["command": command]
                    config["mcpServers"] = servers
                }
            },
            disconnect: {
                try editJSON(url) { config in
                    var servers = config["mcpServers"] as? [String: Any] ?? [:]
                    servers[serverName] = nil
                    config["mcpServers"] = servers
                }
            }
        )
    }

    // MARK: Helpers

    private static func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: Shell.home.appendingPathComponent(relativePath).path)
    }

    private static func check(_ output: Shell.Output) throws {
        guard output.ok else {
            let detail = [output.stderr, output.stdout].first { !$0.isEmpty } ?? "exit code \(output.status)"
            throw AgentError(message: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Changes one JSON config file, keeping every other setting and a backup of the original.
    /// Refuses to touch a file it can't parse rather than risk wiping the user's settings.
    private static func editJSON(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        var config: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError(message: "\(url.path) isn't plain JSON, so it was left unchanged. Add the server by hand (see the README).")
            }
            config = parsed
            let backup = url.appendingPathExtension("bak-todo-mcp")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        change(&config)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
