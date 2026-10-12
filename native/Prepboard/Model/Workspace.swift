#if os(macOS)
import Foundation

/// Multi-screen workspaces: which section or panel goes on which screen, and where.
/// Pure geometry and storage; `WorkspaceManager` does the AppKit window work.

/// One connected display, in AppKit coordinates (origin at the bottom-left of the main screen).
struct WorkspaceScreen: Equatable {
    let id: String          // the display's UUID, stable across reconnects and rearranging
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect  // without the menu bar and Dock
    let isBuiltin: Bool
}

/// What a window shows.
enum WorkspaceContent: Codable, Hashable {
    case main(Section)      // the main PrepBoard window, on this section
    case section(Section)   // an extra window showing one section
    case claude             // the Claude panel on its own
    case video              // the docked video player on its own

    var title: String {
        switch self {
        case .main(let s), .section(let s): s.rawValue
        case .claude: "Claude"
        case .video: "Video"
        }
    }
}

/// A rectangle in 0–1 units of a screen's visible frame, measured from the top-left like you'd describe it.
struct UnitRect: Codable, Equatable {
    var x, y, w, h: Double
    static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)
    static let left = UnitRect(x: 0, y: 0, w: 0.5, h: 1), right = UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
    static let top = UnitRect(x: 0, y: 0, w: 1, h: 0.6), bottom = UnitRect(x: 0, y: 0.6, w: 1, h: 0.4)
}

struct WorkspaceSlot: Codable, Equatable {
    var content: WorkspaceContent
    var screen: Int         // rank: 0 is the largest screen
    var rect: UnitRect
}

struct WorkspaceLayout: Codable, Equatable, Identifiable {
    var name: String
    var slots: [WorkspaceSlot]
    var id: String { name }
}

extension Section: Codable {}

enum Workspace {
    /// Largest screen first; an external display beats the built-in one at the same size.
    static func ranked(_ screens: [WorkspaceScreen]) -> [WorkspaceScreen] {
        screens.sorted { a, b in
            let aa = a.frame.width * a.frame.height, ba = b.frame.width * b.frame.height
            if aa != ba { return aa > ba }
            if a.isBuiltin != b.isBuiltin { return !a.isBuiltin }
            return a.id < b.id
        }
    }

    /// Identifies a screen setup (which displays are connected), independent of order.
    static func fingerprint(_ screens: [WorkspaceScreen]) -> String {
        screens.map(\.id).sorted().joined(separator: "|")
    }

    static func frame(for r: UnitRect, in visible: CGRect) -> CGRect {
        let w = visible.width * r.w, h = visible.height * r.h
        return CGRect(x: visible.minX + visible.width * r.x, y: visible.maxY - visible.height * r.y - h, width: w, height: h)
    }

    static func unitRect(for frame: CGRect, in visible: CGRect) -> UnitRect {
        let f = frame.intersection(visible).isNull ? visible : frame.intersection(visible)
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        return UnitRect(x: round3((f.minX - visible.minX) / visible.width), y: round3((visible.maxY - f.maxY) / visible.height),
                        w: round3(f.width / visible.width), h: round3(f.height / visible.height))
    }

    /// The ranked screen a window is mostly on.
    static func screenIndex(for frame: CGRect, in ranked: [WorkspaceScreen]) -> Int {
        let areas = ranked.map { s -> CGFloat in
            let i = s.frame.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else {
            let mid = CGPoint(x: frame.midX, y: frame.midY)
            return ranked.indices.min { hypot(ranked[$0].frame.midX - mid.x, ranked[$0].frame.midY - mid.y) < hypot(ranked[$1].frame.midX - mid.x, ranked[$1].frame.midY - mid.y) } ?? 0
        }
        return best
    }

    /// Where each slot's window goes on these (ranked) screens. A slot for a screen that isn't there goes on the last one.
    static func placements(for layout: WorkspaceLayout, on ranked: [WorkspaceScreen]) -> [(content: WorkspaceContent, frame: CGRect)] {
        guard !ranked.isEmpty else { return [] }
        return layout.slots.map { s in (s.content, frame(for: s.rect, in: ranked[min(s.screen, ranked.count - 1)].visibleFrame)) }
    }

    /// The current arrangement of windows as a layout.
    static func capture(name: String, windows: [(content: WorkspaceContent, frame: CGRect)], screens ranked: [WorkspaceScreen]) -> WorkspaceLayout {
        WorkspaceLayout(name: name, slots: windows.map { w in
            let i = screenIndex(for: w.frame, in: ranked)
            return WorkspaceSlot(content: w.content, screen: i, rect: unitRect(for: w.frame, in: ranked[i].visibleFrame))
        })
    }

    /// Ready-made layouts for this many screens, best first. Without Claude Code, its slots show Documents instead.
    static func recommended(screenCount: Int, claudeAvailable: Bool) -> [WorkspaceLayout] {
        let focus = WorkspaceLayout(name: "Focus", slots: [.init(content: .main(.practice), screen: 0, rect: .full)])
        let codeRef = WorkspaceLayout(name: "Code + Reference", slots: [
            .init(content: .main(.practice), screen: 0, rect: .full),
            .init(content: .section(.browse), screen: 1, rect: .top),
            .init(content: .claude, screen: 1, rect: .bottom),
        ])
        let study = WorkspaceLayout(name: "Study", slots: [
            .init(content: .main(.documents), screen: 0, rect: .full),
            .init(content: .section(.timeline), screen: 1, rect: .left),
            .init(content: .claude, screen: 1, rect: .right),
        ])
        let command = WorkspaceLayout(name: "Command Center", slots: [
            .init(content: .main(.practice), screen: 0, rect: .full),
            .init(content: .section(.browse), screen: 1, rect: .full),
            .init(content: .section(.timeline), screen: 2, rect: .top),
            .init(content: .claude, screen: 2, rect: .bottom),
        ])
        let list: [WorkspaceLayout] = switch screenCount {
        case ...1: [focus]
        case 2: [codeRef, study, focus]
        default: [command, codeRef, study, focus]
        }
        guard !claudeAvailable else { return list }
        return list.map { l in
            var l = l
            l.slots = l.slots.map { s in var s = s; if s.content == .claude { s.content = .section(.documents) }; return s }
            return l
        }
    }
}

/// Saved workspaces: the last arrangement for each screen setup, layouts you named, and setups you said "Not now" to.
final class WorkspaceStore {
    private let defaults: UserDefaults
    private enum Key { static let byFingerprint = "workspace.byFingerprint", named = "workspace.named", dismissed = "workspace.dismissed" }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let d = try? JSONEncoder().encode(value) { defaults.set(d, forKey: key) }
    }

    func layout(for fingerprint: String) -> WorkspaceLayout? { load(Key.byFingerprint, as: [String: WorkspaceLayout].self)?[fingerprint] }
    func setLayout(_ layout: WorkspaceLayout, for fingerprint: String) {
        var all = load(Key.byFingerprint, as: [String: WorkspaceLayout].self) ?? [:]
        all[fingerprint] = layout
        save(all, Key.byFingerprint)
    }

    var named: [WorkspaceLayout] { load(Key.named, as: [WorkspaceLayout].self) ?? [] }
    func saveNamed(_ layout: WorkspaceLayout) {
        var all = named.filter { $0.name != layout.name }
        all.append(layout)
        save(all, Key.named)
    }
    func deleteNamed(_ name: String) { save(named.filter { $0.name != name }, Key.named) }

    func isDismissed(_ fingerprint: String) -> Bool { (defaults.stringArray(forKey: Key.dismissed) ?? []).contains(fingerprint) }
    func dismiss(_ fingerprint: String) {
        defaults.set(Array(Set((defaults.stringArray(forKey: Key.dismissed) ?? []) + [fingerprint])), forKey: Key.dismissed)
    }
}
#endif
