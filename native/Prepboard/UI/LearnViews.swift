import SwiftData
import SwiftUI

struct IdentifiedString: Identifiable { let id: String }

// MARK: - Session learning row (Quiz me / Find videos / video thumbnails)

struct SessionLearnRow: View {
    @Bindable var task: PrepTask
    var inverted = false
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(\.openURL) private var openURL
    @Environment(ClaudeCode.self) private var claude
    @Query private var roles: [Role]
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !task.videos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) { ForEach(task.videos) { VideoThumb(video: $0) } }
                }
            }
            FlowLayout(spacing: 8) {
                pill("Quiz me", dot: true) { app.quizSessionID = task.id }
                if task.videos.isEmpty {
                    pill(searching ? "Searching YouTube…" : "▶ Find videos") { findVideos() }.disabled(searching)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(inverted ? .white.opacity(0.85) : PB.red).lineLimit(1) }
            }
        }
        .padding(.top, 4)
    }

    private func pill(_ title: String, dot: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if dot { Circle().fill(PB.sun).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(inverted ? Color.white : PB.ink2)
            .overlay(Capsule().strokeBorder(inverted ? Color.white.opacity(0.35) : PB.line2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func findVideos() {
        searching = true; error = nil
        let role = roles.first { $0.id == task.roleId }
        let topic = task.title + (task.refs.isEmpty ? "" : " — " + task.refs.map(\.heading).filter { !$0.isEmpty }.joined(separator: ", "))
        Task {
            defer { searching = false }
            do {
                let c: AnyObject? = claude
                let vids = try await Learning.videos(topic: topic, context: role.map { "\($0.company) \($0.title) interview prep" } ?? "interview prep",
                                                     claude: c, cloud: cloud)
                task.videos = vids
                if vids.isEmpty { error = "No good videos found." }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct VideoThumb: View {
    let video: Video
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.playingVideo = video } label: {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: video.thumbnailURL) { img in img.resizable().scaledToFill() } placeholder: { Color.black.opacity(0.85) }
                    .frame(width: 200, height: 112).clipped()
                    .overlay { Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(.white).shadow(radius: 4) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).foregroundStyle(PB.ink)
                    Text(video.channel).font(.system(size: 11)).foregroundStyle(PB.muted).lineLimit(1)
                }
                .padding(8).frame(width: 200, alignment: .leading)
            }
            .background(PB.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PB.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(video.why)
    }
}

// MARK: - Quiz

struct QuizSheet: View {
    var sessionID: String? = nil
    var reviewID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Environment(Cloud.self) private var cloud
    @Environment(ClaudeCode.self) private var claude
    @Query private var tasks: [PrepTask]
    @Query private var docs: [Doc]
    @Query private var attempts: [QuizAttempt]

    enum Phase { case loading, error(String), question, done(QuizAttempt) }
    @State private var phase: Phase = .loading
    @State private var questions: [Learning.Question] = []
    @State private var index = 0
    @State private var answers: [Int: Int] = [:]
    @State private var source = "cloud"
    @State private var topic = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KindLabel(kind: .mock).overlay(alignment: .leading) { EmptyView() }
                Text(topic).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                if source == "claude-code" { HStack(spacing: 4) { ClaudeMark().frame(width: 12, height: 12); Text("Claude Code").font(.system(size: 11)).foregroundStyle(PB.muted) } }
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(PB.line).frame(height: 1) }
            ScrollView { content.padding(24) }
        }
        .pbSheetFrame(minWidth: 480, idealWidth: 640, minHeight: 420, idealHeight: 640)
        .background(PB.card)
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is writing your quiz…").foregroundStyle(PB.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 64)
        case .error(let msg):
            VStack(alignment: .leading, spacing: 12) {
                Text(msg).font(.system(size: 13)).foregroundStyle(PB.red)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PB.redSoft))
                Button("Try again") { Task { await start() } }.buttonStyle(PillButtonStyle())
            }
        case .question:
            questionView
        case .done(let attempt):
            ResultsView(attempt: attempt) {
                if let s = attempt.sessionId.nilIfEmpty, sessionID != nil { _ = s; index = 0; answers = [:]; Task { await start() } }
            } openScores: { dismiss(); app.section = .scores }
        }
    }

    private var questionView: some View {
        let q = questions[index]
        let chosen = answers[index]
        return VStack(alignment: .leading, spacing: 16) {
            ProgressBar(value: Double(index + (chosen == nil ? 0 : 1)) / Double(max(1, questions.count)))
            Text("Question \(index + 1) of \(questions.count) · \(q.topic)").pbLabelStyle()
            Text(q.question).font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(0..<q.options.count, id: \.self) { k in
                let isRight = chosen != nil && k == q.answer
                let isWrong = chosen == k && k != q.answer
                Button { if chosen == nil { answers[index] = k } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(String("ABCD".map { $0 }[k])).font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(isRight || isWrong ? .white : PB.ink)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isRight ? PB.green : isWrong ? PB.red : PB.surface))
                        Text(q.options[k]).font(.system(size: 14)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(isRight ? PB.greenSoft : isWrong ? PB.redSoft : PB.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isRight ? PB.green : isWrong ? PB.red : PB.line2, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chosen != nil)
            }
            if let chosen {
                (Text(chosen == q.answer ? "Correct. " : "Answer: \(String("ABCD".map { $0 }[q.answer])). ").bold() + Text(q.explanation))
                    .font(.system(size: 14))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(PB.surface))
                HStack {
                    Spacer()
                    Button(index + 1 < questions.count ? "Next question" : "See results") {
                        if index + 1 < questions.count { index += 1 } else { finish() }
                    }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func start() async {
        if let reviewID, let a = attempts.first(where: { $0.id == reviewID }) {
            topic = a.topic; source = a.source; phase = .done(a); return
        }
        guard let sessionID, let task = tasks.first(where: { $0.id == sessionID }) else { phase = .error("Session not found."); return }
        topic = task.title
        phase = .loading
        do {
            let c: AnyObject? = claude
            let (payload, src) = try await Learning.quiz(topic: task.title, material: Learning.material(for: task, docs: docs), claude: c, cloud: cloud)
            guard !payload.questions.isEmpty else { throw Learning.Failure.message("No questions came back. Try again.") }
            questions = payload.questions; source = src; index = 0; answers = [:]
            phase = .question
        } catch { phase = .error(error.localizedDescription) }
    }

    private func finish() {
        guard let task = tasks.first(where: { $0.id == sessionID }) else { return }
        let items = questions.enumerated().map { k, q in
            QuizItem(question: q.question, options: q.options, answer: q.answer, chosen: answers[k], explanation: q.explanation, topic: q.topic)
        }
        let attempt = QuizAttempt(roleId: task.roleId, sessionId: task.id, topic: task.title, items: items, source: source)
        context.insert(attempt)
        try? context.save()
        phase = .done(attempt)
    }
}

struct ResultsView: View {
    let attempt: QuizAttempt
    var retake: (() -> Void)?
    var openScores: (() -> Void)?

    var body: some View {
        let p = attempt.total == 0 ? 0 : Double(attempt.score) / Double(attempt.total)
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(PB.surface, lineWidth: 12)
                    Circle().trim(from: 0, to: p).stroke(PB.cobalt, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(p * 100))%").font(.system(size: 28, weight: .heavy))
                }
                .frame(width: 112, height: 112)
                Text("\(attempt.score) of \(attempt.total) correct").font(.system(size: 18, weight: .bold))
                Text(attempt.topic).font(.system(size: 13)).foregroundStyle(PB.muted)
            }
            .frame(maxWidth: .infinity)
            if attempt.weakTopics.isEmpty {
                Text("Solid. Nothing flagged to revisit.").font(.system(size: 13)).foregroundStyle(PB.cobalt)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(PB.cobaltSoft))
            } else {
                Text("Learn more").pbLabelStyle()
                FlowLayout(spacing: 8) {
                    ForEach(attempt.weakTopics, id: \.self) { w in
                        Text(w).font(.system(size: 11, weight: .bold)).foregroundStyle(PB.red)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 8).fill(PB.redSoft))
                    }
                }
            }
            Text("Answers").pbLabelStyle()
            ForEach(Array(attempt.items.enumerated()), id: \.offset) { k, it in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(k + 1). \(it.question)").font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text((it.isCorrect ? "✓ Your answer: " : "✗ Your answer: ") + (it.chosen.flatMap { $0 < it.options.count ? it.options[$0] : nil } ?? "—"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(it.isCorrect ? PB.green : PB.red)
                    if !it.isCorrect {
                        Text("Correct: \(it.options[it.answer])").font(.system(size: 13, weight: .semibold)).foregroundStyle(PB.green)
                    }
                    Text(it.explanation).font(.system(size: 13)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PB.line))
            }
            HStack(spacing: 8) {
                Spacer()
                if let retake { Button("Retake", action: retake).buttonStyle(PillButtonStyle(filled: false, compact: true)) }
                if let openScores { Button("Open Scores", action: openScores).buttonStyle(PillButtonStyle()) }
            }
        }
    }
}

// MARK: - Scores (leaderboard)

struct ScoresView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \QuizAttempt.createdAt, order: .reverse) private var attempts: [QuizAttempt]
    @Query private var docs: [Doc]
    @Query private var tasks: [PrepTask]

    struct TopicScore: Identifiable { let topic: String; var right: Int; var total: Int; var id: String { topic }
        var pct: Int { total == 0 ? 0 : Int((Double(right) / Double(total) * 100).rounded()) } }

    var body: some View {
        var map: [String: TopicScore] = [:]
        for a in attempts { for it in a.items {
            let k = it.topic.isEmpty ? a.topic : it.topic
            var t = map[k] ?? TopicScore(topic: k, right: 0, total: 0)
            t.total += 1; if it.isCorrect { t.right += 1 }
            map[k] = t
        } }
        let board = map.values.sorted { ($0.pct, $0.total) > ($1.pct, $1.total) }
        let weak = board.filter { $0.pct < 70 }.sorted { $0.pct < $1.pct }.prefix(6)
        let answered = board.reduce(0) { $0 + $1.total }, right = board.reduce(0) { $0 + $1.right }

        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Leaderboard").pbLabelStyle()
                        Text("Scores").font(.pbDisplay).kerning(-1.4)
                    }
                    if attempts.isEmpty {
                        VStack(spacing: 12) {
                            Text("No quizzes yet").font(.system(size: 18, weight: .semibold))
                            Text("Open any session on the timeline and tap Quiz me. Claude writes questions from that session's study guides, and your results land here.")
                                .foregroundStyle(PB.muted).multilineTextAlignment(.center).frame(maxWidth: 480)
                            Button("Go to timeline") { app.section = .timeline }.buttonStyle(PillButtonStyle())
                        }
                        .frame(maxWidth: .infinity).padding(48).pbCard()
                    } else {
                        stats(quizzes: attempts.count, accuracy: answered == 0 ? 0 : Double(right) / Double(answered), answered: answered, weak: weak.count)
                        if geo.size.width > 980 {
                            HStack(alignment: .top, spacing: 16) { leaderboard(board); VStack(spacing: 16) { learnMore(Array(weak)); history }.frame(width: 420) }
                        } else {
                            leaderboard(board); learnMore(Array(weak)); history
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func stats(quizzes: Int, accuracy: Double, answered: Int, weak: Int) -> some View {
        HStack(spacing: 12) {
            cell("Quizzes taken", "\(quizzes)")
            VStack(alignment: .leading, spacing: 4) {
                Text("Accuracy").pbLabelStyle()
                Text("\(Int(accuracy * 100))%").font(.system(size: 26, weight: .bold))
                ProgressBar(value: accuracy)
            }
            .pbCard(padding: 16, fill: PB.surface, radius: PB.rLG)
            cell("Questions answered", "\(answered)")
            cell("Topics to revisit", "\(weak)", highlight: weak > 0)
        }
    }

    private func cell(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if highlight {
                Text(label).font(.pbLabel).kerning(0.9).textCase(.uppercase).foregroundStyle(PB.onSun.opacity(0.9))
            } else {
                Text(label).pbLabelStyle()
            }
            Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(highlight ? PB.onSun : PB.ink)
        }
        .pbCard(padding: 16, fill: highlight ? PB.sun : PB.surface, radius: PB.rLG)
    }

    private func leaderboard(_ board: [TopicScore]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Topic leaderboard") {
                Text("Ranked by how often you get them right").font(.system(size: 13)).foregroundStyle(PB.muted)
            }
            ForEach(Array(board.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 12) {
                    Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(i == 0 ? PB.onSun : i == 1 ? .white : i == 2 ? PB.cobalt : PB.ink)
                        .background(Circle().fill(i == 0 ? PB.sun : i == 1 ? PB.cobalt : i == 2 ? PB.cobaltSoft : PB.surface))
                    Text(t.topic).font(.system(size: 14, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(PB.surface)
                            Capsule().fill(t.pct < 70 ? PB.red : PB.cobalt).frame(width: g.size.width * CGFloat(t.pct) / 100)
                        }
                    }
                    .frame(width: 160, height: 8)
                    Text("\(t.pct)%").font(.system(size: 13, weight: .bold, design: .monospaced)).frame(width: 50, alignment: .trailing)
                    Text("\(t.right)/\(t.total)").font(.system(size: 12)).foregroundStyle(PB.muted).frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { if i < board.count - 1 { Rectangle().fill(PB.line).frame(height: 1) } }
            }
        }
        .pbCard()
    }

    private func learnMore(_ weak: [TopicScore]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Learn more", count: "\(weak.count)")
            if weak.isEmpty {
                Text("Everything is at 70% or better. Keep it up.").font(.system(size: 13)).foregroundStyle(PB.cobalt)
            }
            ForEach(weak) { w in
                let words = w.topic.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 3 }
                let session = tasks.first { t in !t.isBreak && words.contains { t.title.lowercased().contains($0) } }
                let section: (Doc, String)? = {
                    for d in docs { for line in d.body.components(separatedBy: "\n") where line.hasPrefix("## ") {
                        let h = String(line.dropFirst(3)); if words.contains(where: { h.lowercased().contains($0) }) { return (d, h) }
                    } }
                    return nil
                }()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(w.topic).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(w.pct)%").font(.system(size: 11, weight: .bold)).foregroundStyle(PB.red)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 8).fill(PB.redSoft))
                    }
                    FlowLayout(spacing: 8) {
                        if let (d, h) = section { RefChip(ref: DocRef(docId: d.id, heading: h), doc: d) }
                        if let s = session {
                            Button("Session") { app.gotoSession(s) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                            Button("Quiz again") { app.quizSessionID = s.id }.buttonStyle(PillButtonStyle(compact: true))
                        }
                    }
                    if let s = session, !s.videos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(s.videos.prefix(2)) { VideoThumb(video: $0) } } }
                    }
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
            }
        }
        .pbCard()
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "History")
            ForEach(attempts.prefix(20)) { a in
                Button { app.reviewQuizID = a.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.topic).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(a.createdAt.pbFull + (a.source == "claude-code" ? " · Claude Code" : "")).font(.system(size: 12)).foregroundStyle(PB.muted)
                        }
                        Spacer()
                        Text("\(a.score)/\(a.total)").font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(PB.line).frame(height: 1) }
            }
        }
        .pbCard()
    }
}
