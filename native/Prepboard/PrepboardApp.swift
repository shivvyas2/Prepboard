import SwiftData
import SwiftUI

@main
struct PrepboardApp: App {
    @State private var app = AppState()
    @State private var profile = Profile()
    @State private var cloud = Cloud()
    @State private var browser = BrowserModel()
    @State private var claude = ClaudeCode()
    @State private var github = GitHub()
    #if os(macOS)
    @State private var deviceBridge = DeviceBridge()
    @State private var jobSync = JobSync()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Role.self, Doc.self, PrepTask.self, QuizAttempt.self, Problem.self)
        } catch {
            fatalError("Could not open the Prepboard store: \(error)")
        }
        // `-PrepboardImport /path/export.json` replaces local data with a Prepboard export (demo/testing).
        if let path = UserDefaults.standard.string(forKey: "PrepboardImport"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            try? Transfer.importData(data, into: container.mainContext, replace: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(profile)
                .environment(cloud)
                .environment(browser)
                .task { cloud.attach(container: container, profile: profile) }
                .preferredColorScheme(.light)
                .environment(claude)
                .environment(github)
                // Bring in other devices' changes whenever the app comes back to the front.
                .onChange(of: scenePhase) { if scenePhase == .active { cloud.refreshIfStale() } }
                #if os(iOS)
                // Re-check the paired Mac when the app comes back, so AI requests go to the right place.
                .onChange(of: scenePhase) { if scenePhase == .active, claude.paired { Task { await claude.checkConnection() } } }
                #if DEBUG
                // `-PrepboardBridgeTest address,code`: pair at launch and log the result (local testing only).
                .task {
                    if let t = UserDefaults.standard.string(forKey: "PrepboardBridgeTest")?.split(separator: ","), t.count == 2 {
                        await claude.pair(address: String(t[0]), code: String(t[1]))
                        print("PrepboardBridgeTest:", claude.connection)
                        if claude.isReady { print("PrepboardBridgeTest run:", (try? await claude.runText("Reply with exactly: PONG", tools: "Read").text) ?? "failed") }
                        if UserDefaults.standard.bool(forKey: "PrepboardRunnerTest") {
                            print("RUN js:", await CodeRunner.run("console.log([1,2,3].map(x => x * 2).join(','))", lang: .javascript, mac: claude).text)
                            print("RUN py:", await CodeRunner.run("import heapq, collections\nprint(sum(range(10)), heapq.nsmallest(2, [5, 1, 3]), collections.Counter('aab'))", lang: .python, mac: claude).text)
                            print("RUN swift:", await CodeRunner.run("print((1...4).reduce(0, +))", lang: .swift, mac: claude).text)
                        }
                    }
                }
                #endif
                #endif
                #if os(macOS)
                .environment(deviceBridge)
                .environment(jobSync)
                .task {
                    await claude.checkConnection()   // picks up an installed, signed-in Claude Code on launch
                    deviceBridge.attach(claude)
                    jobSync.attach(container: container, claude: claude)
                }
                .frame(minWidth: 1000, minHeight: 680)
                #endif
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands { PrepboardCommands(app: app, container: container) }
        #endif
    }
}

#if os(macOS)
struct PrepboardCommands: Commands {
    let app: AppState
    let container: ModelContainer

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Session") { app.newSession(roleId: app.timelineRoleID) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Document") { app.newDoc(container.mainContext, roleId: app.timelineRoleID ?? "") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Role") { app.newRole(container.mainContext) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Import JSON…") { app.showImporter = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export JSON…") { app.prepareExport(container.mainContext) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            ForEach(Array(Section.allCases.enumerated()), id: \.element) { idx, s in
                Button(s.rawValue) { app.section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
            }
            Divider()
            Button("Jump to Now") { app.section = .timeline; app.scrollTarget = "now" }
                .keyboardShortcut("t", modifiers: .command)
            Button("Search") { app.section = .search }
                .keyboardShortcut("f", modifiers: .command)
            Button("Ask Claude") { app.claudeTerminal = false; app.showClaude.toggle() }
                .keyboardShortcut("j", modifiers: .command)
            Button("Claude Code Terminal") { app.claudeTerminal = true; app.showClaude = true }
                .keyboardShortcut("j", modifiers: [.command, .shift])
        }
    }
}
#endif
