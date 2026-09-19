import AppKit
import SwiftUI

/// Runs `mstodo-mcp login --json` and drives the sign-in window.
@MainActor
final class SignInSession: ObservableObject {
    enum Phase: Equatable {
        case starting
        case waiting(code: String, url: URL)
        case done(user: String)
        case failed(String)
    }

    @Published var phase: Phase = .starting
    var onSignedIn: ((String) -> Void)?
    private var process: Process?
    private var window: NSWindow?

    func start() {
        showWindow()
        if process?.isRunning == true { return }  // already waiting for this sign-in
        phase = .starting
        process = Shell.stream(Shell.launcher, ["login", "--json"], onLine: { line in
            let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            Task { @MainActor in self.handle(event) }
        }, onExit: { status in
            Task { @MainActor in
                if case .starting = self.phase { self.phase = .failed("Sign-in couldn't start (exit code \(status)).") }
                if case .waiting = self.phase { self.phase = .failed("Sign-in stopped before it finished.") }
            }
        })
    }

    private func handle(_ event: [String: Any]?) {
        switch event?["event"] as? String {
        case "code":
            guard let code = event?["user_code"] as? String,
                  let url = (event?["verification_uri"] as? String).flatMap(URL.init(string:)) else { return }
            phase = .waiting(code: code, url: url)
            copy(code)
            NSWorkspace.shared.open(url)
        case "done":
            let user = event?["user"] as? String ?? ""
            phase = .done(user: user)
            onSignedIn?(user)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.window?.close() }
        case "error":
            phase = .failed(event?["message"] as? String ?? "Sign-in failed.")
        default:
            break
        }
    }

    func cancel() {
        process?.terminate()
        window?.close()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Sign in to Microsoft To Do"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SignInView(session: self))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SignInView: View {
    @ObservedObject var session: SignInSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .starting:
                ProgressView("Contacting Microsoft…")
            case let .waiting(code, url):
                Text("1. A Microsoft page has opened in your browser.")
                HStack {
                    Text("2. Paste this code there:")
                    Text(code).font(.system(.title2, design: .monospaced)).bold().textSelection(.enabled)
                    Button("Copy") { session.copy(code) }
                }
                Text("3. Sign in with your Microsoft account and accept.")
                Text("The code is already on your clipboard. This window updates when you're done.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Page Again") { NSWorkspace.shared.open(url) }
                    Spacer()
                    Button("Cancel") { session.cancel() }
                }
            case let .done(user):
                Label("Signed in as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Agents connected to To Do MCP can use Microsoft To Do again.")
            case let .failed(message):
                Label("Sign-in didn't complete", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).font(.callout).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Close") { session.cancel() }
                    Button("Try Again") { session.start() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}
