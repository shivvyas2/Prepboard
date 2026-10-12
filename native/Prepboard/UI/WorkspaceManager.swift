#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Puts PrepBoard's windows on your screens: extra section windows, the Claude and video panels on their own,
/// layouts per screen setup (restored when that setup comes back) and suggestions for setups it hasn't seen.
@MainActor
@Observable
final class WorkspaceManager {
    static let shared = WorkspaceManager()

    /// Connected screens, largest first.
    private(set) var screens: [WorkspaceScreen] = []
    /// Layouts to offer in the banner after a new screen setup appears; nil hides the banner.
    var suggestion: [WorkspaceLayout]?
    private(set) var namedLayouts: [WorkspaceLayout] = []
    /// Bumped whenever a detached window opens or closes, so views that check `isDetached` refresh.
    private(set) var revision = 0

    let store = WorkspaceStore()

    @MainActor private struct Managed {
        let window: NSWindow
        let base: WorkspaceContent
        let state: AppState?          // section windows have their own; panels share the main window's
        var content: WorkspaceContent {
            if case .section = base, let state { return .section(state.section) }
            return base
        }
    }

    private var managed: [Managed] = []
    private weak var mainWindow: NSWindow?
    private var mainApp: AppState?
    private var wrap: ((AnyView, AppState) -> AnyView)?
    private var claudeAvailable: () -> Bool = { false }
    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var quietUntil = Date.distantPast
    private var started = false

    private init() {}

    // MARK: setup

    /// Called once from the app with the main window's state and a function that gives a view the app's environment.
    func configure(app: AppState, claudeAvailable: @escaping () -> Bool, wrap: @escaping (AnyView, AppState) -> AnyView) {
        mainApp = app
        self.wrap = wrap
        self.claudeAvailable = claudeAvailable
        namedLayouts = store.named
        refreshScreens()
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            })
        }
        startIfReady()
    }

    func registerMain(_ window: NSWindow) {
        guard mainWindow == nil else { return }
        mainWindow = window
        observeFrame(of: window)
        startIfReady()
    }

    /// At launch: restore what this screen setup had last time, or suggest a layout for a new multi-screen setup.
    private func startIfReady() {
        guard !started, mainWindow != nil, mainApp != nil else { return }
        started = true
        quietUntil = .now.addingTimeInterval(3)   // windows restoring their frames at launch aren't the user arranging them
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))   // let the main window settle at its restored size first
            self.screenSetupArrived()
        }
    }

    // MARK: screens

    private func refreshScreens() {
        screens = Workspace.ranked(NSScreen.screens.map { s in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(num).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(num)"
            return WorkspaceScreen(id: uuid, name: s.localizedName, frame: s.frame, visibleFrame: s.visibleFrame, isBuiltin: CGDisplayIsBuiltin(num) != 0)
        })
    }

    var fingerprint: String { Workspace.fingerprint(screens) }

    private func screensChanged() {
        // macOS shuffles windows around while displays come and go; don't save those moves as the new layout.
        saveTask?.cancel()
        quietUntil = .now.addingTimeInterval(3)
        screenTask?.cancel()
        screenTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let before = self.fingerprint
            self.refreshScreens()
            if self.fingerprint != before { self.screenSetupArrived() }
        }
    }

    private func screenSetupArrived() {
        let fp = fingerprint
        if let saved = store.layout(for: fp) {
            suggestion = nil
            apply(saved)
        } else if screens.count > 1 && !store.isDismissed(fp) {
            suggestion = Workspace.recommended(screenCount: screens.count, claudeAvailable: claudeAvailable())
        } else {
            suggestion = nil
        }
    }

    func recommended() -> [WorkspaceLayout] {
        Workspace.recommended(screenCount: max(1, screens.count), claudeAvailable: claudeAvailable())
    }

    func dismissSuggestion() {
        store.dismiss(fingerprint)
        suggestion = nil
    }

    // MARK: windows

    func isDetached(_ content: WorkspaceContent) -> Bool {
        _ = revision
        return managed.contains { $0.content == content }
    }

    /// Opens (or brings forward) a window for a section or panel, optionally at a frame or centred on a screen.
    func open(_ content: WorkspaceContent, frame: CGRect? = nil, on screen: WorkspaceScreen? = nil) {
        if case .main(let s) = content {
            mainApp?.section = s
            if let frame { mainWindow?.setFrame(frame, display: true, animate: true) }
            return
        }
        if let i = managed.firstIndex(where: { $0.content == content }) {
            let w = managed[i].window
            if let f = frame ?? screen.map({ Workspace.frame(for: Self.comfortable, in: $0.visibleFrame) }) { w.setFrame(f, display: true, animate: true) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let wrap, let mainApp else { return }
        let state: AppState?
        let view: AnyView
        switch content {
        case .section(let s):
            let st = AppState()
            st.section = s
            st.selectedDocID = mainApp.selectedDocID
            st.selectedRoleID = mainApp.selectedRoleID
            state = st
            view = AnyView(DetachedSectionView())
        case .claude:
            state = nil
            mainApp.showClaude = true
            view = AnyView(ClaudePanel().padding(16).frame(minWidth: 380, minHeight: 360))
        case .video:
            state = nil
            view = AnyView(DetachedVideoView())
        case .main:
            return
        }
        let target = screen ?? screenOfKeyWindow() ?? screens.first
        let f = frame ?? target.map { Workspace.frame(for: Self.comfortable, in: $0.visibleFrame) } ?? CGRect(x: 200, y: 200, width: 1100, height: 760)
        let w = NSWindow(contentRect: f, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.title = "PrepBoard — \(content.title)"
        w.tabbingMode = .disallowed
        w.contentView = NSHostingView(rootView: wrap(view, state ?? mainApp))
        w.setFrame(f, display: true)
        managed.append(Managed(window: w, base: content, state: state))
        observeFrame(of: w)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.closed(n.object as? NSWindow) }
        })
        w.makeKeyAndOrderFront(nil)
        revision += 1
        scheduleSave()
    }

    /// A window that closes is no longer part of the layout; closing a panel's window also closes the panel.
    private func closed(_ window: NSWindow?) {
        guard let window, let i = managed.firstIndex(where: { $0.window === window }) else { return }
        let m = managed.remove(at: i)
        switch m.base {
        case .claude: mainApp?.showClaude = false
        case .video: mainApp?.sideVideo = nil
        default: break
        }
        revision += 1
        scheduleSave()
    }

    /// Window title follows the section a detached window is showing.
    func sectionChanged(in window: NSWindow?, to section: Section) {
        window?.title = "PrepBoard — \(section.rawValue)"
        scheduleSave()
    }

    func closeDetached() {
        for m in managed { m.window.close() }
    }

    /// Default size for a newly opened window: most of the screen, leaving a margin.
    private static let comfortable = UnitRect(x: 0.08, y: 0.08, w: 0.84, h: 0.84)

    private func screenOfKeyWindow() -> WorkspaceScreen? {
        guard let w = NSApp.keyWindow ?? mainWindow, !screens.isEmpty else { return nil }
        return screens[Workspace.screenIndex(for: w.frame, in: screens)]
    }

    // MARK: layouts

    func apply(_ layout: WorkspaceLayout) {
        refreshScreens()
        quietUntil = .now.addingTimeInterval(1.5)
        let available = claudeAvailable()
        let placed = Workspace.placements(for: layout, on: screens).map { p -> (content: WorkspaceContent, frame: CGRect) in
            p.content == .claude && !available ? (.section(.documents), p.frame) : p
        }.filter { $0.content != .video || mainApp?.sideVideo != nil }
        let wanted = placed.map(\.content)
        for m in managed where !wanted.contains(m.content) { m.window.close() }
        for p in placed { open(p.content, frame: p.frame) }
        mainWindow?.makeKeyAndOrderFront(nil)
        suggestion = nil
        scheduleSave(force: true)
    }

    /// Every PrepBoard window and what it shows.
    private func currentWindows() -> [(content: WorkspaceContent, frame: CGRect)] {
        var list: [(WorkspaceContent, CGRect)] = []
        if let w = mainWindow, w.isVisible, !w.isMiniaturized, let app = mainApp { list.append((.main(app.section), w.frame)) }
        for m in managed where m.window.isVisible && !m.window.isMiniaturized { list.append((m.content, m.window.frame)) }
        return list
    }

    func saveCurrent(named name: String) {
        refreshScreens()
        store.saveNamed(Workspace.capture(name: name, windows: currentWindows(), screens: screens))
        namedLayouts = store.named
    }

    func deleteNamed(_ name: String) {
        store.deleteNamed(name)
        namedLayouts = store.named
    }

    private func observeFrame(of window: NSWindow) {
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            })
        }
    }

    /// Remembers the arrangement for this screen setup a moment after windows stop moving.
    private func scheduleSave(force: Bool = false) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            // While a suggestion is waiting for an answer, the setup has no layout yet; saving now would hide the suggestion next time.
            guard !Task.isCancelled, force || (Date.now >= self.quietUntil && self.suggestion == nil), !self.screens.isEmpty else { return }
            let windows = self.currentWindows()
            guard !windows.isEmpty else { return }
            self.store.setLayout(Workspace.capture(name: "Last used", windows: windows, screens: self.screens), for: self.fingerprint)
        }
    }

    // MARK: moving windows

    /// Moves the front window to the next screen, keeping its relative position and size.
    func moveKeyWindowToNextScreen() {
        refreshScreens()
        guard screens.count > 1, let w = NSApp.keyWindow else { return }
        let from = Workspace.screenIndex(for: w.frame, in: screens)
        move(w, from: from, to: (from + 1) % screens.count)
    }

    func moveKeyWindow(to screen: WorkspaceScreen) {
        refreshScreens()
        guard let w = NSApp.keyWindow, let to = screens.firstIndex(where: { $0.id == screen.id }) else { return }
        move(w, from: Workspace.screenIndex(for: w.frame, in: screens), to: to)
    }

    /// Brings every PrepBoard window onto the screen the front window is on.
    func gatherOnKeyScreen() {
        refreshScreens()
        guard let key = NSApp.keyWindow ?? mainWindow else { return }
        let to = Workspace.screenIndex(for: key.frame, in: screens)
        for w in ([mainWindow].compactMap { $0 } + managed.map(\.window)) {
            let from = Workspace.screenIndex(for: w.frame, in: screens)
            if from != to { move(w, from: from, to: to) }
        }
    }

    private func move(_ w: NSWindow, from: Int, to: Int) {
        let r = Workspace.unitRect(for: w.frame, in: screens[from].visibleFrame)
        w.setFrame(Workspace.frame(for: r, in: screens[to].visibleFrame), display: true, animate: true)
    }
}

/// Gives a SwiftUI view the NSWindow it's in.
struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.onWindow = onWindow }
}
#endif
