import SwiftData
import SwiftUI

struct RolesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @Query private var tasks: [PrepTask]

    var body: some View {
        if let id = app.selectedRoleID, let role = roles.first(where: { $0.id == id }) {
            RoleDetailView(role: role)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pipeline").pbLabelStyle()
                            Text("Roles").font(.pbDisplay).kerning(-1.4)
                        }
                        Spacer()
                        Button("+ New role") { app.newRole(context) }.buttonStyle(PillButtonStyle())
                    }
                    PipelineView(roles: roles, tasks: tasks, showAdd: true)
                        .pbCard(padding: 14, fill: PB.surface.opacity(0.7))
                    VStack(alignment: .leading, spacing: 0) {
                        CardHeader(title: "All roles")
                        if roles.isEmpty { Text("No roles yet.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(30) }
                        ForEach(roles) { r in
                            Button { app.openRole(r.id) } label: {
                                HStack(spacing: 12) {
                                    Text(String(r.company.prefix(2)))
                                        .font(.pbMono).frame(width: 36, height: 36)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(r.company) — \(r.title)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text([r.stage.rawValue, r.interviewAt?.pbFull].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 12)).foregroundStyle(PB.muted)
                                    }
                                    Spacer()
                                    ProgressBar(value: tasks.progress(for: r.id)).frame(width: 110)
                                }
                                .padding(8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .pbCard()
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct RoleDetailView: View {
    @Bindable var role: Role
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query private var allTasks: [PrepTask]
    @Query(sort: \Doc.order) private var allDocs: [Doc]
    @State private var confirmDelete = false

    var body: some View {
        let tasks = allTasks.filter { $0.roleId == role.id && !$0.isBreak }.sorted { $0.start < $1.start }
        let docs = allDocs.filter { $0.roleId == role.id }
        let progress = allTasks.progress(for: role.id)

        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    stageCard(progress)
                    if geo.size.width > 920 {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) { details; docsCard(docs) }
                            tasksCard(tasks).frame(width: 340)
                        }
                    } else {
                        details; tasksCard(tasks); docsCard(docs)
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .confirmationDialog("Delete this role and its tasks?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                allTasks.filter { $0.roleId == role.id }.forEach(context.delete)
                allDocs.filter { $0.roleId == role.id }.forEach { $0.roleId = "" }
                app.selectedRoleID = nil
                context.delete(role)
            }
        } message: { Text("Documents are kept as General.") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            CircleIconButton(systemImage: "arrow.left", label: "Back") { app.selectedRoleID = nil }
            VStack(alignment: .leading, spacing: 2) {
                Text(role.team.isEmpty ? "Role" : role.team).pbLabelStyle()
                Text(role.company).font(.pbDisplay).kerning(-1.4).lineLimit(1)
                Text(role.title).foregroundStyle(PB.muted)
            }
            Spacer(minLength: 0)
            Button("Delete") { confirmDelete = true }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            Button("+ Document") { app.newDoc(context, roleId: role.id) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            Button("Timeline") { app.timelineRoleID = role.id; app.section = .timeline }.buttonStyle(PillButtonStyle())
        }
    }

    private func stageCard(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Stage") {
                Text("\(Int(progress * 100))% prep").font(.pbMono).foregroundStyle(PB.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Stage.allCases) { s in
                        let current = s == role.stage, past = s.index < role.stage.index
                        Button { withAnimation(.snappy) { role.stage = s } } label: {
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", s.index + 1)).font(.pbMono).opacity(current ? 0.7 : 1)
                                    .foregroundStyle(current ? .white : past ? PB.cobalt : PB.muted)
                                Text(s.rawValue).font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 14).frame(height: 36)
                            .foregroundStyle(current ? Color.white : past ? PB.cobalt : PB.ink2)
                            .background(Capsule().fill(current ? PB.cobalt : past ? PB.cobaltSoft : PB.card))
                            .overlay(Capsule().strokeBorder(current ? PB.cobalt : past ? PB.cobaltSoft : PB.line2))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ProgressBar(value: progress).padding(.top, 16)
        }
        .pbCard()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Details") {
                if let url = URL(string: role.link), !role.link.isEmpty {
                    Button("Open posting") { openURL(url) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                PBTextField(label: "Company", text: $role.company)
                PBTextField(label: "Title", text: $role.title)
                PBTextField(label: "Team", text: $role.team)
                PBTextField(label: "Location", text: $role.location)
                PBTextField(label: "Comp range", text: $role.salary)
                PBTextField(label: "Role #", text: $role.roleNumber)
                PBTextField(label: "Posting URL", text: $role.link)
                PBTextField(label: "Interview format", text: $role.interviewNote)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Interview").pbLabelStyle()
                HStack {
                    if role.interviewAt != nil {
                        DatePicker("", selection: Binding(get: { role.interviewAt ?? .now }, set: { role.interviewAt = $0 }))
                            .labelsHidden()
                        Button("Clear") { role.interviewAt = nil }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    } else {
                        Button("Set interview date") {
                            role.interviewAt = Calendar.current.date(byAdding: .day, value: 7, to: .now)
                        }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    }
                }
            }
            .padding(.top, 12)
            PBTextField(label: "Notes", text: $role.notes, axis: .vertical).padding(.top, 12)
        }
        .pbCard()
    }

    private func tasksCard(_ tasks: [PrepTask]) -> some View {
        let byDay = Dictionary(grouping: tasks) { Calendar.current.startOfDay(for: $0.start) }
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Plan", count: "\(tasks.filter(\.done).count)/\(tasks.count)") {
                CircleIconButton(systemImage: "plus", size: 34, label: "New session") { app.newSession(roleId: role.id) }
            }
            if tasks.isEmpty { Text("No sessions yet.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(30) }
            ForEach(byDay.keys.sorted(), id: \.self) { day in
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).pbLabelStyle().padding(.top, 12).padding(.bottom, 2)
                ForEach(byDay[day] ?? []) { ChecklistRow(task: $0) }
            }
            Button("Open timeline") { app.timelineRoleID = role.id; app.section = .timeline }
                .buttonStyle(PillButtonStyle(filled: false, compact: true)).padding(.top, 12)
        }
        .pbCard()
    }

    private func docsCard(_ docs: [Doc]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Documents", count: "\(docs.count)") {
                CircleIconButton(systemImage: "plus", size: 34, label: "New document") { app.newDoc(context, roleId: role.id) }
            }
            if docs.isEmpty { Text("No documents for this role yet.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(30) }
            ForEach(docs) { d in DocRow(doc: d, roleName: role.company) { app.openDoc(d.id) } }
        }
        .pbCard()
    }
}
