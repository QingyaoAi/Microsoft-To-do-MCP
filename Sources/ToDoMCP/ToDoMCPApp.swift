import SwiftUI

@main
struct ToDoMCPApp: App {
    @StateObject private var model = AppModel()

    init() {
        if let status = CommandLineMode.runIfRequested() { exit(status) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.needsAttention ? "exclamationmark.circle" : "checklist")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var body: some View {
        signInSection
        Divider()
        Menu("Connect to Agent") {
            ForEach(Agents.all) { agent in agentItem(agent) }
            Divider()
            Button("Copy Server Command") { model.session.copy(model.serverCommand) }
        }
        Menu("Install Skill") {
            ForEach(Skills.targets) { target in skillItem(target) }
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Check Sign-in Now") { model.checkSignIn(forceRefresh: true); model.refreshIntegrations() }
        Button("Open Microsoft To Do") { NSWorkspace.shared.open(URL(string: "https://to-do.live.com")!) }
        Button("Help (GitHub)") { NSWorkspace.shared.open(URL(string: "https://github.com/QingyaoAi/Microsoft-To-do-MCP")!) }
        Divider()
        Text("To Do MCP \(version)")
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    @ViewBuilder private var signInSection: some View {
        switch model.signIn {
        case .checking:
            Text("Checking sign-in…")
        case .signedOut:
            Text("Not signed in to Microsoft To Do")
            Button("Sign In…") { model.startSignIn() }
        case let .ok(user):
            Text("Signed in as \(user)")
            Button("Sign Out") { model.signOut() }
        case let .expired(user):
            Text("⚠︎ Sign-in expired (\(user))")
            Button("Sign In Again…") { model.startSignIn() }
        case let .error(message):
            Text("⚠︎ \(String(message.prefix(60)))")
            Button("Sign In…") { model.startSignIn() }
        }
    }

    @ViewBuilder private func agentItem(_ agent: Agent) -> some View {
        switch model.agentStates[agent.id] ?? .notInstalled {
        case .notInstalled:
            Text("\(agent.name) (not installed)")
        case .notConnected:
            Button("\(agent.name): Connect") { model.connect(agent) }
        case .connected:
            Menu("✓ \(agent.name)") {
                Button("Disconnect") { model.disconnect(agent) }
            }
        case .otherCopy:
            Menu("\(agent.name): uses another copy") {
                Button("Switch to This App") { model.connect(agent) }
                Button("Disconnect") { model.disconnect(agent) }
            }
        }
    }

    @ViewBuilder private func skillItem(_ target: SkillTarget) -> some View {
        switch model.skillStates[target.id] ?? .unavailable {
        case .unavailable:
            Text("\(target.name) (not installed)")
        case .notInstalled:
            Button("\(target.name): Install") { model.installSkill(target) }
        case .installed:
            Text("✓ \(target.name) (up to date)")
        case .different:
            Button("\(target.name): Replace Existing Copy…") { model.installSkill(target) }
        }
    }
}
