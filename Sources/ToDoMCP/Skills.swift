import Foundation

/// Installs the bundled `ms-todo` skill into agents that read skill folders.
struct SkillTarget: Identifiable {
    enum State: Equatable {
        case unavailable  // the agent isn't installed
        case notInstalled
        case installed  // identical to the bundled copy
        case different  // someone else's or a customized copy is there
    }

    let id: String
    let name: String
    let agentDir: String  // e.g. ~/.claude; the skill goes to <agentDir>/skills/ms-todo

    var destination: URL {
        URL(fileURLWithPath: Shell.expand(agentDir))
            .appendingPathComponent("skills/ms-todo")
    }

    var state: State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Shell.expand(agentDir)) else { return .unavailable }
        let installed = destination.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: installed.path) else { return .notInstalled }
        guard let bundled = Skills.bundledSkill else { return .different }
        return fm.contentsEqual(atPath: installed.path, andPath: bundled.appendingPathComponent("SKILL.md").path)
            ? .installed : .different
    }
}

enum Skills {
    static let targets = [
        SkillTarget(id: "claude", name: "Claude Code", agentDir: "~/.claude"),
        SkillTarget(id: "codex", name: "Codex CLI", agentDir: "~/.codex"),
    ]

    static var bundledSkill: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("skills/ms-todo") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Copies the bundled skill in. An existing different copy is moved aside, never deleted.
    /// Returns the backup location, if one was made.
    @discardableResult
    static func install(_ target: SkillTarget) throws -> URL? {
        guard let source = bundledSkill else {
            throw AgentError(message: "This build doesn't include the skill files.")
        }
        let fm = FileManager.default
        let dest = target.destination
        var backup: URL?
        if fm.fileExists(atPath: dest.path) {
            // Outside skills/, or the agent would load the backup as a second ms-todo skill.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backups = dest.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("skill-backups")
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            backup = backups.appendingPathComponent("ms-todo-\(stamp)")
            try fm.moveItem(at: dest, to: backup!)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: dest)
        return backup
    }
}
