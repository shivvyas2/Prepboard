import Foundation
import Observation
import SwiftData

enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Home", timeline = "Timeline", roles = "Roles", hunt = "Hunt", documents = "Documents", practice = "Coding", essentials = "Essentials", scores = "Scores", browse = "Browse", search = "Search"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .timeline: "list.bullet.below.rectangle"
        case .roles: "briefcase"
        case .hunt: "paperplane"
        case .documents: "doc.text"
        case .practice: "chevron.left.forwardslash.chevron.right"
        case .essentials: "person.3"
        case .scores: "trophy"
        case .browse: "safari"
        case .search: "magnifyingglass"
        }
    }
}

@MainActor
@Observable
final class AppState {
    /// `-PrepboardSection timeline` opens a specific section at launch (handy for testing).
    var section: Section = UserDefaults.standard.string(forKey: "PrepboardSection").flatMap { k in Section.allCases.first { "\($0)" == k } } ?? .dashboard
    var selectedRoleID: String?
    /// `-PrepboardOpenDoc <id>` opens a document at launch (testing).
    var selectedDocID: String? = UserDefaults.standard.string(forKey: "PrepboardOpenDoc")
    var docEditing = false
    var docFilter: String = "all"            // "all", "none", or a role id
    var searchText = ""
    var timelineRoleID: String?
    var kindFilter: SessionKind?
    var showBreaks = true
    var scrollTarget: String?             // timeline: session id, "now", "interview", or "day-yyyy-MM-dd"
    var docScrollHeading: String?         // documents: heading to scroll to after opening
    var sessionEditor: SessionDraft?
    var showClaude = false
    var claudeTerminal = false          // Claude panel: chat (false) or the real Claude Code terminal (true)
    var showProfile = false
    var showNewPrep = false
    var showPipeline = false             // the full-screen pipeline board
    var newPrepRoleID: String?           // planner builds the plan for this existing role (e.g. one found by job sync)
    var quizSessionID: String?
    var playingVideo: Video?
    var sideVideo: Video?               // docked player, so a video keeps playing beside documents and PDFs
    /// `-PrepboardOpenURL https://…` opens a page in the in-app browser at launch (testing).
    var browserURL: URL? = UserDefaults.standard.string(forKey: "PrepboardOpenURL").flatMap(URL.init(string:))

    func openInBrowser(_ url: URL) { browserURL = url; section = .browse }
    var reviewQuizID: String?
    var showImporter = false
    var showExporter = false
    var exportFile: JSONFile?
    var message: String?

    func openRole(_ id: String) { showPipeline = false; selectedRoleID = id; section = .roles }
    func planForRole(_ id: String) { newPrepRoleID = id; showNewPrep = true }
    func openDoc(_ id: String, edit: Bool = false, heading: String? = nil) {
        selectedDocID = id; docEditing = edit; docFilter = "all"
        docScrollHeading = (heading?.isEmpty ?? true) ? nil : heading
        section = .documents
    }

    func gotoSession(_ task: PrepTask) {
        if task.isBreak { showBreaks = true }
        if let k = kindFilter, k != task.kind { kindFilter = nil }
        timelineRoleID = task.roleId
        section = .timeline
        scrollTarget = task.id
    }

    func newSession(roleId: String?, day: Date = .now) {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
        sessionEditor = SessionDraft(taskId: nil, roleId: roleId ?? "", title: "", start: start,
                                     end: start.addingTimeInterval(3600), kind: .study, refs: [])
    }

    func editSession(_ t: PrepTask) {
        sessionEditor = SessionDraft(taskId: t.id, roleId: t.roleId, title: t.title, start: t.start, end: t.end, kind: t.kind, refs: t.refs)
    }

    @discardableResult
    func newRole(_ context: ModelContext, stage: Stage = .saved) -> Role {
        let r = Role(stage: stage)
        context.insert(r)
        openRole(r.id)
        return r
    }

    @discardableResult
    func newDoc(_ context: ModelContext, roleId: String = "", title: String = "", body: String = "", tags: [String] = []) -> Doc {
        let d = Doc(roleId: roleId, title: title, body: body, tags: tags)
        d.order = DocOrder.next(d.kind, roleId: roleId, context: context)
        context.insert(d)
        openDoc(d.id, edit: true)
        return d
    }

    func saveResearch(_ query: String, roleId: String, context: ModelContext) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        newDoc(context, roleId: roleId, title: "Research: \(query)",
               body: "## Question\n\(query)\n\n## Findings\n- \n\n## Sources\n- https://developer.apple.com/search/?q=\(q)\n- https://www.google.com/search?q=\(q)\n",
               tags: ["research"])
    }

    func prepareExport(_ context: ModelContext) {
        do { exportFile = JSONFile(data: try Transfer.exportData(context)); showExporter = true }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }
}

struct SessionDraft: Identifiable {
    var taskId: String?
    var id: String { taskId ?? "new" }
    var roleId: String
    var title: String
    var start: Date
    var end: Date
    var kind: SessionKind
    var refs: [DocRef]
}
