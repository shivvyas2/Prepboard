import Foundation
import SwiftData

enum Stage: String, CaseIterable, Identifiable, Codable {
    case saved = "Saved", applied = "Applied", recruiter = "Recruiter", technical = "Technical"
    case onsite = "Onsite", offer = "Offer", closed = "Closed"
    var id: String { rawValue }
    var index: Int { Stage.allCases.firstIndex(of: self)! }
    var isHot: Bool { self == .technical || self == .onsite }
}

@Model
final class Role {
    @Attribute(.unique) var id: String
    var company: String
    var title: String
    var team: String
    var location: String
    var roleNumber: String
    var salary: String
    var link: String
    var stageRaw: String
    var interviewAt: Date?
    var interviewNote: String
    var notes: String
    var createdAt: Date
    // Filled by job sync (Mac) or by hand.
    var recruiter: String = ""
    var recruiterEmail: String = ""
    var source: String = ""             // "" (added by hand), "gmail" or "linkedin"
    var appliedAt: Date?
    var activity: String = ""           // Markdown lines, newest last: "- 2026-10-09 · Gmail · Recruiter reached out"
    var resumeVariant: String = ""      // .tex variant sent (file name, no extension), e.g. "Shiv-Vyas-Apple-ScreenSharing-SDE"

    init(id: String = "role-" + UUID().uuidString.prefix(8).lowercased(),
         company: String = "New company", title: String = "Role title", team: String = "",
         location: String = "", roleNumber: String = "", salary: String = "", link: String = "",
         stage: Stage = .saved, interviewAt: Date? = nil, interviewNote: String = "",
         notes: String = "", createdAt: Date = .now) {
        self.id = id; self.company = company; self.title = title; self.team = team
        self.location = location; self.roleNumber = roleNumber; self.salary = salary; self.link = link
        self.stageRaw = stage.rawValue; self.interviewAt = interviewAt; self.interviewNote = interviewNote
        self.notes = notes; self.createdAt = createdAt
    }

    var stage: Stage {
        get { Stage(rawValue: stageRaw) ?? .saved }
        set { stageRaw = newValue.rawValue }
    }
}

@Model
final class Doc {
    @Attribute(.unique) var id: String
    var roleId: String
    var title: String
    var body: String
    var tags: [String]
    var updatedAt: Date
    var order: Int
    var fileType: String = "md"        // "md" or "pdf"
    var filePath: String = ""          // storage path for PDFs: <user id>/<doc id>.pdf
    var isPDF: Bool { fileType == "pdf" }

    init(id: String = "doc-" + UUID().uuidString.prefix(8).lowercased(), roleId: String = "",
         title: String = "", body: String = "", tags: [String] = [], updatedAt: Date = .now, order: Int = 999) {
        self.id = id; self.roleId = roleId; self.title = title; self.body = body
        self.tags = tags; self.updatedAt = updatedAt; self.order = order
    }
}

enum SessionKind: String, CaseIterable, Identifiable, Codable {
    case study, practice, mock, review, logistics, `break`
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A link from a session to a document, optionally to one `##` section of it.
struct DocRef: Hashable {
    let docId: String
    let heading: String
    init(docId: String, heading: String = "") { self.docId = docId; self.heading = heading }
    init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        docId = String(first); heading = parts.count > 1 ? String(parts[1]) : ""
    }
    var encoded: String { "\(docId)|\(heading)" }
}

/// A time-blocked prep session on the timeline.
@Model
final class PrepTask {
    @Attribute(.unique) var id: String
    var roleId: String
    var title: String
    var start: Date
    var end: Date
    var kindRaw: String
    var refsRaw: [String]
    var done: Bool
    var videosRaw: [String] = []

    init(id: String = "task-" + UUID().uuidString.prefix(8).lowercased(), roleId: String, title: String,
         start: Date, end: Date, kind: SessionKind = .study, refs: [DocRef] = [], done: Bool = false) {
        self.id = id; self.roleId = roleId; self.title = title; self.start = start; self.end = end
        self.kindRaw = kind.rawValue; self.refsRaw = refs.map(\.encoded); self.done = done
    }

    var kind: SessionKind {
        get { SessionKind(rawValue: kindRaw) ?? .study }
        set { kindRaw = newValue.rawValue }
    }
    var refs: [DocRef] {
        get { refsRaw.compactMap(DocRef.init(encoded:)) }
        set { refsRaw = newValue.map(\.encoded) }
    }
    var videos: [Video] {
        get { videosRaw.compactMap { s in
            let p = s.components(separatedBy: "\u{1F}")
            return p.count == 4 ? Video(id: p[0], title: p[1], channel: p[2], why: p[3]) : nil
        } }
        set { videosRaw = newValue.map { [$0.id, $0.title, $0.channel, $0.why].joined(separator: "\u{1F}") } }
    }
    var isBreak: Bool { kind == .break }
    var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }

    enum Status { case done, current, missed, upcoming }
    func status(at now: Date = .now) -> Status {
        if done { return .done }
        if start <= now && now < end { return .current }
        return end <= now ? .missed : .upcoming
    }
}

struct Video: Codable, Hashable, Identifiable {
    var id: String          // YouTube video id
    var title: String
    var channel: String
    var why: String
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
}

struct QuizItem: Codable, Hashable {
    var question: String
    var options: [String]
    var answer: Int
    var chosen: Int?
    var explanation: String
    var topic: String
    var isCorrect: Bool { chosen == answer }
}

/// One completed quiz (feeds the Scores leaderboard and weak topics).
@Model
final class QuizAttempt {
    @Attribute(.unique) var id: String
    var roleId: String
    var sessionId: String
    var topic: String
    var score: Int
    var total: Int
    var itemsJSON: Data
    var weakTopics: [String]
    var source: String
    var createdAt: Date

    init(id: String = "quiz-" + UUID().uuidString.prefix(8).lowercased(), roleId: String, sessionId: String, topic: String,
         items: [QuizItem], source: String, createdAt: Date = .now) {
        self.id = id; self.roleId = roleId; self.sessionId = sessionId; self.topic = topic
        self.score = items.filter(\.isCorrect).count
        self.total = items.count
        self.itemsJSON = (try? JSONEncoder().encode(items)) ?? Data()
        self.weakTopics = Array(Set(items.filter { !$0.isCorrect }.map(\.topic))).sorted()
        self.source = source
        self.createdAt = createdAt
    }

    var items: [QuizItem] { (try? JSONDecoder().decode([QuizItem].self, from: itemsJSON)) ?? [] }
}

extension Array where Element == PrepTask {
    func progress(for roleId: String) -> Double {
        let mine = filter { $0.roleId == roleId && !$0.isBreak }
        guard !mine.isEmpty else { return 0 }
        return Double(mine.filter(\.done).count) / Double(mine.count)
    }
}

/// A LeetCode/CoderPad-style practice problem with the user's code per language (synced as pb_problems).
@Model
final class Problem {
    @Attribute(.unique) var id: String
    var roleId: String
    var title: String
    var difficulty: String          // Easy | Medium | Hard
    var topics: [String]
    var statement: String           // Markdown
    var starters: [String: String]  // language → starter code with test harness
    var code: [String: String]      // language → the user's code
    var language: String
    var solved: Bool
    var notes: String
    var videos: [Video] = []        // YouTube explanations for this problem
    var createdAt: Date
    var updatedAt: Date

    init(id: String = "prob-" + UUID().uuidString.prefix(8).lowercased(), roleId: String = "", title: String, difficulty: String = "Medium",
         topics: [String] = [], statement: String, starters: [String: String], code: [String: String] = [:], language: String = "swift",
         solved: Bool = false, notes: String = "", createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.roleId = roleId; self.title = title; self.difficulty = difficulty; self.topics = topics
        self.statement = statement; self.starters = starters; self.code = code; self.language = language
        self.solved = solved; self.notes = notes; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    func currentCode(_ lang: String) -> String { code[lang] ?? starters[lang] ?? "" }
}

// MARK: - Job hunt

/// Where a discovered job is in the hunt pipeline.
enum LeadStatus: String, CaseIterable, Codable {
    case new, tailoring, ready, needsYou = "needs_you", submitting, submitted, skipped, failed
}

/// One JD term and whether the tailored variant covers it.
struct Coverage: Codable, Hashable { var term: String; var covered: Bool }

/// One planned answer for an application form.
struct FormAnswer: Codable, Hashable {
    var question: String
    var answer: String
    var kind: String        // "bank" (from the Answer Bank) | "drafted" (job-specific, Claude wrote it) | "yours" (typed by the user)
                            // | "choice" (the user's per-role choice, see `Lead.Choice`) | "needs_you"
                            // | "suggested" (Claude's suggestion for a question a stopped form asked; waits for the user's approval)
    var required: Bool
}

/// One job the hunt found; tailored on the Mac, reviewed anywhere, submitted by the Mac (synced as pb_leads).
@Model
final class Lead {
    @Attribute(.unique) var id: String
    var company: String
    var title: String
    var location: String
    var link: String
    var roleNumber: String          // posting id if visible, else ""
    var source: String              // "linkedin-rec" | "linkedin-search" | "careers"
    var jd: String                  // full job description text
    var score: Int                  // 0-100
    var scoreReason: String
    var statusRaw: String
    var baseVariant: String         // base .tex (no extension), "" until tailored
    var baseReason: String
    var variantName: String         // generated .tex (no extension), "" until tailored
    var pdfDocId: String            // Doc id of the built PDF, "" until built
    var coverageJSON: Data          // [Coverage]
    var answersJSON: Data           // [FormAnswer]
    var flagged: String             // newline-separated questions / blocks that need the user
    var reason: String              // last status reason or error
    var roleId: String              // Role created on submit, else ""
    var submitRequested: Bool       // set from any device; the Mac submits
    var foundAt: Date
    var updatedAt: Date

    init(id: String = "lead-" + UUID().uuidString.prefix(8).lowercased(), company: String = "", title: String = "",
         location: String = "", link: String = "", roleNumber: String = "", source: String = "", jd: String = "",
         score: Int = 0, scoreReason: String = "", status: LeadStatus = .new, foundAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.company = company; self.title = title; self.location = location; self.link = link
        self.roleNumber = roleNumber; self.source = source; self.jd = jd; self.score = score; self.scoreReason = scoreReason
        self.statusRaw = status.rawValue; self.baseVariant = ""; self.baseReason = ""; self.variantName = ""; self.pdfDocId = ""
        self.coverageJSON = Data(); self.answersJSON = Data(); self.flagged = ""; self.reason = ""; self.roleId = ""
        self.submitRequested = false; self.foundAt = foundAt; self.updatedAt = updatedAt
    }

    var status: LeadStatus {
        get { LeadStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }
    var coverage: [Coverage] {
        get { (try? JSONDecoder().decode([Coverage].self, from: coverageJSON)) ?? [] }
        set { coverageJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var answers: [FormAnswer] {
        get { (try? JSONDecoder().decode([FormAnswer].self, from: answersJSON)) ?? [] }
        set { answersJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    /// Every required answer is filled in and nothing is left for the user (no question unanswered, no suggestion unapproved).
    var canSubmit: Bool {
        answers.allSatisfy { !["needs_you", "suggested"].contains($0.kind) && (!$0.required || !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
    /// Suggestions waiting for the user's approval.
    var suggestedCount: Int { answers.filter { $0.kind == "suggested" }.count }
    /// Approves every suggestion as the user's own answer (what Submit then sends, and what the Answer Bank may remember).
    func approveSuggestions() {
        answers = answers.map { a in
            guard a.kind == "suggested" else { return a }
            var m = a; m.kind = "yours"; return m
        }
        updatedAt = .now
    }
}

/// Facts the application forms ask for; legal answers come only from here, never drafted.
struct AnswerBank: Codable, Equatable {
    var fullName = "", email = "", phone = "", city = ""
    var linkedin = "", github = "", portfolio = ""
    var resumeLink = ""             // shared when a form asks for a résumé link; "" = use the portfolio link
    var workAuthorization = ""      // e.g. "Authorized to work in the US (F-1 OPT)"
    var needsSponsorship = ""       // "Yes" | "No" | ""; "Yes" also skips roles that say they don't sponsor
    var citizenship = ""            // citizenship / immigration status, e.g. "Indian citizen, F-1 OPT"; "" = ask me each time
    var startDate = ""
    var relocation = ""             // "Yes" | "No" | "Open to it"
    var salary = ""                 // "" = decline / leave blank
    var gender = "", race = "", veteran = "", disability = ""   // "" = decline to answer
    // Education and work history, filled from the résumé (and LinkedIn) by "Fill from résumé".
    var school = "", degree = "", major = "", graduation = "", gpa = ""
    var currentEmployer = "", currentTitle = "", yearsExperience = ""
    var education = "", employment = ""   // one entry per line, most recent first
    var referralSource = ""         // "How did you hear about us?"
    var saved: [String: String] = [:]   // reusable free-text answers keyed by question
    var isComplete: Bool { !fullName.isEmpty && !email.isEmpty && !phone.isEmpty && !workAuthorization.isEmpty && !needsSponsorship.isEmpty }

    init() {}
    /// Tolerates partial JSON (the table default is `{}`), so missing keys stay empty instead of failing the sync.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        fullName = s(.fullName); email = s(.email); phone = s(.phone); city = s(.city)
        linkedin = s(.linkedin); github = s(.github); portfolio = s(.portfolio); resumeLink = s(.resumeLink)
        workAuthorization = s(.workAuthorization); needsSponsorship = s(.needsSponsorship); citizenship = s(.citizenship)
        startDate = s(.startDate); relocation = s(.relocation); salary = s(.salary)
        gender = s(.gender); race = s(.race); veteran = s(.veteran); disability = s(.disability)
        school = s(.school); degree = s(.degree); major = s(.major); graduation = s(.graduation); gpa = s(.gpa)
        currentEmployer = s(.currentEmployer); currentTitle = s(.currentTitle); yearsExperience = s(.yearsExperience)
        education = s(.education); employment = s(.employment); referralSource = s(.referralSource)
        saved = (try? c.decodeIfPresent([String: String].self, forKey: .saved)) ?? [:]
    }

    /// Fields whose emptiness stops an application that asks for them (EEO fields decline instead, salary stays blank).
    static let stopping: [(label: String, field: WritableKeyPath<AnswerBank, String>)] = [
        ("name", \.fullName), ("email", \.email), ("phone", \.phone), ("work authorization", \.workAuthorization),
        ("sponsorship", \.needsSponsorship), ("citizenship", \.citizenship), ("start date", \.startDate), ("relocation", \.relocation)]
    var missingStopping: [String] { Self.stopping.filter { self[keyPath: $0.field].trimmingCharacters(in: .whitespaces).isEmpty }.map(\.label) }

    // MARK: matching form questions

    /// What an empty bank field means for a question that asks for it.
    enum WhenEmpty { case ask, decline, blank, portfolio }
    struct Rule {
        let field: WritableKeyPath<AnswerBank, String>
        let legal: Bool          // legal answers come only from the bank, never drafted
        let whenEmpty: WhenEmpty
    }

    /// Lower case, letters and digits only, single spaces, so "Major / Field of study *" and "major field of study" match.
    static func normalized(_ question: String) -> String {
        String(question.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    /// The bank field a form question asks for, if any. Order matters: the first matching rule wins.
    static func rule(for question: String) -> Rule? {
        let q = question.lowercased()
        func has(_ words: String...) -> Bool {
            words.contains { q.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0), options: .regularExpression) != nil }
        }
        func legal(_ f: WritableKeyPath<AnswerBank, String>, _ e: WhenEmpty = .ask) -> Rule { Rule(field: f, legal: true, whenEmpty: e) }
        func plain(_ f: WritableKeyPath<AnswerBank, String>) -> Rule { Rule(field: f, legal: false, whenEmpty: .ask) }
        if has("citizen", "immigration", "nationality") { return legal(\.citizenship) }
        if has("sponsor", "visa") { return legal(\.needsSponsorship) }
        if has("authoriz", "authoris", "legally", "eligible to work", "right to work", "work permit") { return legal(\.workAuthorization) }
        if has("salary", "compensation", "pay expectation") { return legal(\.salary, .blank) }
        if has("gender", "sex") { return legal(\.gender, .decline) }
        if has("race", "ethnic", "hispanic", "latino") { return legal(\.race, .decline) }
        if has("veteran", "military") { return legal(\.veteran, .decline) }
        if has("disabilit") { return legal(\.disability, .decline) }
        if has("relocat") { return legal(\.relocation) }
        if has("start date", "available to start", "availability", "earliest", "notice period") { return legal(\.startDate) }
        if has("hear about", "hear of", "how did you find", "referral source", "source of application") { return plain(\.referralSource) }
        if has("employment history", "work history", "previous employers", "past employers") { return plain(\.employment) }
        if has("education history", "educational background", "education background") { return plain(\.education) }
        if has("graduat") { return plain(\.graduation) }
        if has("gpa", "grade point") { return plain(\.gpa) }
        if has("field of study", "area of study", "major"), !has("accomplish", "achievement", "project", "challenge") { return plain(\.major) }
        if has("degree") { return plain(\.degree) }
        if has("school", "university", "college", "institution") { return plain(\.school) }
        if has("current employer", "current company", "most recent employer", "most recent company", "present employer") { return plain(\.currentEmployer) }
        if has("current title", "current job title", "current role", "current position", "most recent title", "most recent job title") { return plain(\.currentTitle) }
        if has("years of experience", "years of professional", "years of relevant", "years of work"), !has("with") { return plain(\.yearsExperience) }
        if has("resume", "résumé", "cv"), has("link", "url") { return Rule(field: \.resumeLink, legal: false, whenEmpty: .portfolio) }
        if has("linkedin") { return plain(\.linkedin) }
        if has("github") { return plain(\.github) }
        if has("portfolio", "website", "personal site") { return plain(\.portfolio) }
        if has("email") { return plain(\.email) }
        if has("phone", "telephone", "mobile number") { return plain(\.phone) }
        if has("full name", "your name", "first name", "last name", "legal name") { return plain(\.fullName) }
        if has("city", "where are you located", "current location", "where do you live") { return plain(\.city) }
        return nil
    }

    /// The saved answer for a question, matched on its normalized text.
    func savedAnswer(for question: String) -> String? {
        let key = Self.normalized(question)
        guard !key.isEmpty else { return nil }
        return saved.first { Self.normalized($0.key) == key }?.value
    }

    /// The bank's answer for a form question, if the bank covers it. `legal` answers always come from the bank; the others keep a
    /// drafted answer when the bank is empty. An empty citizenship field leaves the question to the user, as before.
    func answer(for question: String) -> (answer: String, kind: String, legal: Bool)? {
        if let rule = Self.rule(for: question) {
            let value = self[keyPath: rule.field]
            if !value.isEmpty { return (value, "bank", rule.legal) }
            if let saved = savedAnswer(for: question), !saved.isEmpty { return (saved, "bank", rule.legal) }
            switch rule.whenEmpty {
            case .decline: return ("Decline to self-identify", "bank", rule.legal)
            case .blank: return ("", "bank", rule.legal)
            case .portfolio: return portfolio.isEmpty ? ("", "needs_you", rule.legal) : (portfolio, "bank", rule.legal)
            case .ask: return ("", "needs_you", rule.legal)
            }
        }
        if let saved = savedAnswer(for: question) { return (saved, "bank", false) }
        return nil
    }

    /// Fills planned answers from the bank: legal questions always, the rest when the bank has a value.
    func merge(_ answers: [FormAnswer]) -> [FormAnswer] {
        answers.map { a in
            if a.kind == "yours" || a.kind == "choice" { return a }   // the user's own, for this posting
            guard let b = answer(for: a.question) else { return a }
            if !b.legal, b.answer.isEmpty, ["drafted", "suggested"].contains(a.kind), !a.answer.isEmpty { return a }
            var m = a; m.answer = b.answer; m.kind = b.kind
            return m
        }
    }

    /// Questions that belong to one posting ("Why Google?", a cover letter): never saved for reuse.
    static func isPostingSpecific(_ question: String, company: String) -> Bool {
        let q = normalized(question), c = normalized(company)
        if !c.isEmpty, q.contains(c) { return true }
        return ["why", "this role", "this position", "this job", "this company", "this team", "work here", "join us", "interest you",
                "cover letter", "excites you", "about us"].contains { q.contains($0) }
    }

    /// Learns from answers the user typed on a form ("yours"): an empty bank field takes the answer; a question no field covers is
    /// saved for next time. Filled bank fields are never overwritten here, and posting-specific questions are never saved.
    func remembering(_ answers: [FormAnswer], company: String) -> AnswerBank {
        var bank = self
        for a in answers where a.kind == "yours" {
            let value = a.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !Self.isPostingSpecific(a.question, company: company) else { continue }
            if let rule = Self.rule(for: a.question) {
                if bank[keyPath: rule.field].trimmingCharacters(in: .whitespaces).isEmpty { bank[keyPath: rule.field] = value }
            } else {
                let key = Self.normalized(a.question)
                bank.saved = bank.saved.filter { Self.normalized($0.key) != key }
                bank.saved[a.question.trimmingCharacters(in: .whitespacesAndNewlines)] = value
            }
        }
        return bank
    }
}

extension Lead {
    /// Per-role decisions the user makes on the card; stored as `choice` answers so they sync with the lead and override the bank.
    enum Choice: String, CaseIterable {
        case relocate = "Willing to relocate for this role"
        case onsite = "Willing to work onsite or hybrid as this posting describes"
        case salary = "Salary expectation for this role"
        case startDate = "Earliest start date for this role"
    }

    func choice(_ c: Choice) -> String? {
        answers.first { $0.kind == "choice" && $0.question == c.rawValue }.map(\.answer).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "" removes the choice, so the Answer Bank's default applies again.
    func setChoice(_ c: Choice, _ value: String) {
        var all = answers.filter { !($0.kind == "choice" && $0.question == c.rawValue) }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { all.append(FormAnswer(question: c.rawValue, answer: v, kind: "choice", required: false)) }
        answers = all
        updatedAt = .now
    }

    /// The bank with this role's choices applied: what Submit and the form answers use.
    func bank(_ base: AnswerBank) -> AnswerBank {
        var b = base
        if let v = choice(.relocate) { b.relocation = v }
        if let v = choice(.salary) { b.salary = v }
        if let v = choice(.startDate) { b.startDate = v }
        return b
    }

    // MARK: visa sponsorship

    /// The phrase in a job description that rules out someone who needs visa sponsorship, or nil.
    static func sponsorshipBlock(jd: String) -> String? {
        let patterns = [
            #"\b(?:not|unable to|cannot|can't|won't|will not|do not|does not|don't|doesn't)\s+(?:be able to\s+)?(?:offer\s+|provide\s+|support\s+)?(?:visa\s+|employment\s+|immigration\s+)?sponsor"#,
            #"\bno\s+(?:visa\s+|employment\s+|immigration\s+)?sponsorship"#,
            #"\bnot\s+(?:now\s+or\s+in\s+the\s+future\s+)?require\s+(?:visa\s+|employment\s+|immigration\s+)?sponsorship"#,
            #"\bwithout\s+(?:the\s+need\s+for\s+)?(?:current\s+or\s+future\s+)?(?:visa\s+|employment\s+|immigration\s+)?sponsorship"#,
            #"\bsponsorship\s+(?:is\s+)?(?:not|un)\s*(?:available|offered|provided)"#,
            #"\bmust\s+be\s+an?\s+(?:u\.?s\.?|united\s+states)\s+citizen"#,
            #"\b(?:u\.?s\.?|united\s+states)\s+citizen(?:s|ship)?\s+(?:only|is\s+required|required)"#,
            #"\b(?:security|secret|ts/sci|top\s+secret)\s+clearance"#,
            #"\bgreen\s+card\s+holders?\s+only"#,
        ]
        for p in patterns {
            if let r = jd.range(of: p, options: [.regularExpression, .caseInsensitive]) { return String(jd[r]) }
        }
        return nil
    }
    static let sponsorshipSkipPrefix = "Doesn't sponsor visas"

    /// Re-judges every role not yet submitted after the sponsorship toggle changes: with `needs`, a posting that rules out sponsorship
    /// is skipped; without it, roles skipped only for that come back. Returns how many changed.
    @discardableResult
    static func applySponsorship(_ needs: Bool, to leads: [Lead]) -> Int {
        var changed = 0
        for lead in leads where ![.submitted, .submitting, .tailoring].contains(lead.status) {
            if needs, lead.status != .skipped, let phrase = sponsorshipBlock(jd: lead.jd) {
                lead.status = .skipped; lead.submitRequested = false
                lead.reason = "\(sponsorshipSkipPrefix): \u{201C}\(phrase)\u{201D}"; lead.updatedAt = .now; changed += 1
            } else if !needs, lead.status == .skipped, lead.reason.hasPrefix(sponsorshipSkipPrefix) {
                lead.status = lead.variantName.isEmpty ? .new : .ready; lead.reason = ""; lead.updatedAt = .now; changed += 1
            }
        }
        return changed
    }

    /// True when every line in `flagged` is a form question this lead now has an answer for, so nothing else (an honesty problem,
    /// a sign-in, a CAPTCHA) is waiting on the user.
    var onlyQuestionsFlagged: Bool {
        let answered = Set(answers.filter { $0.kind != "needs_you" && !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { AnswerBank.normalized($0.question) })
        let lines = flagged.split(separator: "\n").map { AnswerBank.normalized(String($0)) }.filter { !$0.isEmpty }
        if lines.isEmpty { return reason == Lead.fillAnswersReason }
        return lines.allSatisfy(answered.contains)
    }
    static let fillAnswersReason = "Fill in the remaining answers first"

    /// Re-fills waiting applications from the bank after it changes. A needs-you lead that was only waiting on questions the bank
    /// now answers goes back to ready (so keep applying can queue it); anything else stays with the user. Returns how many went back.
    @discardableResult
    static func applyBank(_ bank: AnswerBank, to leads: [Lead]) -> Int {
        var unblocked = 0
        for lead in leads where [.ready, .needsYou].contains(lead.status) && !lead.submitRequested {
            let merged = bank.merge(lead.answers)
            if merged != lead.answers { lead.answers = merged; lead.updatedAt = .now }
            if lead.status == .needsYou, lead.canSubmit, lead.onlyQuestionsFlagged {
                lead.status = .ready; lead.flagged = ""; lead.reason = "Your saved answers filled the remaining questions"; lead.updatedAt = .now
                unblocked += 1
            }
        }
        return unblocked
    }
}

/// The hunt's configuration and Answer Bank; one record with id "hunt" (synced as pb_hunt_settings).
@Model
final class HuntSettings {
    @Attribute(.unique) var id: String = "hunt"
    var regions: [String] = []          // "United States", "United States / New York"
    var companies: [String] = []        // "Apple" or "Apple | https://jobs.apple.com/..." (careers URL after " | ")
    var keywords: [String] = []         // "iOS Engineer", "Full Stack"
    var auto: Bool = false              // daily run on/off
    var runHour: Int = 8                // 0-23 local
    var minScore: Int = 60
    var dailyTailorLimit: Int = 30
    var dailySubmitLimit: Int = 30
    var resumeFolder: String            // Mac path; defaultResumeFolder until the user picks one
    var answersJSON: Data               // AnswerBank
    var updatedAt: Date

    static let defaultResumeFolder = NSHomeDirectory() + "/Documents/Career/Resumes (Downloads)"

    init() { resumeFolder = Self.defaultResumeFolder; answersJSON = Data(); updatedAt = .now }

    var answerBank: AnswerBank {
        get { (try? JSONDecoder().decode(AnswerBank.self, from: answersJSON)) ?? AnswerBank() }
        set { answersJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// The single settings record, inserted with defaults on first use.
    @MainActor
    static func current(_ context: ModelContext) -> HuntSettings {
        let hunt = "hunt"
        if let s = try? context.fetch(FetchDescriptor<HuntSettings>(predicate: #Predicate { $0.id == hunt })).first { return s }
        let s = HuntSettings()
        context.insert(s)
        return s
    }
}
