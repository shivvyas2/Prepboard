import SwiftData
import SwiftUI

// MARK: - Code editor (plain monospaced text; no smart quotes, dashes or autocorrect, which break code)

#if os(macOS)
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 10, height: 12)
        tv.backgroundColor = NSColor(PB.card)
        tv.textColor = NSColor(PB.ink)
        tv.insertionPointColor = NSColor(PB.cobalt)
        tv.string = text
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ p: CodeEditor) { parent = p }
        func textDidChange(_ n: Notification) { parent.text = (n.object as! NSTextView).string }
    }
}
#else
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.keyboardDismissMode = .interactive
        tv.backgroundColor = UIColor(PB.card)
        tv.textColor = UIColor(PB.ink)
        tv.tintColor = UIColor(PB.cobalt)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) { if tv.text != text { tv.text = text } }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        init(_ p: CodeEditor) { parent = p }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text }
    }
}
#endif

// MARK: - Practice

/// LeetCode-style problem + editor + console, with a CoderPad-style AI assistant you can switch off for "no AI" rounds.
struct PracticeView: View {
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(ClaudeCode.self) private var claude
    @Environment(\.modelContext) private var context
    @Query(sort: \Problem.createdAt, order: .reverse) private var problems: [Problem]
    @Query private var roles: [Role]

    @AppStorage("practice.problem") private var selectedID = ""
    @AppStorage("practice.ai") private var aiAllowed = true
    @State private var code = ""
    @State private var output = ""
    @State private var running = false
    @State private var pane = 0                   // compact: 0 problem · 1 code · 2 output · 3 AI
    @State private var leftTab = 0                // wide: 0 problem · 1 AI
    @State private var aiMessages: [PlannerMessage] = []
    @State private var aiInput = ""
    @State private var aiThinking = false
    @State private var claudeSession: String?
    @State private var showNew = false
    @State private var timerStart: Date?
    @State private var timerMinutes = 45

    private var problem: Problem? { problems.first { $0.id == selectedID } ?? problems.first }
    private var lang: CodeLang { CodeLang(rawValue: problem?.language ?? "swift") ?? .swift }

    var body: some View {
        GeometryReader { geo in
            if let problem {
                VStack(spacing: 12) {
                    toolbar(problem, compact: geo.size.width < 760)
                    if geo.size.width >= 760 { wide(problem, width: geo.size.width) } else { compact(problem) }
                }
                .onAppear { load(problem) }
                .onChange(of: problem.id) { load(problem) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { if problems.isEmpty { let p = Problem.sample(); context.insert(p); try? context.save(); selectedID = p.id } }
            }
        }
        .padding(.bottom, 20)
        .sheet(isPresented: $showNew) { NewProblemSheet { selectedID = $0 } }
    }

    // MARK: layout

    private func wide(_ p: Problem, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                if aiAllowed {
                    Picker("", selection: $leftTab) { Text("Problem").tag(0); Text("AI assistant").tag(1) }
                        .pickerStyle(.segmented).labelsHidden().padding(12)
                    Divider()
                }
                if leftTab == 1 && aiAllowed { assistant(p) } else { statement(p) }
            }
            .frame(width: min(460, width * 0.4))
            .frame(maxHeight: .infinity)
            .pbCard(padding: 0, radius: PB.rXL)

            VStack(spacing: 0) {
                CodeEditor(text: $code).frame(maxHeight: .infinity)
                Divider()
                console.frame(height: 190)
            }
            .clipShape(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).strokeBorder(PB.line))
            .background(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).fill(PB.card))
        }
    }

    private func compact(_ p: Problem) -> some View {
        VStack(spacing: 10) {
            Picker("", selection: $pane) {
                Text("Problem").tag(0); Text("Code").tag(1); Text("Output").tag(2)
                if aiAllowed { Text("AI").tag(3) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch pane {
                case 1: CodeEditor(text: $code)
                case 2: console
                case 3 where aiAllowed: assistant(p)
                default: statement(p)
                }
            }
            .frame(maxHeight: .infinity)
            .pbCard(padding: 0, radius: PB.rLG)
        }
    }

    private func toolbar(_ p: Problem, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("New problem…") { showNew = true }
                Divider()
                ForEach(problems) { q in
                    Button((q.solved ? "✓ " : "") + "\(q.title) · \(q.difficulty)") { save(); selectedID = q.id }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(p.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .padding(.horizontal, 14).frame(height: 36)
                .overlay(Capsule().strokeBorder(PB.line2))
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            difficultyChip(p.difficulty)
            Picker("", selection: Binding(get: { lang }, set: { switchLanguage(to: $0) })) {
                ForEach(CodeLang.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Spacer(minLength: 0)
            if !compact { timer }
            Toggle("AI", isOn: $aiAllowed).toggleStyle(CheckboxToggleStyle())
                .help("Allow the AI assistant (like CoderPad's). Turn off to practice a no-AI round.")
            Menu {
                Button("Reset to starter code") { code = p.starters[lang.rawValue] ?? ""; save() }
                Button(p.solved ? "Mark unsolved" : "Mark solved") { p.solved.toggle(); save() }
                Button("Delete problem", role: .destructive) { context.delete(p); try? context.save(); selectedID = "" }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { run() } label: {
                Label(running ? "Running…" : "Run", systemImage: "play.fill").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle(compact: true)).disabled(running)
            .keyboardShortcut(.return, modifiers: .command)
            .help(lang.runsHere ? "Run the file, including its tests (⌘↩)" : "\(lang.label) runs in the Mac app")
            if aiAllowed {
                Button("Review") { review(p) }.buttonStyle(PillButtonStyle(filled: false, compact: true)).disabled(aiThinking)
            }
        }
    }

    private var timer: some View {
        Group {
            if let start = timerStart {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = Int(Double(timerMinutes * 60) - ctx.date.timeIntervalSince(start))
                    Button { timerStart = nil } label: {
                        Text(left >= 0 ? String(format: "%02d:%02d", left / 60, left % 60) : "Time's up")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(left < 300 ? PB.red : PB.ink)
                    }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true)).help("Stop the interview timer")
                }
            } else {
                Menu {
                    ForEach([20, 30, 45, 60], id: \.self) { m in Button("\(m) minutes") { timerMinutes = m; timerStart = .now } }
                } label: { Label("Timer", systemImage: "timer").font(.system(size: 13, weight: .medium)) }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
        }
    }

    private func difficultyChip(_ d: String) -> some View {
        Text(d).font(.system(size: 11, weight: .bold))
            .foregroundStyle(d == "Easy" ? Color(hex: 0x2F7D4F) : d == "Hard" ? PB.red : PB.onSun)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(d == "Easy" ? Color(hex: 0xDDEEDF) : d == "Hard" ? Color(hex: 0xFBE4D8) : PB.sunSoft))
    }

    private func statement(_ p: Problem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(p.title).font(.system(size: 22, weight: .bold)).kerning(-0.4)
                if !p.topics.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(p.topics, id: \.self) { Text($0).font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(PB.surface)).overlay(Capsule().strokeBorder(PB.line)) }
                    }
                }
                MarkdownView(blocks: MarkdownParser.parse(p.statement))
                if !p.notes.isEmpty {
                    Text("Last review").pbLabelStyle().padding(.top, 8)
                    MarkdownView(blocks: MarkdownParser.parse(p.notes))
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var console: some View {
        ScrollView {
            Text(output.isEmpty ? "Run your code to see the output and test results here." : output)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(output.isEmpty ? PB.muted : PB.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(PB.surface)
    }

    private func assistant(_ p: Problem) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if aiMessages.isEmpty {
                            Text("Ask about an approach, an API or an error, like CoderPad's AI assistant. It sees the problem and your code, and gives hints rather than full answers unless you ask.")
                                .font(.system(size: 13)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(aiMessages.enumerated()), id: \.offset) { _, m in
                            Group {
                                if m.role == "user" {
                                    Text(m.content).font(.system(size: 13)).foregroundStyle(.white)
                                        .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(PB.cobalt))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                } else {
                                    MarkdownView(blocks: MarkdownParser.parse(m.content))
                                        .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(PB.surface))
                                }
                            }
                        }
                        if aiThinking { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").font(.system(size: 12)).foregroundStyle(PB.muted) } }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .onChange(of: aiMessages.count) { withAnimation { proxy.scrollTo("end") } }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask the AI…", text: $aiInput, axis: .vertical).textFieldStyle(.plain).lineLimit(1...5)
                    .onSubmit { ask(aiInput, p) }
                Button { ask(aiInput, p) } label: { Image(systemName: "arrow.up").foregroundStyle(.white).frame(width: 30, height: 30).background(Circle().fill(PB.cobalt)) }
                    .buttonStyle(.plain).disabled(aiThinking || aiInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    // MARK: actions

    private func load(_ p: Problem) {
        code = p.currentCode(p.language)
        output = ""
        aiMessages = []
        claudeSession = nil
    }

    private func save() {
        guard let p = problem else { return }
        if p.code[p.language] != code { p.code[p.language] = code; p.updatedAt = .now }
        try? context.save()
    }

    private func switchLanguage(to l: CodeLang) {
        save()
        guard let p = problem else { return }
        p.language = l.rawValue
        code = p.currentCode(l.rawValue)
        try? context.save()
    }

    private func run() {
        save()
        running = true
        output = "Running \(lang.label)…"
        if pane != 3 { pane = 2 }
        let src = code, l = lang
        Task {
            output = await CodeRunner.run(src, lang: l)
            running = false
            if output.contains("Passed "), let p = problem,
               let m = output.range(of: #"Passed (\d+)/(\d+)"#, options: .regularExpression) {
                let nums = output[m].dropFirst(7).split(separator: "/")
                if nums.count == 2, nums[0] == nums[1], !p.solved { p.solved = true; try? context.save() }
            }
        }
    }

    private func review(_ p: Problem) {
        leftTab = 1; pane = 3
        ask(PracticePrompt.review, p, saveReview: true)
    }

    private func ask(_ text: String, _ p: Problem, saveReview: Bool = false) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !aiThinking else { return }
        save()
        aiInput = ""
        aiMessages.append(.init(role: "user", content: q))
        aiThinking = true
        let system = PracticePrompt.assistSystem(problem: p, lang: lang, code: code)
        let history = aiMessages
        Task {
            defer { aiThinking = false }
            do {
                var reply: String
                if claude.isReady {
                    // Fresh context each turn so the AI always sees the latest code.
                    let convo = history.map { "\($0.role == "user" ? "Candidate" : "Assistant"): \($0.content)" }.joined(separator: "\n\n")
                    reply = try await claude.runText(system + "\n\n" + convo + "\n\nAssistant:", tools: "Read WebSearch WebFetch").text
                } else {
                    struct Req: Encodable { let mode = "assist"; let system: String; let messages: [PlannerMessage] }
                    struct Res: Decodable { let reply: String?; let error: String? }
                    let r: Res = try await cloud.invoke(Req(system: system, messages: history))
                    if let e = r.error { throw Learning.Failure.message(e) }
                    reply = r.reply ?? ""
                }
                reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                aiMessages.append(.init(role: "assistant", content: reply))
                if saveReview { p.notes = reply; p.updatedAt = .now; try? context.save() }
            } catch {
                aiMessages.append(.init(role: "assistant", content: "Sorry — \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - New problem

struct NewProblemSheet: View {
    var onCreate: (String) -> Void
    @Environment(Cloud.self) private var cloud
    @Environment(ClaudeCode.self) private var claude
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var roles: [Role]
    @State private var topic = ""
    @State private var difficulty = "Medium"
    @State private var pasted = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New practice problem").font(.system(size: 20, weight: .bold))
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
            }
            Text("Describe a topic and AI writes a LeetCode-style problem with tests in Swift, Python and JavaScript. Or paste a problem (e.g. from LeetCode) to practice it here.")
                .font(.system(size: 13)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            PBTextField(label: "Topic", text: $topic)
            HStack(spacing: 14) {
                Text("Difficulty").pbLabelStyle()
                ForEach(["Easy", "Medium", "Hard"], id: \.self) { d in
                    Toggle(d, isOn: Binding(get: { difficulty == d }, set: { if $0 { difficulty = d } })).toggleStyle(CheckboxToggleStyle())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Or paste a problem").pbLabelStyle()
                TextEditor(text: $pasted).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(height: 140).padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(PB.red) }
            HStack {
                Spacer()
                Button(busy ? "Writing the problem…" : "Create") { create() }
                    .buttonStyle(PillButtonStyle()).disabled(busy || (topic.isEmpty && pasted.isEmpty))
            }
        }
        .padding(24)
        .background(PB.card)
        #if os(macOS)
        .frame(width: 560)
        #endif
    }

    private func create() {
        busy = true; error = nil
        let role = roles.first { $0.id == app.timelineRoleID } ?? roles.filter { ($0.interviewAt ?? .distantPast) > .now }.min { $0.interviewAt! < $1.interviewAt! }
        let prompt = PracticePrompt.problem(topic: topic, difficulty: difficulty, pasted: pasted,
                                            role: role.map { "\($0.company) — \($0.title)" } ?? "")
        Task {
            defer { busy = false }
            do {
                let payload: ProblemPayload
                if claude.isReady {
                    payload = try await claude.runJSON(prompt, tools: "Read WebFetch")
                } else {
                    struct Req: Encodable { let mode = "problem"; let prompt: String }
                    struct Res: Decodable { let problem: ProblemPayload?; let error: String? }
                    let r: Res = try await cloud.invoke(Req(prompt: prompt))
                    guard let p = r.problem else { throw Learning.Failure.message(r.error ?? "No problem came back. Try again.") }
                    payload = p
                }
                let p = Problem(roleId: role?.id ?? "", title: payload.title, difficulty: payload.difficulty, topics: payload.topics,
                                statement: payload.statement, starters: payload.starters)
                context.insert(p)
                try? context.save()
                onCreate(p.id)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
