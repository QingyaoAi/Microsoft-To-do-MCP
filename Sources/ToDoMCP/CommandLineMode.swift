import Foundation

/// Scriptable, headless use of the app's setup actions (also used by the test scripts):
///   ToDoMCP --diagnose
///   ToDoMCP --connect <agent-id> | --disconnect <agent-id>
///   ToDoMCP --install-skill <claude|codex> [--replace]
/// Agent ids: claude-code, codex, claude-desktop, cursor, gemini.
enum CommandLineMode {
    static func runIfRequested() -> Int32? {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, command.hasPrefix("--") else { return nil }
        let server = Shell.launcher.path
        let target = args.count > 1 ? args[1] : ""

        switch command {
        case "--diagnose":
            let report: [String: Any] = [
                "serverCommand": server,
                "agents": Dictionary(uniqueKeysWithValues: Agents.all.map { ($0.id, describe($0.state(for: server))) }),
                "skills": Dictionary(uniqueKeysWithValues: Skills.targets.map { ($0.id, "\($0.state)") }),
            ]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            return 0

        case "--connect", "--disconnect":
            guard let agent = Agents.all.first(where: { $0.id == target }) else {
                return fail("unknown agent \(target.debugDescription); use one of \(Agents.all.map(\.id))")
            }
            do {
                if command == "--connect" { try agent.connect(server) } else { try agent.disconnect() }
                print("\(command == "--connect" ? "connected" : "disconnected") \(agent.name)")
                return 0
            } catch {
                return fail(error.localizedDescription)
            }

        case "--install-skill":
            guard let skill = Skills.targets.first(where: { $0.id == target }) else {
                return fail("unknown skill target \(target.debugDescription); use one of \(Skills.targets.map(\.id))")
            }
            if skill.state == .different && !args.contains("--replace") {
                return fail("a different ms-todo skill is installed at \(skill.destination.path); pass --replace to move it to skill-backups and install this one")
            }
            do {
                let backup = try Skills.install(skill)
                print("installed skill for \(skill.name)" + (backup.map { "; previous copy moved to \($0.path)" } ?? ""))
                return 0
            } catch {
                return fail(error.localizedDescription)
            }

        default:
            return fail("usage: ToDoMCP [--diagnose | --connect <agent> | --disconnect <agent> | --install-skill <target> [--replace]]")
        }
    }

    private static func describe(_ state: Agent.State) -> String {
        switch state {
        case .notInstalled: return "not installed"
        case .notConnected: return "not connected"
        case .connected: return "connected"
        case let .otherCopy(command): return "uses another copy: \(command)"
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }
}
