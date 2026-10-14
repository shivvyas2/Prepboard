import SwiftData
import SwiftUI

// MARK: - Code editor (plain monospaced text; no smart quotes, dashes or autocorrect, which break code)

#if os(macOS)
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var lang: CodeLang = .swift
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.typingAttributes = [.font: Self.font, .foregroundColor: SyntaxHighlighter.plain]
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
        if let ts = tv.textStorage { SyntaxHighlighter.highlight(ts, lang: lang, font: Self.font) }
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text || context.coordinator.lang != lang {
            if tv.string != text { tv.string = text }
            context.coordinator.lang = lang
            if let ts = tv.textStorage { SyntaxHighlighter.highlight(ts, lang: lang, font: Self.font) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lang: CodeLang
        init(_ p: CodeEditor) { parent = p; lang = p.lang }
        func textDidChange(_ n: Notification) {
            let tv = n.object as! NSTextView
            if let ts = tv.textStorage { SyntaxHighlighter.highlight(ts, lang: parent.lang, font: CodeEditor.font) }
            parent.text = tv.string
        }
    }
}
#else
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var lang: CodeLang = .swift
    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.typingAttributes = [.font: Self.font, .foregroundColor: SyntaxHighlighter.plain]
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
        SyntaxHighlighter.highlight(tv.textStorage, lang: lang, font: Self.font)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text || context.coordinator.lang != lang {
            if tv.text != text { tv.text = text }
            context.coordinator.lang = lang
            SyntaxHighlighter.highlight(tv.textStorage, lang: lang, font: Self.font)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var lang: CodeLang
        init(_ p: CodeEditor) { parent = p; lang = p.lang }
        func textViewDidChange(_ tv: UITextView) {
            if tv.markedTextRange == nil { SyntaxHighlighter.highlight(tv.textStorage, lang: parent.lang, font: CodeEditor.font) }
            parent.text = tv.text
        }
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
    @State private var result: RunResult?
    @State private var running = false
    @State private var pane = 0                   // compact: 0 problem · 1 code · 2 output · 3 AI · 4 list
    @AppStorage("practice.library") private var showLibrary = true
    @State private var libFilter = "All"          // All · To do · Solved
    @State private var libDifficulty = "Any"
    @State private var libSearch = ""
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
        .padding(.bottom, 24)
        .sheet(isPresented: $showNew) { NewProblemSheet { selectedID = $0 } }
    }

    // MARK: layout

    private func wide(_ p: Problem, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if showLibrary && width >= 1000 {
                library.frame(width: 260).frame(maxHeight: .infinity).pbCard(padding: 0, radius: PB.rXL)
            }
            VStack(spacing: 0) {
                Picker("", selection: $leftTab) {
                    Text("Problem").tag(0)
                    Text(p.videos.isEmpty ? "Videos" : "Videos (\(p.videos.count))").tag(2)
                    if aiAllowed { Text("AI assistant").tag(1) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(12)
                Divider()
                switch leftTab {
                case 1 where aiAllowed: assistant(p)
                case 2: ProblemVideos(problem: p)
                default: statement(p)
                }
            }
            .frame(width: min(440, width * (showLibrary && width >= 1000 ? 0.32 : 0.4)))
            .frame(maxHeight: .infinity)
            .pbCard(padding: 0, radius: PB.rXL)

            VStack(spacing: 0) {
                CodeEditor(text: $code, lang: lang).frame(maxHeight: .infinity)
                Divider()
                console.frame(height: 220)
            }
            .clipShape(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).strokeBorder(PB.line))
            .background(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).fill(PB.card))
        }
    }

    private func compact(_ p: Problem) -> some View {
        VStack(spacing: 12) {
            Picker("", selection: $pane) {
                Text("All").tag(4); Text("Problem").tag(0); Text("Code").tag(1); Text("Output").tag(2)
                if aiAllowed { Text("AI").tag(3) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch pane {
                case 1: CodeEditor(text: $code, lang: lang)
                case 2: console
                case 3 where aiAllowed: assistant(p)
                case 4: library
                default:
                    VStack(spacing: 0) {
                        ProblemVideos(problem: p, compact: true)
                        Divider()
                        statement(p)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .pbCard(padding: 0, radius: PB.rLG)
        }
    }

    @ViewBuilder
    private func toolbar(_ p: Problem, compact: Bool) -> some View {
        if compact {
            // iPhone: two rows so nothing is squeezed or cut off.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    problemMenu(p).layoutPriority(1)
                    difficultyChip(p.difficulty)
                    Spacer(minLength: 0)
                    languagePicker
                }
                HStack(spacing: 8) {
                    Toggle("AI", isOn: $aiAllowed).toggleStyle(CheckboxToggleStyle(labeled: true))
                    Spacer(minLength: 0)
                    moreMenu(p)
                    if aiAllowed { reviewButton(p) }
                    runButton
                }
            }
        } else {
            HStack(spacing: 8) {
                CircleIconButton(systemImage: "sidebar.left", size: 40, active: showLibrary, label: "All problems") { showLibrary.toggle() }
                problemMenu(p)
                difficultyChip(p.difficulty)
                languagePicker
                Spacer(minLength: 0)
                timer
                Toggle("AI assistant", isOn: $aiAllowed).toggleStyle(CheckboxToggleStyle(labeled: true))
                    .help("Allow the AI assistant (like CoderPad's). Turn off to practice a no-AI round.")
                moreMenu(p)
                if aiAllowed { reviewButton(p) }
                runButton
            }
        }
    }

    private func problemMenu(_ p: Problem) -> some View {
        Menu {
            Button("New problem…") { showNew = true }
            Divider()
            ForEach(problems) { q in
                Button((q.solved ? "✓ " : "") + "\(q.title) · \(q.difficulty)") { save(); selectedID = q.id }
            }
        } label: {
            HStack(spacing: 8) {
                Text(p.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
            }
            .padding(.horizontal, 16).frame(height: 40)
            .overlay(Capsule().strokeBorder(PB.line2))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private var languagePicker: some View {
        Picker("", selection: Binding(get: { lang }, set: { switchLanguage(to: $0) })) {
            ForEach(CodeLang.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func moreMenu(_ p: Problem) -> some View {
        Menu {
            Button("Reset to starter code") { code = p.starters[lang.rawValue] ?? ""; save() }
            Button(p.solved ? "Mark unsolved" : "Mark solved") { p.solved.toggle(); save() }
            Button("Delete problem", role: .destructive) { context.delete(p); try? context.save(); selectedID = "" }
        } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40).contentShape(Rectangle()) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More actions")
    }

    private var runButton: some View {
        Button { run() } label: {
            Label(running ? "Running…" : "Run", systemImage: "play.fill").font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(PillButtonStyle(compact: true)).fixedSize().disabled(running)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Run the file, including its tests (⌘↩). \(lang.runnerNote).")
    }

    private func reviewButton(_ p: Problem) -> some View {
        Button("Review") { review(p) }.buttonStyle(PillButtonStyle(filled: false, compact: true)).fixedSize().disabled(aiThinking)
    }

    /// Every coding problem in one place: filter by status and difficulty, search titles and topics.
    private var library: some View {
        let q = libSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let list = problems.filter { p in
            (libFilter == "All" || (libFilter == "Solved") == p.solved)
                && (libDifficulty == "Any" || p.difficulty == libDifficulty)
                && (q.isEmpty || p.title.lowercased().contains(q) || p.topics.contains { $0.lowercased().contains(q) })
        }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Problems").font(.system(size: 15, weight: .semibold))
                    Text("\(problems.filter(\.solved).count)/\(problems.count) solved").font(.system(size: 12)).foregroundStyle(PB.muted)
                    Spacer(minLength: 0)
                    CircleIconButton(systemImage: "plus", size: 32, label: "New problem") { showNew = true }
                }
                TextField("Search title or topic", text: $libSearch).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(PB.surface)).overlay(Capsule().strokeBorder(PB.line))
                Picker("", selection: $libFilter) { ForEach(["All", "To do", "Solved"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Picker("", selection: $libDifficulty) { ForEach(["Any", "Easy", "Medium", "Hard"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { q in
                        Button { save(); selectedID = q.id; if pane == 4 { pane = 0 } } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: q.solved ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(q.solved ? PB.cobalt : PB.muted).font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(q.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(2)
                                    Text(([q.difficulty] + q.topics.prefix(2)).joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(PB.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(q.id == problem?.id ? PB.cobaltSoft : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty {
                        Text("No problems match.").font(.system(size: 13)).foregroundStyle(PB.muted).padding(24)
                    }
                }
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
        Text(d).font(.system(size: 11, weight: .bold)).fixedSize()
            .foregroundStyle(d == "Easy" ? PB.green : d == "Hard" ? PB.red : PB.sunInk)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(d == "Easy" ? PB.greenSoft : d == "Hard" ? PB.redSoft : PB.sunSoft))
    }

    private func statement(_ p: Problem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(p.title).font(.system(size: 22, weight: .bold)).kerning(-0.4)
                if !p.topics.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(p.topics, id: \.self) { Text($0).font(.system(size: 11, weight: .medium)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(PB.surface)).overlay(Capsule().strokeBorder(PB.line)) }
                    }
                }
                MarkdownView(blocks: MarkdownParser.parse(p.statement))
                if !p.notes.isEmpty {
                    Text("Last review").pbLabelStyle().padding(.top, 8)
                    MarkdownView(blocks: MarkdownParser.parse(p.notes))
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var console: some View {
        RunConsole(result: result, running: running, langLabel: lang.label)
    }

    private func assistant(_ p: Problem) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if aiMessages.isEmpty {
                            Text("Ask about an approach, an API or an error, like CoderPad's AI assistant. It sees the problem and your code, and gives hints rather than full answers unless you ask.")
                                .font(.system(size: 13)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(aiMessages.enumerated()), id: \.offset) { _, m in
                            Group {
                                if m.role == "user" {
                                    Text(m.content).font(.system(size: 13)).foregroundStyle(.white)
                                        .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(PB.cobalt))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                } else {
                                    MarkdownView(blocks: MarkdownParser.parse(m.content))
                                        .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(PB.surface))
                                }
                            }
                        }
                        if aiThinking { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").font(.system(size: 12)).foregroundStyle(PB.muted) } }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
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
            .padding(12)
        }
    }

    // MARK: actions

    private func load(_ p: Problem) {
        code = p.currentCode(p.language)
        result = nil
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
        result = nil
        if pane != 3 { pane = 2 }
        let src = code, l = lang
        Task {
            let r = await CodeRunner.run(src, lang: l, mac: claude)
            result = r
            running = false
            if r.verdict == .accepted, let p = problem, !p.solved { p.solved = true; try? context.save() }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New practice problem").font(.system(size: 20, weight: .bold))
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
            }
            Text("Describe a topic and AI writes a LeetCode-style problem with tests in Swift, Python and JavaScript. Or paste a problem (e.g. from LeetCode) to practice it here.")
                .font(.system(size: 13)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            PBTextField(label: "Topic", text: $topic)
            HStack(spacing: 16) {
                Text("Difficulty").pbLabelStyle()
                ForEach(["Easy", "Medium", "Hard"], id: \.self) { d in
                    Toggle(d, isOn: Binding(get: { difficulty == d }, set: { if $0 { difficulty = d } })).toggleStyle(CheckboxToggleStyle(labeled: true))
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

// MARK: - Videos

/// Video walkthroughs for a problem, played right beside the code. Found with Claude Code (or the
/// Anthropic key), saved on the problem and synced.
struct ProblemVideos: View {
    @Bindable var problem: Problem
    var compact = false
    @Environment(Cloud.self) private var cloud
    @Environment(ClaudeCode.self) private var claude
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var playing: Video?
    @State private var searching = false
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        if compact && !expanded && playing == nil {
            // iPhone: a slim bar above the problem; opens the full list on tap.
            Button { expanded = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle").foregroundStyle(PB.cobalt)
                    Text(problem.videos.isEmpty ? "Find video explanations" : "Videos (\(problem.videos.count))")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(PB.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(PB.muted)
                }
                .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let v = playing {
                    VStack(alignment: .leading, spacing: 8) {
                        YouTubePlayer(video: v).id(v.id).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(v.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Text(v.channel).font(.system(size: 12)).foregroundStyle(PB.muted)
                            }
                            Spacer(minLength: 0)
                            CircleIconButton(systemImage: "arrow.up.right.square", size: 32, label: "Open on YouTube") { openURL(v.watchURL) }
                            CircleIconButton(systemImage: "xmark", size: 32, label: "Close video") { playing = nil }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(problem.videos.isEmpty ? "Video explanations" : "\(problem.videos.count) videos").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    if compact { CircleIconButton(systemImage: "chevron.up", size: 32, label: "Hide videos") { expanded = false; playing = nil } }
                    Button(searching ? "Searching…" : (problem.videos.isEmpty ? "Find videos" : "Find more")) { find() }
                        .buttonStyle(PillButtonStyle(compact: true)).fixedSize().disabled(searching)
                }
                if problem.videos.isEmpty && !searching {
                    Text("Find walkthroughs for this problem: approach, edge cases and complexity, from channels like NeetCode. They play here, next to your code.")
                        .font(.system(size: 13)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(PB.red).fixedSize(horizontal: false, vertical: true) }
                ForEach(problem.videos) { v in
                    Button { playing = v } label: {
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: v.thumbnailURL) { img in img.resizable().scaledToFill() } placeholder: { Color.black.opacity(0.85) }
                                .frame(width: 128, height: 72).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay { Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(.white).shadow(radius: 4) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(v.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(PB.ink).lineLimit(2).multilineTextAlignment(.leading)
                                Text(v.channel).font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
                                if !v.why.isEmpty { Text(v.why).font(.system(size: 12)).foregroundStyle(PB.ink2).lineLimit(2).multilineTextAlignment(.leading) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(v.id == playing?.id ? PB.cobaltSoft : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove", role: .destructive) { problem.videos.removeAll { $0.id == v.id }; try? context.save() } }
                }
            }
            .padding(16)
        }
        .frame(maxHeight: compact ? 520 : .infinity)
    }

    private func find() {
        searching = true; error = nil
        let topic = "\(problem.title) coding interview problem solution explanation (LeetCode-style walkthrough)"
        let ctx = "\(problem.difficulty) · topics: \(problem.topics.joined(separator: ", ")). Prefer NeetCode, Back To Back SWE, take U forward, or the official LeetCode channel."
        Task {
            defer { searching = false }
            do {
                let found = try await Learning.videos(topic: topic, context: ctx, claude: claude, cloud: cloud)
                let known = Set(problem.videos.map(\.id))
                problem.videos += found.filter { !known.contains($0.id) }
                problem.updatedAt = .now
                try? context.save()
                if found.isEmpty { error = "No videos found. Try again in a moment." }
                else if playing == nil { playing = problem.videos.first }
            } catch { self.error = error.localizedDescription }
        }
    }
}
