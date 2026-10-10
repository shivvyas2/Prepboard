import SwiftData
import SwiftUI

// MARK: - Planner API types (supabase/functions/prep-chat)

struct PlannerMessage: Codable, Hashable { var role: String; var content: String }

private struct ChatRequest: Encodable {
    let mode = "chat"
    let messages: [PlannerMessage]
    let now: String
    let timezone: String
}

private struct DocRequest: Encodable {
    let mode = "doc"
    let role: Plan.Role
    let doc: Plan.Doc
    let now: String
    let timezone: String
}

private struct ChatResponse: Decodable { let reply: String?; let plan: Plan?; let error: String? }
private struct DocResponse: Decodable { let body: String?; let error: String? }

struct Plan: Codable {
    struct Role: Codable {
        let company, title, team, location, link, interview_at, interview_note, notes, stage: String
    }
    struct Doc: Codable { let key, title: String; let headings: [String] }
    struct Ref: Codable { let doc_key, heading: String }
    struct Session: Codable { let title, start, end, kind: String; let refs: [Ref] }
    let summary: String
    let role: Role
    let docs: [Doc]
    let sessions: [Session]
}

// MARK: - View

/// "Start something new": a chat that interviews the user and builds a role, a timeline and study guides.
struct NewPrepView: View {
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(Profile.self) private var profile
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [PlannerMessage] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var plan: Plan?
    @State private var claudeSession: String?
    @FocusState private var focused: Bool
    @Environment(ClaudeCode.self) private var claude
    private var usingClaudeCode: Bool { claude.isReady }

    private let suggestions = [
        "I have a Google L5 Android interview in 2 weeks",
        "Help me prep for a product design onsite on Friday",
        "I'll paste a job posting",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start something new").font(.system(size: 15, weight: .semibold))
                    Text("Chat to build a prep plan").font(.system(size: 12)).foregroundStyle(PB.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if messages.isEmpty { hero }
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, m in bubble(m) }
                        if thinking {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").font(.system(size: 13)).foregroundStyle(PB.muted) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let plan { planCard(plan) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 20).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("end") } }
                .onChange(of: thinking) { withAnimation { proxy.scrollTo("end") } }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(plan == nil ? "Describe the role, or paste the job posting…" : "Ask for changes, e.g. “less on Saturday, more mocks”",
                          text: $input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { send(input) }
                    .padding(.vertical, 8)
                Button { send(input) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(Circle().fill(PB.cobalt))
                }
                .buttonStyle(.plain)
                .disabled(thinking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(thinking ? 0.4 : 1)
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(PB.card))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(PB.line2))
            .shadow(color: Color(hex: 0x3C2D14).opacity(0.07), radius: 14, y: 8)
            .frame(maxWidth: 760)
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .background(PB.background)
        .onAppear { focused = true }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ProfileAvatar(size: 64)
            Text("What are you preparing for?").font(.system(size: 42, weight: .bold)).kerning(-1.6).multilineTextAlignment(.center)
            Text("Tell me the role, paste the job posting, and when the interview is. I'll build your timeline, sessions and study guides.")
                .foregroundStyle(PB.muted).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 6) {
                if usingClaudeCode { ClaudeMark().frame(width: 12, height: 12) }
                Text(usingClaudeCode ? "Using your Claude Code" : "Using your Anthropic key (Profile → AI)")
                    .font(.system(size: 12)).foregroundStyle(PB.muted)
            }
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { send(s) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            }
            .frame(maxWidth: 620)
        }
        .padding(.top, 50)
    }

    private func bubble(_ m: PlannerMessage) -> some View {
        let user = m.role == "user"
        return Text(m.content)
            .font(.system(size: 14)).lineSpacing(3)
            .foregroundStyle(user ? Color.white : PB.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: user ? 20 : 6, bottomTrailingRadius: user ? 6 : 20, topTrailingRadius: 20)
                .fill(user ? PB.cobalt : PB.card))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: user ? 20 : 6, bottomTrailingRadius: user ? 6 : 20, topTrailingRadius: 20)
                .strokeBorder(user ? Color.clear : PB.line))
            .frame(maxWidth: 620, alignment: user ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }

    private func planCard(_ p: Plan) -> some View {
        let work = p.sessions.filter { $0.kind != "break" }
        let hours = work.reduce(0.0) { acc, s in
            guard let a = DateCoding.date(s.start), let b = DateCoding.date(s.end) else { return acc }
            return acc + b.timeIntervalSince(a) / 3600
        }
        let days = Set(p.sessions.compactMap { DateCoding.date($0.start).map { Calendar.current.startOfDay(for: $0) } }).count
        return VStack(alignment: .leading, spacing: 14) {
            Text("Your plan").pbLabelStyle()
            Text("\(p.role.company) — \(p.role.title)").font(.system(size: 20, weight: .bold)).kerning(-0.4)
            if let at = DateCoding.date(p.role.interview_at) {
                Text("\(at.pbFull) · \(p.role.interview_note)").font(.system(size: 13)).foregroundStyle(PB.muted)
            }
            Text(p.summary).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                stat("Days", "\(days)"); stat("Sessions", "\(work.count)"); stat("Prep hours", String(format: "%.1f", hours))
            }
            Text("Study guides").pbLabelStyle()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(p.docs, id: \.key) { Text("• \($0.title)").font(.system(size: 13)).foregroundStyle(PB.ink2) }
            }
            HStack(spacing: 10) {
                Button("Create plan") { apply(p) }.buttonStyle(PillButtonStyle())
                Text("You can keep chatting to change it first.").font(.system(size: 12)).foregroundStyle(PB.muted)
            }
        }
        .pbCard(padding: 20, radius: 24)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).pbLabelStyle()
            Text(value).font(.system(size: 22, weight: .bold))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !thinking else { return }
        messages.append(.init(role: "user", content: t))
        input = ""
        thinking = true
        Task {
            defer { thinking = false }
            do {
                if usingClaudeCode {
                    let first = claudeSession == nil
                    let prompt = first ? PlannerPrompt.rules(now: DateCoding.string(.now), timezone: TimeZone.current.identifier) + "\n\nUser: \(t)" : t
                    let (text, session) = try await claude.runText(prompt, tools: "Read WebFetch", resume: claudeSession)
                    claudeSession = session ?? claudeSession
                    if let p = PlannerPrompt.plan(in: text) {
                        plan = p
                        messages.append(.init(role: "assistant", content: p.summary))
                    } else {
                        messages.append(.init(role: "assistant", content: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    return
                }
                let res: ChatResponse = try await cloud.invoke(ChatRequest(messages: messages, now: DateCoding.string(.now), timezone: TimeZone.current.identifier))
                if let err = res.error { throw NSError(domain: "Planner", code: 0, userInfo: [NSLocalizedDescriptionKey: err]) }
                messages.append(.init(role: "assistant", content: res.reply ?? "…"))
                if let p = res.plan { plan = p }
            } catch {
                messages.append(.init(role: "assistant", content: "Sorry — \(error.localizedDescription)"))
            }
        }
    }

    private func apply(_ p: Plan) {
        let role = Role(company: p.role.company, title: p.role.title, team: p.role.team, location: p.role.location,
                        link: p.role.link, stage: Stage(rawValue: p.role.stage) ?? .saved,
                        interviewAt: DateCoding.date(p.role.interview_at), interviewNote: p.role.interview_note, notes: p.role.notes)
        context.insert(role)
        var docIds: [String: String] = [:]
        var created: [(Doc, Plan.Doc)] = []
        for (i, d) in p.docs.enumerated() {
            let doc = Doc(roleId: role.id, title: d.title,
                          body: "_Writing this guide…_\n\n" + d.headings.map { "## \($0)\n" }.joined(separator: "\n"),
                          tags: ["guide"], order: i)
            context.insert(doc)
            docIds[d.key] = doc.id
            created.append((doc, d))
        }
        for s in p.sessions {
            guard let start = DateCoding.date(s.start), let end = DateCoding.date(s.end), end > start else { continue }
            context.insert(PrepTask(roleId: role.id, title: s.title, start: start, end: end,
                                    kind: SessionKind(rawValue: s.kind) ?? .study,
                                    refs: s.refs.compactMap { r in docIds[r.doc_key].map { DocRef(docId: $0, heading: r.heading) } }))
        }
        try? context.save()
        app.timelineRoleID = role.id
        app.section = .dashboard
        dismiss()

        // Write the study guides in parallel and fill them in as they arrive.
        let cloud = cloud
        let claude: ClaudeCode? = usingClaudeCode ? self.claude : nil
        Task { @MainActor in
            await withTaskGroup(of: (String, String?).self) { group in
                for (doc, d) in created {
                    let id = doc.id
                    group.addTask { @MainActor in
                        if let claude, let text = try? await claude.runText(PlannerPrompt.docPrompt(role: p.role, doc: d), tools: "Read WebFetch").text {
                            return (id, text)
                        }
                        let res: DocResponse? = try? await cloud.invoke(DocRequest(role: p.role, doc: d, now: DateCoding.string(.now),
                                                                                   timezone: TimeZone.current.identifier))
                        return (id, res?.body)
                    }
                }
                for await (id, body) in group {
                    if let body, let doc = created.first(where: { $0.0.id == id })?.0 {
                        doc.body = body
                        doc.updatedAt = .now
                        try? context.save()
                    }
                }
            }
        }
    }
}
