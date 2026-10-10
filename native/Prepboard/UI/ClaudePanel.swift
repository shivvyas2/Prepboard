#if os(macOS)
import SwiftData
import SwiftUI

/// Side panel that talks to the user's local Claude Code, with the current doc or session as context.
struct ClaudePanel: View {
    @Environment(AppState.self) private var app
    @Environment(ClaudeCode.self) private var claude
    @Environment(\.modelContext) private var context
    @Query private var docs: [Doc]
    @Query(sort: \PrepTask.start) private var tasks: [PrepTask]
    @Query private var roles: [Role]
    @State private var input = ""
    @State private var includeContext = true
    @FocusState private var inputFocused: Bool

    private struct Context { let label: String; let text: String; let roleId: String }

    /// What the user is looking at: the open document, otherwise the current/next session.
    private var currentContext: Context? {
        if app.section == .documents, let id = app.selectedDocID, let d = docs.first(where: { $0.id == id }) {
            return Context(label: "Doc · \(d.title)", text: "Document “\(d.title)”:\n\n" + String(d.body.prefix(14_000)), roleId: d.roleId)
        }
        let now = Date.now
        let roleTasks = tasks.filter { !$0.isBreak && (app.timelineRoleID == nil || $0.roleId == app.timelineRoleID) }
        if let t = roleTasks.first(where: { $0.status(at: now) == .current }) ?? roleTasks.first(where: { !$0.done && $0.end > now }) {
            let docsById = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })
            let refs = t.refs.compactMap { r in docsById[r.docId].map { "- \($0.title)" + (r.heading.isEmpty ? "" : " › \(r.heading)") } }
            let role = roles.first { $0.id == t.roleId }
            var text = "Current prep session: \(t.title) (\(TimeFmt.hm(t.start))–\(TimeFmt.hm(t.end)), \(t.kind.label))."
            if let role { text += "\nRole: \(role.company) — \(role.title). Interview: \(role.interviewAt?.pbFull ?? "not set"). \(role.notes)" }
            if !refs.isEmpty { text += "\nLinked guide sections:\n" + refs.joined(separator: "\n") }
            return Context(label: "Session · \(t.title)", text: text, roleId: t.roleId)
        }
        return nil
    }

    var body: some View {
        let ctx = currentContext
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if claude.messages.isEmpty { intro(ctx) }
                        ForEach(claude.messages) { m in bubble(m, ctx: ctx).id(m.id) }
                        if let status = claude.status {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.system(size: 12)).foregroundStyle(PB.muted) }
                        }
                        if let error = claude.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(PB.red)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(PB.red.opacity(0.08)))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: claude.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer(ctx)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).fill(PB.card))
        .overlay(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).strokeBorder(PB.line))
        .clipShape(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous))
        .shadow(color: Color(hex: 0x3C2D14).opacity(0.07), radius: 14, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ClaudeMark().frame(width: 18, height: 18)
                .frame(width: 30, height: 30).background(Circle().fill(Color(hex: 0xF5EDE4)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code").font(.system(size: 15, weight: .semibold))
                Text(claude.workingDirectory.lastPathComponent).font(.pbMono).foregroundStyle(PB.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("New conversation") { claude.reset() }
                Button("Change folder…") { claude.chooseWorkingDirectory() }
                Divider()
                Text("Tools allowed: read files, search the web")
            } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            CircleIconButton(systemImage: "xmark", size: 30, label: "Close Claude") { app.showClaude = false }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.line).frame(height: 1) }
    }

    private func intro(_ ctx: Context?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask your local Claude Code about what you're studying. It can read your prep folder and search the web.")
                .font(.system(size: 13)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
            Text("Try").pbLabelStyle().padding(.top, 4)
            ForEach(suggestions(ctx), id: \.self) { s in
                Button { send(s, ctx: ctx) } label: {
                    Text(s).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func suggestions(_ ctx: Context?) -> [String] {
        guard let ctx else {
            return ["What should I focus on before my next interview?", "Give me one medium LeetCode problem in Swift to practice now."]
        }
        if ctx.label.hasPrefix("Doc") {
            return ["Quiz me with 5 questions on this document.", "Summarize this into a one-page cheat sheet.", "What are the most likely follow-up questions on this?"]
        }
        return ["Quiz me on this session's topics.", "Give me one practice problem for this session, no solution yet.", "Explain the key idea of each linked section in 2 lines."]
    }

    private func bubble(_ m: ClaudeCode.Message, ctx: Context?) -> some View {
        Group {
            if m.role == .user {
                Text(m.text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(PB.cobalt))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    MarkdownView(blocks: MarkdownParser.parse(m.text))
                    if !claude.isRunning || m.id != claude.messages.last?.id {
                        HStack(spacing: 6) {
                            Button("Save as document") { save(m, ctx: ctx) }
                                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(m.text, forType: .string)
                            }
                            .buttonStyle(PillButtonStyle(filled: false, compact: true))
                        }
                    }
                }
            }
        }
    }

    private func composer(_ ctx: Context?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ctx, claude.sessionId == nil {
                Toggle(isOn: $includeContext) {
                    Text("Include \(ctx.label)").font(.system(size: 12)).foregroundStyle(PB.ink2).lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Claude…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 14))
                    .focused($inputFocused)
                    .onSubmit { send(input, ctx: ctx) }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PB.surface))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PB.line))
                if claude.isRunning {
                    CircleIconButton(systemImage: "stop.fill", size: 40, active: true, label: "Stop") { claude.stop() }
                } else {
                    CircleIconButton(systemImage: "arrow.up", size: 40, active: true, label: "Send") { send(input, ctx: ctx) }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .overlay(alignment: .top) { Rectangle().fill(PB.line).frame(height: 1) }
        .onAppear { inputFocused = true }
    }

    private func send(_ text: String, ctx: Context?) {
        claude.send(text, context: includeContext ? ctx?.text : nil)
        input = ""
    }

    private func save(_ m: ClaudeCode.Message, ctx: Context?) {
        let question = claude.messages.prefix { $0.id != m.id }.last { $0.role == .user }?.text ?? "Claude notes"
        let title = "Claude: " + String(question.prefix(60))
        app.newDoc(context, roleId: ctx?.roleId ?? "", title: title, body: m.text, tags: ["claude"])
    }
}
#endif
