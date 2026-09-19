import Foundation

/// Runs command-line programs for the app. All functions block, so call them off the main thread.
enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// The user's home folder; honors $HOME so the command-line test mode can use a scratch home.
    static let home: URL = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser

    /// Expands a leading "~/" against `home`.
    static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
    }

    /// The bundled server launcher. MSTODO_CLI overrides it for development builds.
    static var launcher: URL {
        if let path = ProcessInfo.processInfo.environment["MSTODO_CLI"] {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mstodo-mcp")
    }

    static func run(_ executable: URL, _ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain stderr concurrently so a chatty program can't fill the pipe and block.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a command the way the user's terminal would find it. Apps opened from Finder get a
    /// minimal PATH, and tools such as `claude` are Node scripts that also need `node` on PATH.
    static func runInLoginShell(_ arguments: [String]) -> Output {
        var shell = "/bin/zsh"
        if let entry = getpwuid(getuid()), let userShell = String(validatingUTF8: entry.pointee.pw_shell),
           ["bash", "zsh", "sh"].contains(URL(fileURLWithPath: userShell).lastPathComponent) {
            shell = userShell
        }
        let script = #"export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"; exec "$@""#
        return run(URL(fileURLWithPath: shell), ["-lc", script, "todo-mcp"] + arguments)
    }

    static func commandExists(_ name: String) -> Bool {
        runInLoginShell(["/bin/sh", "-c", "command -v \"$0\" >/dev/null", name]).ok
    }

    /// Streams stdout line by line (for `login --json`). Returns the running process.
    static func stream(
        _ executable: URL, _ arguments: [String],
        onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                onLine(line)
            }
        }
        process.terminationHandler = { onExit($0.terminationStatus) }
        do {
            try process.run()
            return process
        } catch {
            onExit(-1)
            return nil
        }
    }
}
