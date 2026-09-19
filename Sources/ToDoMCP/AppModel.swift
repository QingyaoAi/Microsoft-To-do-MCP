import AppKit
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum SignIn: Equatable {
        case checking
        case signedOut
        case ok(user: String)
        case expired(user: String)
        case error(String)
    }

    @Published var signIn: SignIn = .checking
    @Published var agentStates: [String: Agent.State] = [:]
    @Published var skillStates: [String: SkillTarget.State] = [:]
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let session = SignInSession()
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 20 * 3600  // renew the sign-in about daily
    private var lastRefresh: Date? {
        get { UserDefaults.standard.object(forKey: "lastRefresh") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastRefresh") }
    }

    /// The command agents run to start the server: the launcher inside this app bundle.
    var serverCommand: String { Shell.launcher.path }

    /// macOS runs unsigned apps opened from Downloads from a random read-only copy
    /// ("App Translocation"); a path registered from there would break later.
    var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    var needsAttention: Bool {
        switch signIn {
        case .signedOut, .expired, .error: return true
        default: return false
        }
    }

    override init() {
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        session.onSignedIn = { [weak self] user in
            self?.signIn = .ok(user: user)
            self?.lastRefresh = Date()
            self?.notify("Signed in as \(user). Microsoft To Do is connected.")
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.checkSignIn() } }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignIn() }
        }
        checkSignIn()
        refreshIntegrations()
    }

    // MARK: Sign-in

    /// Checks the saved sign-in, renewing it when the last renewal is older than a day.
    func checkSignIn(forceRefresh: Bool = false) {
        let due = forceRefresh || lastRefresh.map { Date().timeIntervalSince($0) > refreshInterval } ?? true
        let launcher = Shell.launcher
        Task.detached {
            let args = ["status", "--json"] + (due ? ["--refresh"] : [])
            let output = Shell.run(launcher, args)
            let json = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))) as? [String: Any]
            await MainActor.run { self.applyStatus(json, output: output, refreshed: due) }
        }
    }

    private func applyStatus(_ json: [String: Any]?, output: Shell.Output, refreshed: Bool) {
        let user = json?["user"] as? String ?? ""
        let previous = signIn
        switch json?["state"] as? String {
        case "ok":
            signIn = .ok(user: user)
            if refreshed { lastRefresh = Date() }
        case "signed_out":
            signIn = .signedOut
        case "login_required":
            signIn = .expired(user: user)
            if previous != signIn {
                notify("Your Microsoft To Do sign-in has expired. Click to sign in again.", signInOnClick: true)
            }
        case "error":
            // Usually offline; keep the last known state and try again next hour.
            if case .checking = previous { signIn = .error(json?["message"] as? String ?? "Unknown error") }
        default:
            let detail = output.stderr.isEmpty ? "exit code \(output.status)" : output.stderr
            signIn = .error("The bundled server couldn't run: \(detail)")
        }
    }

    func startSignIn() {
        session.start()
    }

    func signOut() {
        let launcher = Shell.launcher
        Task.detached {
            _ = Shell.run(launcher, ["logout", "--json"])
            await MainActor.run { self.signIn = .signedOut }
        }
    }

    // MARK: Agents and skills

    func refreshIntegrations() {
        let command = serverCommand
        Task.detached {
            let agents = Dictionary(uniqueKeysWithValues: Agents.all.map { ($0.id, $0.state(for: command)) })
            let skills = Dictionary(uniqueKeysWithValues: Skills.targets.map { ($0.id, $0.state) })
            await MainActor.run {
                self.agentStates = agents
                self.skillStates = skills
            }
        }
    }

    func connect(_ agent: Agent) {
        if isTranslocated {
            alert("Move “To Do MCP” to your Applications folder first",
                  "macOS is running it from a temporary location, so the path an agent would use stops working later. Drag the app to Applications, open it from there, and try again.")
            return
        }
        let command = serverCommand
        Task.detached {
            do {
                try agent.connect(command)
                await MainActor.run {
                    self.alert("Connected to \(agent.name)", agent.restartNote ?? "")
                    self.refreshIntegrations()
                }
            } catch {
                await MainActor.run { self.alert("Couldn't connect to \(agent.name)", error.localizedDescription) }
            }
        }
    }

    func disconnect(_ agent: Agent) {
        Task.detached {
            do {
                try agent.disconnect()
                await MainActor.run { self.refreshIntegrations() }
            } catch {
                await MainActor.run { self.alert("Couldn't disconnect \(agent.name)", error.localizedDescription) }
            }
        }
    }

    func installSkill(_ target: SkillTarget) {
        if target.state == .different {
            let confirm = NSAlert()
            confirm.messageText = "Replace the ms-todo skill in \(target.name)?"
            confirm.informativeText = "A different or customized copy is already installed at \(target.destination.path). It will be moved to \(target.agentDir)/skill-backups, not deleted."
            confirm.addButton(withTitle: "Keep Existing")
            confirm.addButton(withTitle: "Replace")
            NSApp.activate(ignoringOtherApps: true)
            guard confirm.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let backup = try Skills.install(target)
            alert("Skill installed for \(target.name)",
                  backup.map { "The previous copy was moved to \($0.path)." } ?? "New \(target.name) sessions will use it.")
        } catch {
            alert("Couldn't install the skill", error.localizedDescription)
        }
        refreshIntegrations()
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Notifications and alerts

    private func notify(_ body: String, signInOnClick: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "To Do MCP"
            content.body = body
            content.userInfo = ["signIn": signInOnClick]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let wantsSignIn = response.notification.request.content.userInfo["signIn"] as? Bool ?? false
        Task { @MainActor in if wantsSignIn { self.startSignIn() } }
        completionHandler()
    }

    func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
