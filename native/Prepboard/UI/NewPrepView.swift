import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    let context: String
    let now: String
    let timezone: String
}

private struct FormatRequest: Encodable {
    let mode = "format"
    let kind: String
    let text: String
}

/// A PDF the user attached in the planner (résumé, job posting…). Kept as the original PDF and as a formatted doc.
struct PlannerAttachment: Identifiable {
    enum Kind: String, CaseIterable { case resume = "Résumé", posting = "Job posting", other = "Other document" }
    let id = UUID()
    let name: String
    var kind: Kind
    let data: Data
    let text: String
    var sent = false

    var tag: String { kind == .resume ? "resume" : kind == .posting ? "job-posting" : "attachment" }
    var promptBlock: String {
        "<attachment kind=\"\(kind.rawValue)\" name=\"\(name)\">\n\(text.isEmpty ? "(no selectable text in this PDF)" : String(text.prefix(30_000)))\n</attachment>"
    }

    init?(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        name = url.lastPathComponent
        self.data = data
        text = PDFDocument(data: data)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let n = name.lowercased()
        kind = n.contains("resume") || n.contains("résumé") || n.contains("cv") ? .resume
            : n.contains("job") || n.contains("posting") || n.contains("description") || n.contains("jd") ? .posting : .resume
    }
}

private let attachmentMarker = "\n\n<attachment "

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
    @State private var attachments: [PlannerAttachment] = []
    @State private var importing = false
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

            if !attachments.isEmpty { attachmentChips.frame(maxWidth: 760).padding(.horizontal, 16).padding(.bottom, 8) }

            HStack(alignment: .bottom, spacing: 10) {
                Button { importing = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 16, weight: .medium)).foregroundStyle(PB.ink2)
                        .frame(width: 36, height: 42)
                }
                .buttonStyle(.plain)
                .help("Attach your résumé or the job posting (PDF)")
                .accessibilityLabel("Attach a PDF")
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
                .disabled(thinking || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.contains { !$0.sent }))
                .opacity(thinking ? 0.4 : 1)
            }
            .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(PB.card))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(PB.line2))
            .shadow(color: Color(hex: 0x3C2D14).opacity(0.07), radius: 14, y: 8)
            .frame(maxWidth: 760)
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .background(PB.background)
        .onAppear { focused = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            attachments += urls.compactMap(PlannerAttachment.init(url:))
        }
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

    private var attachmentChips: some View {
        FlowLayout(spacing: 8) {
            ForEach($attachments) { $a in
                HStack(spacing: 6) {
                    Image(systemName: "doc.richtext").foregroundStyle(PB.cobalt)
                    Text(a.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Menu(a.kind.rawValue) {
                        ForEach(PlannerAttachment.Kind.allCases, id: \.self) { k in Button(k.rawValue) { a.kind = k } }
                    }
                    .menuStyle(.button).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize()
                    if !a.sent {
                        Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(PB.muted).accessibilityLabel("Remove \(a.name)")
                    }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Capsule().fill(PB.card)).overlay(Capsule().strokeBorder(PB.line))
            }
        }
    }

    private func bubble(_ m: PlannerMessage) -> some View {
        let user = m.role == "user"
        let parts = m.content.components(separatedBy: attachmentMarker)
        let names = parts.dropFirst().compactMap { p -> String? in
            guard let r = p.range(of: "name=\""), let e = p[r.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(p[r.upperBound..<e])
        }
        let shown = parts[0] + names.map { "\n📎 \($0)" }.joined()
        return Text(shown.trimmingCharacters(in: .whitespacesAndNewlines))
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
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fresh = attachments.indices.filter { !attachments[$0].sent }
        guard !t.isEmpty || !fresh.isEmpty, !thinking else { return }
        if t.isEmpty { t = "Here's my " + fresh.map { attachments[$0].kind.rawValue.lowercased() }.joined(separator: " and ") + "." }
        for i in fresh { t += "\n\n" + attachments[i].promptBlock; attachments[i].sent = true }
        messages.append(.init(role: "user", content: t))
        input = ""
        thinking = true
        Task {
            defer { thinking = false }
            do {
                if usingClaudeCode {
                    let first = claudeSession == nil
                    let prompt = first ? PlannerPrompt.rules(now: DateCoding.string(.now), timezone: TimeZone.current.identifier) + "\n\nUser: \(t)" : t
                    let (text, session) = try await claude.runText(prompt, tools: "Read WebSearch WebFetch", resume: claudeSession)
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
        let files = attachments
        let docContext = files.map(\.promptBlock).joined(separator: "\n")
        saveAttachments(files, roleId: role.id, claude: claude)
        Task { @MainActor in
            await withTaskGroup(of: (String, String?).self) { group in
                for (doc, d) in created {
                    let id = doc.id
                    group.addTask { @MainActor in
                        if let claude, let text = try? await claude.runText(PlannerPrompt.docPrompt(role: p.role, doc: d, context: docContext), tools: "Read WebSearch WebFetch").text {
                            return (id, text)
                        }
                        let res: DocResponse? = try? await cloud.invoke(DocRequest(role: p.role, doc: d, context: docContext, now: DateCoding.string(.now),
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

    /// Keeps each attached PDF twice: the original (synced to storage, openable any time) and a formatted
    /// Markdown copy in PrepBoard's style that links back to it with an "original:<id>" tag.
    private func saveAttachments(_ files: [PlannerAttachment], roleId: String, claude: ClaudeCode?) {
        let cloud = cloud
        for (i, f) in files.enumerated() {
            let formatted = Doc(roleId: roleId, title: f.kind == .other ? (f.name as NSString).deletingPathExtension : f.kind.rawValue,
                                body: "_Formatting \(f.name)…_", tags: [f.tag], order: 900 + i)
            context.insert(formatted)
            try? context.save()
            Task { @MainActor in
                if let pdf = try? await cloud.importPDF(f.data, fileName: f.name, roleId: roleId, context: context) {
                    pdf.tags = ["pdf", f.tag, "original"]
                    formatted.tags.append("original:\(pdf.id)")
                }
                var body: String?
                if !f.text.isEmpty {
                    if let claude {
                        body = try? await claude.runText(PlannerPrompt.formatPrompt(kind: f.kind.rawValue, text: f.text), tools: "Read").text
                    }
                    if body?.isEmpty ?? true {
                        let res: DocResponse? = try? await cloud.invoke(FormatRequest(kind: f.kind.rawValue, text: f.text))
                        body = res?.body
                    }
                }
                formatted.body = (body?.isEmpty == false ? body! : (f.text.isEmpty ? "This PDF has no selectable text. Open the original to read it." : f.text))
                formatted.updatedAt = .now
                try? context.save()
            }
        }
    }
}
