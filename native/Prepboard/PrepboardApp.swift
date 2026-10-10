import SwiftData
import SwiftUI

@main
struct PrepboardApp: App {
    @State private var app = AppState()
    @State private var profile = Profile()
    @State private var cloud = Cloud()
    @State private var browser = BrowserModel()
    #if os(macOS)
    @State private var claude = ClaudeCode()
    #endif
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Role.self, Doc.self, PrepTask.self, QuizAttempt.self)
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
                #if os(macOS)
                .environment(claude)
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
            Button("Ask Claude") { app.showClaude.toggle() }
                .keyboardShortcut("j", modifiers: .command)
        }
    }
}
#endif
