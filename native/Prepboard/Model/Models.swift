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
    var kind: String        // "bank" (from the Answer Bank) | "drafted" (job-specific, Claude wrote it) | "needs_you"
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
    /// Every required answer is filled in and nothing is left for the user.
    var canSubmit: Bool {
        answers.allSatisfy { $0.kind != "needs_you" && (!$0.required || !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
}

/// Facts the application forms ask for; legal answers come only from here, never drafted.
struct AnswerBank: Codable, Equatable {
    var fullName = "", email = "", phone = "", city = ""
    var linkedin = "", github = "", portfolio = ""
    var workAuthorization = ""      // e.g. "Authorized to work in the US (F-1 OPT)"
    var needsSponsorship = ""       // "Yes" | "No" | ""
    var startDate = ""
    var relocation = ""             // "Yes" | "No" | "Open to it"
    var salary = ""                 // "" = decline / leave blank
    var gender = "", race = "", veteran = "", disability = ""   // "" = decline to answer
    var saved: [String: String] = [:]   // reusable free-text answers keyed by question
    var isComplete: Bool { !fullName.isEmpty && !email.isEmpty && !phone.isEmpty && !workAuthorization.isEmpty && !needsSponsorship.isEmpty }

    init() {}
    /// Tolerates partial JSON (the table default is `{}`), so missing keys stay empty instead of failing the sync.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        fullName = s(.fullName); email = s(.email); phone = s(.phone); city = s(.city)
        linkedin = s(.linkedin); github = s(.github); portfolio = s(.portfolio)
        workAuthorization = s(.workAuthorization); needsSponsorship = s(.needsSponsorship); startDate = s(.startDate)
        relocation = s(.relocation); salary = s(.salary)
        gender = s(.gender); race = s(.race); veteran = s(.veteran); disability = s(.disability)
        saved = (try? c.decodeIfPresent([String: String].self, forKey: .saved)) ?? [:]
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
