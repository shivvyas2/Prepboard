import SwiftData
import SwiftUI

struct CardHeader<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let count { Text(count).font(.pbMono).foregroundStyle(PB.muted) }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 10)
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
        case .mock: Color(hex: 0xC2410C)
        case .review: Color(hex: 0x2F7D4F)
        case .logistics: Color(hex: 0x8A6D1F)
        case .break: Color(hex: 0xBCB4A6)
        }
    }
}

struct KindLabel: View {
    let kind: SessionKind
    var inverted = false
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).frame(width: 7, height: 7)
            Text(kind.label.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.9)
        }
        .foregroundStyle(inverted ? Color.white : kind.color)
    }
}

enum TimeFmt {
    static func hm(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
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
                    Text(String(format: "%02d", min(doc.order, 99)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(inverted ? PB.onSun : PB.ink)
                        .background(Circle().fill(inverted ? PB.sun : PB.card))
                        .overlay(Circle().strokeBorder(inverted ? PB.sun : PB.line))
                    Text(ref.heading.isEmpty ? (doc.title.components(separatedBy: CharacterSet(charactersIn: ":—")).first ?? doc.title)
                                             : TimeFmt.cleanHeading(ref.heading))
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .padding(.leading, 4).padding(.trailing, 12).frame(height: 30)
                .foregroundStyle(inverted ? Color.white : PB.ink)
                .background(Capsule().fill(inverted ? Color.white.opacity(0.08) : PB.surface))
                .overlay(Capsule().strokeBorder(inverted ? Color.white.opacity(0.18) : PB.line))
                .contentShape(Capsule())
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
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
            .padding(.vertical, 7)
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
        .padding(.vertical, 16).padding(.horizontal, 2)
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
        HStack(spacing: 14) {
            Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(PB.ink2).frame(width: 22)
            TextField("Add a task", text: $title).textFieldStyle(.plain).font(.system(size: 15)).onSubmit(add)
        }
        .padding(.vertical, 14).padding(.horizontal, 2)
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
        VStack(alignment: .leading, spacing: 14) {
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
                        ForEach(roles) { Text("\($0.company) — \($0.title)").tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(PB.ink)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Linked documents").pbLabelStyle()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(docs) { d in
                            let linked = draft.refs.contains { $0.docId == d.id }
                            Button {
                                if linked { draft.refs.removeAll { $0.docId == d.id } }
                                else { draft.refs.append(DocRef(docId: d.id)) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: linked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(linked ? PB.cobalt : PB.line2)
                                    Text(String(format: "%02d", min(d.order, 99))).font(.pbMono).foregroundStyle(PB.muted)
                                    Text(d.title.isEmpty ? "Untitled" : d.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
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
        .padding(22)
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
                Text(doc.tags.contains("research") ? "Rs" : String(format: "%02d", min(doc.order, 99)))
                    .font(.pbMono).foregroundStyle(PB.ink2)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                VStack(alignment: .leading, spacing: 2) {
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
            .padding(2)
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
            .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 4)
            ForEach(items) { role in tile(role) }
            if showAdd {
                Button { app.newRole(context, stage: stage) } label: {
                    Text("+ Add").font(.system(size: 13)).foregroundStyle(PB.muted)
                        .frame(maxWidth: .infinity).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: PB.rMD).strokeBorder(PB.line2, style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
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
                Text(role.company).font(.system(size: 14, weight: .semibold))
                Text(role.title).font(.system(size: 13)).opacity(0.65).fixedSize(horizontal: false, vertical: true)
                if let at = role.interviewAt { Text(at.pbShort).font(.pbMono).opacity(0.65) }
                ProgressBar(value: tasks.progress(for: role.id), inverted: hot).padding(.top, 6)
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
