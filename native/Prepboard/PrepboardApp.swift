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
    @State private var jobHunt = JobHunt()
    @State private var huntBrowser = HuntBrowser()
    @State private var browserServer = BrowserServer()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Role.self, Doc.self, PrepTask.self, QuizAttempt.self, Problem.self, Lead.self, HuntSettings.self)
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
                .environment(jobHunt)
                .environment(huntBrowser)
                .environment(browserServer)
                .environment(WorkspaceManager.shared)
                .task {
                    // Extra windows get the same models and store as the main one (their own AppState for sections).
                    let (profile, cloud, browser, claude, github, deviceBridge, jobSync, jobHunt, huntBrowser, browserServer, container) =
                        (profile, cloud, browser, claude, github, deviceBridge, jobSync, jobHunt, huntBrowser, browserServer, container)
                    WorkspaceManager.shared.configure(app: app, claudeAvailable: { claude.isReady }) { view, state in
                        AnyView(view
                            .environment(state).environment(profile).environment(cloud).environment(browser)
                            .environment(claude).environment(github).environment(deviceBridge).environment(jobSync).environment(jobHunt)
                            .environment(huntBrowser).environment(browserServer)
                            .environment(WorkspaceManager.shared)
                            .modelContainer(container)
                            .preferredColorScheme(.light))
                    }
                }
                .task {
                    await claude.checkConnection()   // picks up an installed, signed-in Claude Code on launch
                    try? browserServer.start(browser: huntBrowser)   // the hunt and the LinkedIn sync refuse to run until this is up
                    _ = await browserServer.ready()   // the port arrives asynchronously; attach() below may run a sync or hunt at once
                    deviceBridge.attach(claude)
                    jobSync.attach(container: container, claude: claude, browser: browserServer)
                    jobHunt.attach(container: container, claude: claude, cloud: cloud, github: github, browser: browserServer)
                }
                #if DEBUG
                // `-PrepboardBrowserSmoke 1`: once the browser server is up, drive it through `claude -p` and log the reply (local testing only).
                .task {
                    guard UserDefaults.standard.bool(forKey: "PrepboardBrowserSmoke") else { return }
                    var waited = 0
                    while !browserServer.isRunning, waited < 100 { waited += 1; try? await Task.sleep(for: .milliseconds(100)) }
                    guard browserServer.isRunning else { print("PrepboardBrowserSmoke: the browser server did not start"); return }
                    let out = await ClaudeCode.shell("claude -p --output-format json \(browserServer.claudeFlags(extraTools: "")) 2>/dev/null",
                                                     stdin: "Use the prepboard browser tools: navigate to https://example.com, then read_page, and reply with exactly the page's h1 text (or its title if the page has no h1).")
                    let reply = out.firstIndex(of: "{").flatMap { try? JSONSerialization.jsonObject(with: Data(out[$0...].utf8)) as? [String: Any] }?["result"] as? String
                    print("PrepboardBrowserSmoke:", reply ?? String(out.suffix(400)))
                    fflush(stdout)   // stdout is block-buffered when piped; the launcher reads this line before quitting the app
                }
                #endif
                .frame(minWidth: 1000, minHeight: 680)
                #endif
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            PrepboardCommands(app: app, container: container)
            WorkspaceCommands(workspace: WorkspaceManager.shared)
        }
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
            ForEach(Array(Section.allCases.prefix(9).enumerated()), id: \.element) { idx, s in   // ⌘1–⌘9; Search has ⌘F
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
