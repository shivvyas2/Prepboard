import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(\.modelContext) private var context
    @State private var windowSize: CGSize = .zero
    #if os(macOS)
    @Environment(ClaudeCode.self) private var claude
    @Environment(WorkspaceManager.self) private var workspace
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
        .background(GeometryReader { g in
            Color.clear
                .onAppear { windowSize = g.size }
                .onChange(of: g.size) { windowSize = g.size }
        })
        .environment(\.pbWindowSize, windowSize)
        #if os(macOS)
        .background(HostWindowReader { workspace.registerMain($0) })
        .overlay(alignment: .top) {
            if let s = workspace.suggestion {
                WorkspaceBanner(layouts: s).padding(.top, 20).padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: workspace.suggestion)
        #endif
        .onChange(of: cloud.needsOnboarding) { if cloud.needsOnboarding { cloud.needsOnboarding = false; app.showNewPrep = true } }
    }

    private var content: some View { SectionContent(section: app.section) }

    // MARK: Mac / iPad — rail + pill tabs, like the web app

    private var wideShell: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
            VStack(alignment: .leading, spacing: 24) {
                topBar
                workspaceContent
            }
            .padding(.top, 24).padding(.trailing, 24)
            #if os(macOS)
            .padding(.top, 12)
            #endif
        }
    }

    /// The rail scrolls when the window is short (iPad landscape, small Mac windows), so nothing is cut off.
    private var rail: some View {
        GeometryReader { railGeo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    PrepBoardLogo(size: 48).help("PrepBoard").padding(.bottom, 8)
                    Button { app.showProfile = true } label: {
                        ProfileAvatar(size: 48)
                            .padding(4)
                            .overlay(Circle().strokeBorder(PB.line2, lineWidth: 1.5))
                            .overlay(alignment: .topTrailing) {
                                Circle().fill(PB.sun).frame(width: 12, height: 12)
                                    .overlay(Circle().strokeBorder(PB.bg, lineWidth: 2)).offset(x: 1, y: -1)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Profile")
                    .padding(.bottom, 16)
                    ForEach(Section.allCases) { s in
                        CircleIconButton(systemImage: s.icon, size: 48, active: app.section == s, label: s.rawValue) { app.section = s }
                            .accessibilityAddTraits(app.section == s ? [.isSelected] : [])
                            #if os(macOS)
                            .contextMenu {
                                Button("Open in New Window") { workspace.open(.section(s)) }
                                if workspace.screens.count > 1 {
                                    Menu("Open on") {
                                        ForEach(workspace.screens) { sc in Button(sc.name) { workspace.open(.section(s), on: sc) } }
                                    }
                                }
                            }
                            #endif
                    }
                    Spacer()
                    #if os(macOS)
                    if claude.isReady {
                        Button { app.showClaude.toggle() } label: {
                            ClaudeMark().frame(width: 24, height: 24)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(PB.card))
                                .overlay(Circle().strokeBorder(app.showClaude ? PB.cobalt : PB.line, lineWidth: app.showClaude ? 2 : 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain).help("Ask Claude Code (⌥C)")
                        .accessibilityLabel("Claude Code")
                        .accessibilityAddTraits(app.showClaude ? [.isSelected] : [])
                        .contextMenu { Button("Open Claude in Its Own Window") { workspace.open(.claude) } }
                    }
                    #endif
                    CircleIconButton(systemImage: "square.and.arrow.down", size: 48, label: "Import JSON") { app.showImporter = true }
                    CircleIconButton(systemImage: "square.and.arrow.up", size: 48, label: "Export JSON") { app.prepareExport(context) }
                }
                .padding(.vertical, 24)
                #if os(macOS)
                .padding(.top, 16)
                #endif
                .frame(width: 80)
                .frame(minHeight: railGeo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 80)
    }

    /// Claude Code floats over the page instead of docking, so the page keeps its full width and stays usable behind it.
    private var workspaceContent: some View {
        GeometryReader { geo in
            let panelWidth: CGFloat = app.claudeTerminal ? 560 : 400
            let hasVideo = app.sideVideo != nil && !videoDetached
            let dockVideo = hasVideo && geo.size.width >= 896
            let mainWidth = max(0, geo.size.width - (dockVideo ? 356 : 0))
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        if let video = app.sideVideo, hasVideo && !dockVideo {
                            SideVideoPanel(video: video, compact: true)
                                .frame(maxWidth: 320)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: mainWidth, height: geo.size.height, alignment: .top)
                    if let video = app.sideVideo, dockVideo {
                        SideVideoPanel(video: video).frame(width: 340)
                    }
                }
                #if os(macOS)
                if claudeVisible {
                    ClaudePanel()
                        .frame(width: min(panelWidth, max(0, geo.size.width - 16)))
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, 20)
                        .shadow(color: PB.shadow.opacity(0.16), radius: 28, x: -4, y: 12)
                        .onExitCommand { app.showClaude = false }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                #endif
            }
            .animation(.snappy, value: claudeVisible)
            .animation(.snappy, value: app.claudeTerminal)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var claudeVisible: Bool {
        #if os(macOS)
        app.showClaude && claude.isReady && !workspace.isDetached(.claude)
        #else
        false
        #endif
    }

    private var videoDetached: Bool {
        #if os(macOS)
        workspace.isDetached(.video)
        #else
        false
        #endif
    }

    /// The rail is the only navigation and each page carries its own heading, so the top bar holds just search and New.
    private var topBar: some View {
        @Bindable var app = app
        return HStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(PB.muted)
                TextField("Search roles, docs, sessions…", text: $app.searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: app.searchText) { if !app.searchText.isEmpty { app.section = .search } }
            }
            .padding(.horizontal, 16).frame(minWidth: 140, maxWidth: 360).frame(height: 44)
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
                .padding(.horizontal, 24).frame(height: 44)
                .foregroundStyle(.white)
                .background(Capsule().fill(PB.cobalt))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    // MARK: iPhone — tab bar

    #if os(iOS)
    /// iPhone tabs: the four most-used sections, then PrepBoard's own "More" (one top bar, no nested navigation).
    private static let primaryTabs: [Section] = [.dashboard, .hunt, .roles, .timeline]
    private static let moreTabs: [Section] = Section.allCases.filter { !primaryTabs.contains($0) }

    private var compactShell: some View {
        let selection = Binding<String>(
            get: { Self.primaryTabs.contains(app.section) ? app.section.rawValue : "more" },
            set: { tag in
                if let s = Self.primaryTabs.first(where: { $0.rawValue == tag }) { app.section = s }
                else if Self.primaryTabs.contains(app.section) { app.section = .documents }
            })
        return TabView(selection: selection) {
            ForEach(Self.primaryTabs) { s in
                compactPage { SectionContent(section: s) }
                    .tabItem { Label(s.rawValue, systemImage: s.icon) }
                    .tag(s.rawValue)
            }
            compactPage {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.moreTabs) { s in
                                Button { app.section = s } label: {
                                    Label(s.rawValue, systemImage: s.icon).font(.system(size: 14, weight: .semibold))
                                        .padding(.horizontal, 16).frame(height: 44)
                                        .foregroundStyle(app.section == s ? Color.white : PB.ink)
                                        .background(Capsule().fill(app.section == s ? PB.cobalt : PB.card))
                                        .overlay(Capsule().strokeBorder(app.section == s ? Color.clear : PB.line))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    SectionContent(section: Self.moreTabs.contains(app.section) ? app.section : .documents)
                }
            }
            .tabItem { Label("More", systemImage: "ellipsis") }
            .tag("more")
        }
        // iPhone: the video docks at the top and keeps playing across tabs.
        .safeAreaInset(edge: .top) {
            if let v = app.sideVideo { SideVideoPanel(video: v, compact: true).padding(.horizontal, 16).padding(.bottom, 8).background(PB.background) }
        }
    }

    private func compactPage<V: View>(@ViewBuilder _ page: () -> V) -> some View {
        NavigationStack {
                    page()
                        .padding(.horizontal, 16).padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(PB.background)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) { PrepBoardMark().frame(width: 22, height: 26) }
                            ToolbarItem(placement: .topBarTrailing) { newMenu }
                            ToolbarItem(placement: .topBarLeading) {
                                Menu {
                                    Button("Profile") { app.showProfile = true }
                                    Button("Import JSON") { app.showImporter = true }
                                    Button("Export JSON") { app.prepareExport(context) }
                                } label: { ProfileAvatar(size: 32) }
                            }
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
            #if os(iOS)
            .fullScreenCover(isPresented: $app.showPipeline) { PipelineScreen() }
            #else
            .sheet(isPresented: $app.showPipeline) { PipelineScreen() }
            #endif
            .sheet(isPresented: $app.showNewPrep, onDismiss: { app.newPrepRoleID = nil }) { NewPrepView() }
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

/// The view for one section; used by the main window and by detached section windows.
struct SectionContent: View {
    let section: Section

    var body: some View {
        switch section {
        case .timeline: PrepTimelineView()
        case .dashboard: DashboardView()
        case .roles: RolesView()
        case .hunt: HuntView()
        case .documents: DocumentsView()
        case .practice: PracticeView()
        case .essentials: EssentialsView()
        case .scores: ScoresView()
        case .browse: BrowserView()
        case .search: SearchView()
        }
    }
}
