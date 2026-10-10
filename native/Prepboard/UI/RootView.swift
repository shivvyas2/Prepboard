import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(\.modelContext) private var context
    #if os(macOS)
    @Environment(ClaudeCode.self) private var claude
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var app = app
        Group {
            if cloud.configured && !cloud.ready {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cloud.configured && cloud.user == nil {
                AuthView()
            } else {
                #if os(iOS)
                if sizeClass == .compact { compactShell } else { wideShell }
                #else
                wideShell
                #endif
            }
        }
        .background(PB.background)
        .foregroundStyle(PB.ink)
        .tint(PB.cobalt)
        .modifier(AppSheets())
        .onChange(of: cloud.needsOnboarding) { if cloud.needsOnboarding { cloud.needsOnboarding = false; app.showNewPrep = true } }
    }

    @ViewBuilder
    private var content: some View {
        switch app.section {
        case .timeline: PrepTimelineView()
        case .dashboard: DashboardView()
        case .roles: RolesView()
        case .documents: DocumentsView()
        case .scores: ScoresView()
        case .browse: BrowserView()
        case .search: SearchView()
        }
    }

    // MARK: Mac / iPad — rail + pill tabs, like the web app

    private var wideShell: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 12) {
                PrepBoardLogo(size: 48).help("PrepBoard").padding(.bottom, 6)
                Button { app.showProfile = true } label: {
                    ProfileAvatar(size: 48)
                        .padding(2)
                        .overlay(Circle().strokeBorder(PB.line2, lineWidth: 1.5))
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(PB.sun).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(PB.bg, lineWidth: 2)).offset(x: 1, y: -1)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("Profile")
                .padding(.bottom, 18)
                ForEach(Section.allCases) { s in
                    CircleIconButton(systemImage: s.icon, size: 48, active: app.section == s, label: s.rawValue) { app.section = s }
                }
                Spacer()
                #if os(macOS)
                if claude.isReady {
                    Button { app.showClaude.toggle() } label: {
                        ClaudeMark().frame(width: 24, height: 24)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color(hex: 0xF5EDE4)))
                            .overlay(Circle().strokeBorder(app.showClaude ? Color(hex: 0xD97757) : PB.line, lineWidth: app.showClaude ? 2 : 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Ask Claude Code (⌘J)")
                }
                #endif
                CircleIconButton(systemImage: "square.and.arrow.down", size: 48, label: "Import JSON") { app.showImporter = true }
                CircleIconButton(systemImage: "square.and.arrow.up", size: 48, label: "Export JSON") { app.prepareExport(context) }
            }
            .padding(.vertical, 20)
            .frame(width: 80)
            #if os(macOS)
            .padding(.top, 18)
            #endif

            VStack(alignment: .leading, spacing: 20) {
                topBar
                HStack(alignment: .top, spacing: 18) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    #if os(macOS)
                    if app.showClaude && claude.isReady {
                        ClaudePanel().frame(width: 400).padding(.bottom, 20)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    #endif
                }
                .animation(.snappy, value: app.showClaude)
            }
            .padding(.top, 20).padding(.trailing, 24)
            #if os(macOS)
            .padding(.top, 10)
            #endif
        }
    }

    private var topBar: some View {
        @Bindable var app = app
        return ViewThatFits(in: .horizontal) {
            topBarContent(showTabs: true)
            topBarContent(showTabs: false)
        }
    }

    private func topBarContent(showTabs: Bool) -> some View {
        @Bindable var app = app
        return HStack(spacing: 12) {
            if showTabs { HStack(spacing: 4) {
                ForEach(Section.allCases) { s in
                    Button { app.section = s } label: {
                        Text(s.rawValue).font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 18).frame(height: 40)
                            .foregroundStyle(app.section == s ? Color.white : PB.ink2)
                            .background(Capsule().fill(app.section == s ? PB.cobalt : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            } }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(PB.muted)
                TextField("Search roles, docs, sessions…", text: $app.searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: app.searchText) { if !app.searchText.isEmpty { app.section = .search } }
            }
            .padding(.horizontal, 16).frame(minWidth: 200, maxWidth: 360).frame(height: 44)
            .background(Capsule().fill(PB.card)).overlay(Capsule().strokeBorder(PB.line))
            newMenu
        }
    }

    private var newMenu: some View {
        Menu {
            Button("Start something new…") { app.showNewPrep = true }
            Divider()
            Button("Prep session") { app.newSession(roleId: app.timelineRoleID) }
            Button("Document") { app.newDoc(context, roleId: app.timelineRoleID ?? "") }
            Button("Role") { app.newRole(context) }
        } label: {
            Label("New", systemImage: "plus").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20).frame(height: 44)
                .foregroundStyle(.white)
                .background(Capsule().fill(PB.cobalt))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    // MARK: iPhone — tab bar

    #if os(iOS)
    private var compactShell: some View {
        @Bindable var app = app
        return TabView(selection: $app.section) {
            ForEach(Section.allCases) { s in
                NavigationStack {
                    content
                        .padding(.horizontal, 16).padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(PB.background)
                        .toolbar {
                            ToolbarItem(placement: .principal) { PrepBoardMark().frame(width: 22, height: 26) }
                            ToolbarItem(placement: .topBarTrailing) { newMenu.scaleEffect(0.85) }
                            ToolbarItem(placement: .topBarLeading) {
                                Menu {
                                    Button("Profile") { app.showProfile = true }
                                    Button("Import JSON") { app.showImporter = true }
                                    Button("Export JSON") { app.prepareExport(context) }
                                } label: { ProfileAvatar(size: 30) }
                            }
                        }
                }
                .tabItem { Label(s.rawValue, systemImage: s.icon) }
                .tag(s)
            }
        }
    }
    #endif
}

/// All app-level sheets, file pickers and alerts (kept separate so the root view type-checks quickly).
struct AppSheets: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        @Bindable var app = app
        return content
            .sheet(item: $app.sessionEditor) { SessionEditorSheet(draft: $0) }
            .sheet(isPresented: $app.showProfile) { ProfileSheet() }
            .sheet(isPresented: $app.showNewPrep) { NewPrepView() }
            .sheet(item: $app.playingVideo) { VideoPlayerSheet(video: $0) }
            .sheet(item: Binding(get: { app.quizSessionID.map(IdentifiedString.init) }, set: { app.quizSessionID = $0?.id })) { QuizSheet(sessionID: $0.id) }
            .sheet(item: Binding(get: { app.reviewQuizID.map(IdentifiedString.init) }, set: { app.reviewQuizID = $0?.id })) { QuizSheet(reviewID: $0.id) }
            .fileImporter(isPresented: $app.showImporter, allowedContentTypes: [.json]) { result in
                guard case let .success(url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try Transfer.importData(try Data(contentsOf: url), into: context, replace: false); app.message = "Imported" }
                catch { app.message = "That file isn't a PrepBoard export." }
            }
            .fileExporter(isPresented: $app.showExporter, document: app.exportFile ?? JSONFile(data: Data()),
                          contentType: .json, defaultFilename: "prepboard-\(DateCoding.dayString(.now)).json") { _ in }
            .alert(app.message ?? "", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }
}
