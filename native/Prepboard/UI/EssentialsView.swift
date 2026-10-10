import SwiftData
import SwiftUI

/// Leadership, behavioral and the other essentials every interview needs, per role. Each topic is a normal
/// document (tag "essentials:<key>"), so it syncs and opens in Documents. Empty topics can be generated with
/// Claude Code (or the Anthropic key), under strict format rules so they match the rest of the app.
struct EssentialsView: View {
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(ClaudeCode.self) private var claude
    @Environment(\.modelContext) private var context
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @Query private var docs: [Doc]
    @State private var generating: Set<String> = []
    @State private var error: String?

    struct Topic: Identifiable {
        let id: String
        let title: String
        let blurb: String
        let icon: String
        let headings: [String]
    }

    static let topics: [Topic] = [
        Topic(id: "intro", title: "Tell me about yourself", blurb: "Your pitch in 30 seconds and 2 minutes, tailored to this role.",
              icon: "person.wave.2", headings: ["30-second version", "2-minute version", "Tailoring to this role", "Delivery tips"]),
        Topic(id: "leadership", title: "Leadership & behavioral stories", blurb: "A STAR story bank from your résumé: ownership, influence, mentoring.",
              icon: "person.3", headings: ["Story bank overview", "Leading without authority", "Ownership and delivering results",
                                           "Mentoring and raising the bar", "Handling ambiguity", "Practice prompts"]),
        Topic(id: "conflict", title: "Conflict, failure & feedback", blurb: "The hard questions, answered honestly and with what you learned.",
              icon: "arrow.triangle.branch", headings: ["Disagreement with a teammate", "Failure and what changed", "Receiving hard feedback",
                                                        "Prioritizing under pressure", "Practice prompts"]),
        Topic(id: "why", title: "Why this company & role", blurb: "Specific reasons, what you bring, and how you match their values.",
              icon: "building.2", headings: ["Why this company", "Why this team and role", "What you bring", "Their values and how you show them"]),
        Topic(id: "questions", title: "Questions to ask", blurb: "Sharp questions for the hiring manager, engineers and recruiter.",
              icon: "questionmark.bubble", headings: ["For the hiring manager", "For engineers on the team", "For the recruiter", "Questions to avoid"]),
        Topic(id: "logistics", title: "Interview day checklist", blurb: "Format, setup, tech check and what to do the day before and of.",
              icon: "checklist", headings: ["Schedule and format", "Setup and tech check", "Day-before checklist", "Day-of checklist"]),
        Topic(id: "salary", title: "Compensation & negotiation", blurb: "Market range, your numbers and what to say when asked.",
              icon: "dollarsign.circle", headings: ["Market range", "Your numbers", "Answering compensation questions", "Negotiation script"]),
    ]

    private var role: Role? {
        roles.first { $0.id == app.timelineRoleID }
            ?? roles.filter { ($0.interviewAt ?? .distantPast) > .now }.min { $0.interviewAt! < $1.interviewAt! }
            ?? roles.last
    }

    private func doc(_ t: Topic, role: Role?) -> Doc? {
        docs.first { $0.tags.contains("essentials:\(t.id)") && $0.roleId == (role?.id ?? "") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(PB.red)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.red.opacity(0.08)))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(Self.topics) { t in card(t) }
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        let empty = Self.topics.filter { (doc($0, role: role)?.body ?? "").isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Essentials").pbLabelStyle()
            Text("Leadership & essential preparation").font(.pbDisplay).kerning(-1.4).lineLimit(2).minimumScaleFactor(0.7)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { rolePicker; aiNote; Spacer(minLength: 0); generateAll(empty) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { rolePicker; Spacer(minLength: 0); generateAll(empty) }
                    aiNote
                }
            }
        }
    }

    private var rolePicker: some View {
                Menu {
                    Button("General (no role)") { app.timelineRoleID = nil }
                    ForEach(roles) { r in Button("\(r.company) — \(r.title)") { app.timelineRoleID = r.id } }
                } label: {
                    HStack(spacing: 8) {
                        Text(role.map { "\($0.company) — \($0.title)" } ?? "General").font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .padding(.horizontal, 16).frame(height: 36).overlay(Capsule().strokeBorder(PB.line2))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize(horizontal: false, vertical: true)
    }

    private var aiNote: some View {
        Text(claude.isReady ? "Generates with your Claude Code" : "Generates with your Anthropic key")
            .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize()
    }

    @ViewBuilder
    private func generateAll(_ empty: [Topic]) -> some View {
        if !empty.isEmpty {
            Button("Generate all (\(empty.count))") { for t in empty { generate(t) } }
                .buttonStyle(PillButtonStyle(compact: true)).fixedSize().disabled(!generating.isEmpty)
        }
    }

    private func card(_ t: Topic) -> some View {
        let d = doc(t, role: role)
        let words = d?.body.split(whereSeparator: \.isWhitespace).count ?? 0
        let busy = generating.contains(t.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: t.icon).font(.system(size: 16)).foregroundStyle(PB.cobalt)
                    .frame(width: 36, height: 36).background(Circle().fill(PB.cobaltSoft))
                Text(t.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
            Text(t.blurb).font(.system(size: 13)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Writing…").font(.system(size: 12)).foregroundStyle(PB.muted)
                } else if let d, words > 0 {
                    Text("\(words) words · \(d.updatedAt.formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundStyle(PB.muted)
                    Spacer(minLength: 0)
                    Button("Regenerate") { generate(t) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    Button("Open") { app.openDoc(d.id) }.buttonStyle(PillButtonStyle(compact: true))
                } else {
                    Text("Empty").font(.system(size: 12, weight: .semibold)).foregroundStyle(PB.muted)
                    Spacer(minLength: 0)
                    Button("Write myself") { app.openDoc(ensureDoc(t).id, edit: true) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    Button("Generate") { generate(t) }.buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
        .frame(minHeight: 170, alignment: .top)
        .pbCard(padding: 16, radius: PB.rLG)
    }

    @discardableResult
    private func ensureDoc(_ t: Topic) -> Doc {
        if let d = doc(t, role: role) { return d }
        let d = Doc(roleId: role?.id ?? "", title: t.title, body: "", tags: ["essentials", "essentials:\(t.id)"],
                    order: 100 + (Self.topics.firstIndex { $0.id == t.id } ?? 0))
        context.insert(d)
        try? context.save()
        return d
    }

    /// Strict format rules so generated pages match the app: fixed "## " sections, no emoji, no tables, no filler.
    static let formatRules = """
    PrepBoard format rules (follow exactly):
    - Start with one short overview paragraph, then use exactly the given "## " section headings, verbatim and in order. No "# " title.
    - Use "### " for each story or item inside a section, "-" bullets, and **bold** only for labels such as **Situation**, **Task**, **Action**, **Result**.
    - Build on the user's résumé and research below; never invent employers, numbers or projects. Where something is missing, write "To fill in:" with what to add.
    - No emoji, no tables, no HTML, no preamble or closing remarks. Plain, direct sentences.
    """

    private func generate(_ t: Topic) {
        guard !generating.contains(t.id) else { return }
        let d = ensureDoc(t)
        generating.insert(t.id)
        error = nil
        let r = role
        let planRole = Plan.Role(company: r?.company ?? "", title: r?.title ?? "", team: r?.team ?? "", location: r?.location ?? "",
                                 link: r?.link ?? "", interview_at: r.flatMap { DateCoding.string($0.interviewAt) } ?? "",
                                 interview_note: r?.interviewNote ?? "", notes: r?.notes ?? "", stage: r?.stageRaw ?? "")
        let planDoc = Plan.Doc(key: t.id, title: t.title, headings: t.headings)
        // The user's own material for this role: résumé, job posting and research docs.
        let material = docs.filter { $0.roleId == (r?.id ?? "") && !$0.isPDF && !$0.tags.contains("essentials")
                                     && ($0.tags.contains("resume") || $0.tags.contains("job-posting") || $0.title.localizedCaseInsensitiveContains("research")) }
            .map { "<document title=\"\($0.title)\">\n\($0.body.prefix(12_000))\n</document>" }.joined(separator: "\n")
        let ctx = Self.formatRules + "\n\n" + (material.isEmpty ? "(No résumé or research documents yet. Write general guidance and mark personal parts \"To fill in:\".)" : material)
        Task {
            defer { generating.remove(t.id) }
            do {
                var body: String
                if claude.isReady {
                    body = try await claude.runText(PlannerPrompt.docPrompt(role: planRole, doc: planDoc, context: ctx), tools: "Read WebSearch WebFetch").text
                } else {
                    struct Req: Encodable { let mode = "doc"; let role: Plan.Role; let doc: Plan.Doc; let context: String; let now: String; let timezone: String }
                    struct Res: Decodable { let body: String?; let error: String? }
                    let res: Res = try await cloud.invoke(Req(role: planRole, doc: planDoc, context: ctx, now: DateCoding.string(.now), timezone: TimeZone.current.identifier))
                    guard let b = res.body, !b.isEmpty else { throw Learning.Failure.message(res.error ?? "Nothing came back. Try again.") }
                    body = b
                }
                d.body = body.withoutEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                d.updatedAt = .now
                try? context.save()
            } catch {
                self.error = "\(t.title): \(error.localizedDescription)"
            }
        }
    }
}
