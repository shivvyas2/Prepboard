import Foundation

/// Quiz generation and YouTube video discovery.
/// On a Mac with Claude Code connected, this uses the user's own Claude Code (`claude -p`);
/// everywhere else it calls the `prep-chat` Supabase Edge Function.
enum Learning {
    struct QuizPayload: Codable { let topic: String; let questions: [Question] }
    struct Question: Codable { let question: String; let options: [String]; let answer: Int; let explanation: String; let topic: String }
    struct VideoPayload: Codable { let url: String?; let id: String?; let title: String; let channel: String; let why: String }

    private struct QuizRequest: Encodable { let mode = "quiz"; let topic: String; let material: String; let count: Int; let now: String; let timezone: String }
    private struct QuizResponse: Decodable { let quiz: QuizPayload?; let error: String? }
    private struct VideosRequest: Encodable { let mode = "videos"; let topic: String; let context: String; let now: String; let timezone: String }
    private struct VideosResponse: Decodable { let videos: [VideoPayload]?; let error: String? }

    enum Failure: LocalizedError {
        case unavailable, message(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Connect Claude Code (Profile) or your Supabase account to generate quizzes and find videos."
            case .message(let m): m
            }
        }
    }

    /// The study material behind a session: the linked guide sections.
    @MainActor
    static func material(for task: PrepTask, docs: [Doc]) -> String {
        let byId = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })
        return task.refs.compactMap { ref -> String? in
            guard let d = byId[ref.docId] else { return nil }
            return "### \(d.title)\(ref.heading.isEmpty ? "" : " › \(ref.heading)")\n" + section(of: d.body, heading: ref.heading)
        }.joined(separator: "\n\n").prefix(40_000).description
    }

    static func section(of body: String, heading: String) -> String {
        guard !heading.isEmpty else { return body }
        let lines = body.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading }) else { return body }
        let j = lines[(i + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
        return lines[i..<j].joined(separator: "\n")
    }

    // MARK: quiz

    @MainActor
    static func quiz(topic: String, material: String, claude: AnyObject?, cloud: Cloud) async throws -> (QuizPayload, String) {
        #if os(macOS)
        if let claude = claude as? ClaudeCode, claude.isReady {
            let prompt = """
            Write a 6-question multiple-choice interview-prep quiz on: \(topic)
            Test understanding (why/how/trade-offs, predicting behavior, spotting bugs), not trivia. Each question has exactly 4 plausible options and one correct answer; vary the correct index.
            Study material:
            \(material.isEmpty ? "(none — use standard knowledge)" : material)

            Reply with ONLY a JSON object, no prose and no code fences:
            {"topic": "...", "questions": [{"question": "...", "options": ["A","B","C","D"], "answer": 0, "explanation": "1-3 sentences", "topic": "short sub-topic"}]}
            """
            let payload: QuizPayload = try await claude.runJSON(prompt, tools: "Read")
            return (validated(payload), "claude-code")
        }
        #endif
        guard cloud.configured else { throw Failure.unavailable }
        let res: QuizResponse = try await cloud.invoke(QuizRequest(topic: topic, material: material, count: 6,
                                                                   now: DateCoding.string(.now), timezone: TimeZone.current.identifier))
        if let e = res.error { throw Failure.message(e) }
        guard let q = res.quiz else { throw Failure.message("No quiz came back. Try again.") }
        return (validated(q), "cloud")
    }

    private static func validated(_ q: QuizPayload) -> QuizPayload {
        QuizPayload(topic: q.topic, questions: q.questions.filter { $0.options.count == 4 && (0..<4).contains($0.answer) })
    }

    // MARK: videos

    @MainActor
    static func videos(topic: String, context: String, claude: AnyObject?, cloud: Cloud) async throws -> [Video] {
        var raw: [VideoPayload] = []
        #if os(macOS)
        if let claude = claude as? ClaudeCode, claude.isReady {
            let prompt = """
            Use web search to find 3-4 high-quality YouTube videos that explain: \(topic)
            Context: \(context)
            Prefer clear explanations from reputable channels. Only include URLs you actually found.
            Reply with ONLY a JSON array, no prose and no code fences:
            [{"url": "https://www.youtube.com/watch?v=...", "title": "...", "channel": "...", "why": "one sentence on why it helps"}]
            """
            raw = try await claude.runJSON(prompt, tools: "WebSearch WebFetch")
        }
        #endif
        if raw.isEmpty {
            guard cloud.configured else { throw Failure.unavailable }
            let res: VideosResponse = try await cloud.invoke(VideosRequest(topic: topic, context: context,
                                                                           now: DateCoding.string(.now), timezone: TimeZone.current.identifier))
            if let e = res.error { throw Failure.message(e) }
            raw = res.videos ?? []
        }
        var seen = Set<String>()
        return raw.compactMap { v in
            guard let id = v.id ?? v.url.flatMap(youtubeID), !seen.contains(id) else { return nil }
            seen.insert(id)
            return Video(id: id, title: v.title, channel: v.channel, why: v.why)
        }
    }

    static func youtubeID(_ s: String) -> String? {
        guard let u = URLComponents(string: s), let host = u.host else { return nil }
        if host == "youtu.be" { return String(u.path.dropFirst().prefix(11)).nilIfEmpty }
        guard host.hasSuffix("youtube.com") else { return nil }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return String(v.prefix(11)) }
        let parts = u.path.split(separator: "/")
        if parts.count >= 2, ["embed", "shorts", "live"].contains(String(parts[0])) { return String(parts[1].prefix(11)) }
        return nil
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

/// The planner conversation when it runs on the user's own Claude Code (same rules as the server planner).
enum PlannerPrompt {
    static func rules(now: String, timezone: String) -> String {
        """
        You are the planner inside PrepBoard, an interview-prep app. The user is starting preparation for something new.
        Current time: \(now) (user's timezone: \(timezone)).
        Have a short, friendly conversation, asking at most one or two questions per message, to learn: the role (company, title, ideally the job posting), the interview date/time/format, their background and weak spots, and how many hours per day they can prepare. Infer what you can from what they paste.
        When you know enough, reply with ONLY a JSON object in a ```json fenced block:
        {"summary": "2-3 sentences to the user", "role": {"company": "", "title": "", "team": "", "location": "", "link": "", "interview_at": "ISO 8601 with offset or empty", "interview_note": "", "notes": "", "stage": "Saved|Applied|Recruiter|Technical|Onsite|Offer"},
         "docs": [{"key": "slug", "title": "", "headings": ["4-8 section headings"]}],
         "sessions": [{"title": "", "start": "ISO 8601 with offset", "end": "ISO 8601 with offset", "kind": "study|practice|mock|review|logistics|break", "refs": [{"doc_key": "", "heading": "one of that doc's headings or empty"}]}]}
        Plan rules: sessions from the next sensible slot until shortly before the interview, respecting daily hours, 30-150 minute blocks, meal breaks, done by ~22:00, fundamentals first, mocks in the middle, light last hours. 4-6 docs tailored to this role.
        Otherwise reply in plain text with your next short question. Do not use Markdown headers.
        """
    }

    static func docPrompt(role: Plan.Role, doc: Plan.Doc) -> String {
        """
        Write a concise, practical interview study guide in Markdown.
        Role: \(role.company) — \(role.title). Interview: \(role.interview_at) · \(role.interview_note). Notes: \(role.notes)
        Title: \(doc.title)
        Start with a one-paragraph overview, then one "## " section per heading below, verbatim and in order:
        \(doc.headings.map { "- \($0)" }.joined(separator: "\n"))
        Prefer checklists, likely interview questions with crisp answer outlines, and short code samples where relevant. 400-900 words. Output only the guide.
        """
    }

    /// Finds a plan JSON object in a reply (fenced or bare).
    static func plan(in text: String) -> Plan? {
        var src = text
        if let f = text.range(of: "```json") ?? text.range(of: "```"), let e = text.range(of: "```", range: f.upperBound..<text.endIndex) {
            src = String(text[f.upperBound..<e.lowerBound])
        }
        guard let o = src.firstIndex(of: "{"), let c = src.lastIndex(of: "}"), o < c else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: Data(src[o...c].utf8))
    }
}

#if os(macOS)
extension ClaudeCode {
    /// Runs a headless Claude Code turn and returns the reply text and session id (pass it back to continue the conversation).
    func runText(_ prompt: String, tools: String, resume: String? = nil) async throws -> (text: String, session: String?) {
        let dir = workingDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
        var cmd = "cd '\(dir)' && claude -p --output-format json --allowedTools \(tools)"
        if let resume, resume.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) { cmd += " --resume \(resume)" }
        let out = await Self.shell(cmd + " 2>/dev/null", stdin: prompt)
        guard let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else {
            throw Learning.Failure.message("Claude Code didn't respond. Check it works in Terminal.")
        }
        if obj["is_error"] as? Bool == true { throw Learning.Failure.message((obj["result"] as? String) ?? "Claude Code returned an error.") }
        return ((obj["result"] as? String) ?? "", obj["session_id"] as? String)
    }

    /// Runs a one-shot headless Claude Code prompt and decodes the JSON in its reply.
    func runJSON<T: Decodable>(_ prompt: String, tools: String) async throws -> T {
        let dir = workingDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(dir)' && claude -p --output-format json --allowedTools \(tools) 2>/dev/null"
        let out = await Self.shell(cmd, stdin: prompt)
        guard let start = out.firstIndex(of: "{"), let envelope = out[start...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: Data(envelope)) as? [String: Any] else {
            throw Learning.Failure.message("Claude Code didn't respond. Check it works in Terminal. \(out.suffix(200))")
        }
        if obj["is_error"] as? Bool == true { throw Learning.Failure.message((obj["result"] as? String) ?? "Claude Code returned an error.") }
        let text = (obj["result"] as? String) ?? ""
        // Pull the first top-level JSON value out of the reply (tolerates stray prose or code fences).
        guard let open = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let close = text.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close else {
            throw Learning.Failure.message("Claude Code's reply wasn't JSON.")
        }
        do { return try JSONDecoder().decode(T.self, from: Data(text[open...close].utf8)) }
        catch { throw Learning.Failure.message("Couldn't read Claude Code's reply: \(error.localizedDescription)") }
    }
}
#endif
