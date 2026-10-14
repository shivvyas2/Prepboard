import SwiftData
import SwiftUI

struct CardHeader<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let count {
                // A non-zero count is something waiting on you, so it gets the orange badge; anything else stays quiet.
                let pending = (Int(count) ?? 0) > 0
                Text(count).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1).fixedSize()
                    .foregroundStyle(pending ? PB.onSun : PB.muted)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 20)
                    .background(Capsule().fill(pending ? PB.sun : PB.surface))
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 12)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, count: String? = nil) { self.init(title: title, count: count) { EmptyView() } }
}

extension SessionKind {
    var color: Color {
        switch self {
        case .study: PB.cobalt
        case .practice: PB.ink
        case .mock: PB.red
        case .review: PB.green
        case .logistics: Color(hex: 0x86600C)
        case .break: Color(hex: 0xC3C7CF)
        }
    }
}

struct KindLabel: View {
    let kind: SessionKind
    var inverted = false
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).frame(width: 7, height: 7)
            Text(kind.label.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.9)
        }
        .foregroundStyle(inverted ? Color.white : kind.color)
    }
}

/// Profile → Time format. Observable, so every view showing a time redraws when it changes.
@MainActor
@Observable
final class TimePrefs {
    static let shared = TimePrefs()
    var use24h: Bool = UserDefaults.standard.object(forKey: "time.use24h") as? Bool ?? true {
        didSet { UserDefaults.standard.set(use24h, forKey: "time.use24h") }
    }
}

@MainActor
enum TimeFmt {
    /// "19:00" or "7:00 PM", per Profile → Time format.
    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        return TimePrefs.shared.use24h ? String(format: "%02d:%02d", h, m)
            : String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h < 12 ? "AM" : "PM")
    }
    /// Hour ruler label: "19:00" or "7 PM".
    static func hour(_ h: Int) -> String {
        TimePrefs.shared.use24h ? String(format: "%02d:00", h) : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 || h == 24 ? "AM" : "PM")"
    }
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h" + (minutes % 60 > 0 ? " \(minutes % 60)m" : "") : "\(minutes)m"
    }
    static func cleanHeading(_ h: String) -> String {
        var s = h.unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.value == 0x2B50 || $0.value == 0xFE0F) }
            .map(String.init).joined()
        if let i = s.firstIndex(of: "(") { s = String(s[..<i]) }
        if let i = s.firstIndex(of: ":") { s = String(s[..<i]) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Pill linking a session to a document section. Tapping opens the doc scrolled to that heading.
struct RefChip: View {
    let ref: DocRef
    let doc: Doc?
    var inverted = false
    @Environment(AppState.self) private var app

    var body: some View {
        if let doc {
            Button { app.openDoc(doc.id, heading: ref.heading) } label: {
                HStack(spacing: 8) {
                    Image(systemName: doc.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(inverted ? PB.onSun : PB.ink)
                        .background(Circle().fill(inverted ? PB.sun : PB.card))
                        .overlay(Circle().strokeBorder(inverted ? PB.sun : PB.line))
                    Text(ref.heading.isEmpty ? (doc.title.components(separatedBy: CharacterSet(charactersIn: ":—")).first ?? doc.title)
                                             : TimeFmt.cleanHeading(ref.heading))
                        .font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4).frame(minHeight: 32)
                .foregroundStyle(inverted ? Color.white : PB.ink)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(inverted ? Color.white.opacity(0.08) : PB.surface))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(inverted ? Color.white.opacity(0.18) : PB.line))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(doc.title + (ref.heading.isEmpty ? "" : " › " + ref.heading))
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// Compact agenda line: time · status dot · title. Tapping jumps to the session on the timeline.
struct AgendaRow: View {
    let task: PrepTask
    var now: Date = .now
    @Environment(AppState.self) private var app

    var body: some View {
        let st = task.status(at: now)
        Button { app.gotoSession(task) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(TimeFmt.hm(task.start)).font(.system(size: 12, design: .monospaced)).foregroundStyle(PB.muted)
                    .frame(width: 42, alignment: .leading)
                Circle()
                    .fill(st == .done ? PB.cobalt : st == .current ? PB.sun : Color.clear)
                    .overlay(Circle().strokeBorder(task.isBreak ? PB.line2 : st == .current || st == .done ? PB.cobalt : PB.ink,
                                                   style: StrokeStyle(lineWidth: 1.5, dash: task.isBreak ? [2] : [])))
                    .frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(task.title)
                    .font(.system(size: 14, weight: .medium))
                    .strikethrough(st == .done)
                    .foregroundStyle(st == .done || task.isBreak ? PB.muted : PB.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Checklist line like a to-do app: checkbox · title · time. Title jumps to the session on the timeline.
struct ChecklistRow: View {
    @Bindable var task: PrepTask
    var now: Date = .now
    @Environment(AppState.self) private var app

    var body: some View {
        let st = task.status(at: now)
        HStack(spacing: 16) {
            Toggle("Done", isOn: $task.done).toggleStyle(CheckboxToggleStyle())
            Button { app.gotoSession(task) } label: {
                Text(task.title)
                    .font(.system(size: 15, weight: .medium))
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? PB.muted : PB.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(TimeFmt.hm(task.start)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(st == .current ? PB.cobalt : PB.muted)
        }
        .padding(.vertical, 16).padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.line2).frame(height: 1) }
    }
}

/// "+ Add a task" line: adds a 1-hour study session at the next full hour (or 10:00 on another day).
struct AddTaskRow: View {
    let roleId: String
    let day: Date
    @Environment(\.modelContext) private var context
    @State private var title = ""

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(PB.ink2).frame(width: 22)
            TextField("Add a task", text: $title).textFieldStyle(.plain).font(.system(size: 15)).onSubmit(add)
        }
        .padding(.vertical, 16).padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.line2).frame(height: 1) }
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let cal = Calendar.current
        let start: Date
        if cal.isDateInToday(day) {
            let hour = min(22, cal.component(.hour, from: .now) + 1)
            start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        } else {
            start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
        }
        context.insert(PrepTask(roleId: roleId, title: t, start: start, end: start.addingTimeInterval(3600)))
        title = ""
    }
}

/// Create or edit a session: time block, type, role and linked documents.
struct SessionEditorSheet: View {
    @State var draft: SessionDraft
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @Query(sort: \Doc.order) private var docs: [Doc]
    @Query private var tasks: [PrepTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(draft.taskId == nil ? "New session" : "Edit session").font(.system(size: 18, weight: .semibold))
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
            }
            PBTextField(label: "What", text: $draft.title)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Day & start").pbLabelStyle()
                    DatePicker("", selection: $draft.start).labelsHidden()
                        .onChange(of: draft.start) { old, new in
                            draft.end = new.addingTimeInterval(draft.end.timeIntervalSince(old))
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("End").pbLabelStyle()
                    DatePicker("", selection: $draft.end, in: draft.start.addingTimeInterval(300)..., displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type").pbLabelStyle()
                    Picker("", selection: $draft.kind) {
                        ForEach(SessionKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(PB.ink)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Role").pbLabelStyle()
                    Picker("", selection: $draft.roleId) {
                        Text("None").tag("")
                        ForEach(roles) { Text("\($0.company) · \($0.title)").tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(PB.ink)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Linked documents").pbLabelStyle()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(DocOrder.arranged(docs)) { d in
                            let linked = draft.refs.contains { $0.docId == d.id }
                            Button {
                                if linked { draft.refs.removeAll { $0.docId == d.id } }
                                else { draft.refs.append(DocRef(docId: d.id)) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: linked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(linked ? PB.cobalt : PB.line2)
                                    Image(systemName: d.symbol).font(.system(size: 12)).foregroundStyle(PB.muted).frame(width: 18)
                                    Text(d.title.isEmpty ? "Untitled" : d.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
            }
            HStack {
                if let id = draft.taskId, let t = tasks.first(where: { $0.id == id }) {
                    Button("Delete") { context.delete(t); dismiss() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                Spacer()
                Button("Save session", action: save).buttonStyle(PillButtonStyle())
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .background(PB.card)
        .presentationDetents([.large])
    }

    private func save() {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        let end = max(draft.end, draft.start.addingTimeInterval(300))
        if let id = draft.taskId, let t = tasks.first(where: { $0.id == id }) {
            t.title = title; t.start = draft.start; t.end = end; t.kind = draft.kind; t.roleId = draft.roleId; t.refs = draft.refs
            app.gotoSession(t)
        } else {
            let t = PrepTask(roleId: draft.roleId, title: title, start: draft.start, end: end, kind: draft.kind, refs: draft.refs)
            context.insert(t)
            app.gotoSession(t)
        }
        dismiss()
    }
}

struct DocRow: View {
    let doc: Doc
    let roleName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: doc.symbol)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(PB.cobalt)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.title.isEmpty ? "Untitled" : doc.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("\(roleName) · \(doc.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Kanban of roles by stage. Drag a tile onto another column to change its stage.
/// The pipeline at a glance: one tile per active stage with its count and the companies in it. Tapping opens the full board.
struct PipelineSummary: View {
    let roles: [Role]
    @Environment(AppState.self) private var app
    private let stages: [Stage] = [.saved, .applied, .recruiter, .technical, .onsite, .offer]

    var body: some View {
        Button { app.showPipeline = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Pipeline", count: "\(roles.filter { $0.stage != .closed }.count)") {
                    HStack(spacing: 4) {
                        Text("Open board").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(PB.cobalt)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ForEach(stages) { stage in tile(stage).frame(minWidth: 104) } }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(stages) { stage in tile(stage) }
                    }
                }
            }
            .pbCard(padding: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pipeline. Open the full board")
    }

    private func tile(_ stage: Stage) -> some View {
        let items = roles.filter { $0.stage == stage }
        let hot = stage.isHot && !items.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            Text(stage.rawValue).font(.system(size: 12, weight: .semibold)).opacity(hot ? 0.9 : 0.7)
            Text("\(items.count)").font(.system(size: 24, weight: .bold)).monospacedDigit()
            Text(items.isEmpty ? " " : items.prefix(2).map(\.company).joined(separator: ", ") + (items.count > 2 ? " +\(items.count - 2)" : ""))
                .font(.system(size: 11)).lineLimit(1).opacity(hot ? 0.9 : 0.6)
        }
        .foregroundStyle(hot ? Color.white : PB.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(hot ? PB.cobalt : PB.surface))
    }
}

enum PipelineFilter: String, CaseIterable, Identifiable {
    case all = "All", new = "New this week", interviewing = "Upcoming interview", email = "Found in email"
    var id: String { rawValue }
    func includes(_ r: Role) -> Bool {
        switch self {
        case .all: true
        case .new: r.isNew
        case .interviewing: (r.interviewAt ?? .distantPast) > .now
        case .email: !r.source.isEmpty
        }
    }
}

extension Role {
    /// Added in the last week (by hand or by the Gmail/LinkedIn sync).
    var isNew: Bool { createdAt > Date.now.addingTimeInterval(-7 * 86400) }
}

/// The whole pipeline board on its own screen, with drag between stages and "+ Add" in each column.
struct PipelineScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Role.createdAt, order: .reverse) private var roles: [Role]
    @Query private var tasks: [PrepTask]
    @State private var query = ""
    @State private var filter: PipelineFilter = .all

    private var shown: [Role] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return roles.filter { r in
            filter.includes(r) && (q.isEmpty || r.company.lowercased().contains(q) || r.title.lowercased().contains(q))
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PB.s3) { searchField.frame(maxWidth: 320); chips; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: PB.s3) { searchField; chips }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(PB.muted)
            TextField("Filter by company or title", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PB.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Clear filter")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).frame(height: 40)
        .background(Capsule().fill(PB.card)).overlay(Capsule().strokeBorder(PB.line))
    }

    private var chips: some View {
        HStack(spacing: PB.s2) {
            ForEach(PipelineFilter.allCases) { f in
                let n = roles.filter(f.includes).count
                Button { filter = f } label: {
                    HStack(spacing: 6) {
                        Text(f.rawValue)
                        Text("\(n)").font(.system(size: 11, weight: .bold)).opacity(0.8)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 14).frame(height: 36)
                    .foregroundStyle(filter == f ? Color.white : PB.ink2)
                    .background(Capsule().fill(filter == f ? PB.cobalt : PB.card))
                    .overlay(Capsule().strokeBorder(filter == f ? PB.cobalt : PB.line))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == f ? [.isSelected] : [])
            }
        }
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s4) {
            HStack(spacing: 12) {
                CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pipeline").font(.system(size: 22, weight: .semibold))
                    Text("Drag roles between stages").font(.system(size: 12)).foregroundStyle(PB.muted)
                }
                Spacer()
                Button("+ New role") { app.newRole(context) }.buttonStyle(PillButtonStyle(compact: true))
            }
            filterBar
            ScrollView(.vertical) {
                PipelineView(roles: shown, tasks: tasks, showAdd: true)
            }
            .scrollIndicators(.hidden)
        }
        .padding(PB.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PB.background)
        #if os(macOS)
        .pbSheetFrame(minWidth: 640, idealWidth: 1400, minHeight: 440, idealHeight: 900)
        #endif
    }
}

struct PipelineView: View {
    let roles: [Role]
    let tasks: [PrepTask]
    var showAdd = false
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var targeted: Stage?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Stage.allCases) { stage in column(stage) }
            }
            .padding(4)
        }
    }

    private func column(_ stage: Stage) -> some View {
        let items = roles.filter { $0.stage == stage }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stage.rawValue).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%02d", items.count)).font(.pbMono).foregroundStyle(PB.muted)
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
            ForEach(items) { role in tile(role) }
            if showAdd {
                Button { app.newRole(context, stage: stage) } label: {
                    Text("+ Add").font(.system(size: 13)).foregroundStyle(PB.muted)
                        .frame(maxWidth: .infinity).padding(12)
                        .overlay(RoundedRectangle(cornerRadius: PB.rMD).strokeBorder(PB.line2, style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 210, alignment: .topLeading)
        .frame(minHeight: 160, alignment: .top)
        .background(RoundedRectangle(cornerRadius: PB.rLG).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: PB.rLG)
            .strokeBorder(targeted == stage ? PB.ink2 : PB.line, style: StrokeStyle(lineWidth: targeted == stage ? 2 : 1, dash: targeted == stage ? [5] : [])))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let role = roles.first(where: { $0.id == id }) else { return false }
            withAnimation(.snappy) { role.stage = stage }
            return true
        } isTargeted: { targeted = $0 ? stage : (targeted == stage ? nil : targeted) }
    }

    private func tile(_ role: Role) -> some View {
        let hot = role.stage.isHot
        return Button { app.openRole(role.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(role.company).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    if role.isNew {
                        Text("New").font(.system(size: 10, weight: .bold)).foregroundStyle(PB.onSun).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(PB.sun))
                    }
                }
                Text(role.title).font(.system(size: 13)).opacity(hot ? 0.85 : 0.65).fixedSize(horizontal: false, vertical: true)
                if let at = role.interviewAt { Text(at.pbShort).font(.pbMono).opacity(hot ? 0.85 : 0.65) }
                ProgressBar(value: tasks.progress(for: role.id), inverted: hot).padding(.top, 8)
            }
            .foregroundStyle(hot ? Color.white : PB.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PB.rMD).fill(hot ? PB.cobalt : PB.card))
            .overlay(RoundedRectangle(cornerRadius: PB.rMD).strokeBorder(hot ? PB.cobalt : PB.line))
            .contentShape(RoundedRectangle(cornerRadius: PB.rMD))
        }
        .buttonStyle(.plain)
        .draggable(role.id)
    }
}

extension Doc {
    /// A symbol for what the document is about, from its type, tags and title; replaces the old order number.
    var symbol: String {
        if isPDF { return tags.contains("resume") ? "person.text.rectangle" : "doc.richtext" }
        let t = title.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("start here", "read first", "overview of") { return "signpost.right.fill" }
        if has("recap", "retro", "debrief", "review of round", "post-mortem") { return "arrow.counterclockwise" }
        if has("game plan", "plan for", "strategy", "checklist", "day-of", "day of") { return "flag.fill" }
        if has("system design", "architecture", "design the", "scalab") { return "square.3.layers.3d" }
        if has("behavio", "star ", "stories", "leadership", "values") { return "person.2.fill" }
        if has("coderpad", "coding", "problem", "leetcode", "algorithm", "data structure", "drill", "practice") { return "chevron.left.forwardslash.chevron.right" }
        if has("question", "q&a", "faq", "ask them") { return "questionmark.bubble.fill" }
        if tags.contains("research") || has("research", "company", "team", "culture", "product") { return "building.2.fill" }
        if has("brief", "overview", "summary", "what to expect") { return "doc.text.magnifyingglass" }
        if has("swift", "ios", "avkit", "avfoundation", "concurrency", "memory", "os ", "operating system", "networking") { return "cpu" }
        if has("notes", "journal") { return "note.text" }
        return "book.closed.fill"
    }
}
