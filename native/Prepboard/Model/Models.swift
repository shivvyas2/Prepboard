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
            return p.count >= 4 ? Video(id: p[0], title: p[1], channel: p[2], why: p[3], keyPoints: p.count > 4 ? p[4] : "") : nil
        } }
        set { videosRaw = newValue.map { [$0.id, $0.title, $0.channel, $0.why, $0.keyPoints].joined(separator: "\u{1F}") } }
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
    /// What the video covers, as short points from its description and chapters: kept with the problem, so it reads offline.
    var keyPoints: String = ""

    init(id: String, title: String, channel: String, why: String, keyPoints: String = "") {
        self.id = id; self.title = title; self.channel = channel; self.why = why; self.keyPoints = keyPoints
    }
    /// Older rows have no keyPoints; they decode with "".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        channel = (try? c.decode(String.self, forKey: .channel)) ?? ""
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
        keyPoints = (try? c.decodeIfPresent(String.self, forKey: .keyPoints)) ?? ""
    }
    /// One YouTube playlist of these videos (YouTube builds it from the ids; it takes up to 50). In the YouTube app it can be saved
    /// to the library and downloaded as a whole with Premium. Nil when there are no videos.
    static func playlistURL(_ videos: [Video]) -> URL? {
        var seen = Set<String>()
        let ids = videos.map(\.id).filter { seen.insert($0).inserted }.prefix(50)
        guard !ids.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/watch_videos?video_ids=" + ids.joined(separator: ","))
    }
    /// The YouTube app when installed (where Premium's Download button lives), otherwise the web page.
    var youtubeAppURL: URL { URL(string: "youtube://watch?v=\(id)")! }
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

/// Commands from any device to the Mac that applies, and the Mac's status back. The Mac runs Claude Code; a phone only asks.
struct HuntRemote: Codable, Equatable {
    /// Set by any device: the Mac turns Keep applying on or off to match. nil = no request.
    var keepApplying: Bool?
    /// When a device last pressed "Find roles now" (ISO time); the Mac runs once for each new value.
    var runRequested = ""
    /// Written by the Mac: one line on what it is doing, when, and its real Keep applying state.
    var macStatus = "", macStatusAt = "", macPausedUntil = ""
    var macKeepApplying = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepApplying = try? c.decodeIfPresent(Bool.self, forKey: .keepApplying)
        runRequested = (try? c.decodeIfPresent(String.self, forKey: .runRequested)) ?? ""
        macStatus = (try? c.decodeIfPresent(String.self, forKey: .macStatus)) ?? ""
        macStatusAt = (try? c.decodeIfPresent(String.self, forKey: .macStatusAt)) ?? ""
        macPausedUntil = (try? c.decodeIfPresent(String.self, forKey: .macPausedUntil)) ?? ""
        macKeepApplying = (try? c.decodeIfPresent(Bool.self, forKey: .macKeepApplying)) ?? false
    }

    /// When the Mac last reported; nil if never.
    var macSeen: Date? { DateCoding.date(macStatusAt) }
    /// The Mac reported within the last 10 minutes (it reports at least every 5 while PrepBoard is open).
    func macOnline(now: Date = .now) -> Bool { macSeen.map { now.timeIntervalSince($0) < 600 } ?? false }
}

/// Facts the application forms ask for; legal answers come only from here, never drafted.
struct AnswerBank: Codable, Equatable {
    var fullName = "", email = "", phone = "", city = ""
    var linkedin = "", github = "", portfolio = ""
    var resumeLink = ""             // shared when a form asks for a résumé link; "" = use the portfolio link
    var workAuthorization = ""      // e.g. "Authorized to work in the US (F-1 OPT)"
    var needsSponsorship = ""       // "Yes" | "No" | ""; "Yes" also skips roles that say they don't sponsor
    var citizenship = ""            // citizenship / immigration status, e.g. "Indian citizen, F-1 OPT"; "" = ask me each time
    var visaStatus = ""             // VisaStatus raw value; once chosen, every immigration question is answered from it
    var citizenshipCountry = ""     // "Country of citizenship" / "Nationality"
    var eadExpiry = ""              // when the current work authorization (EAD) ends, e.g. "June 2028"
    var zipCode = "", state = "", country = ""   // address parts forms ask for; country "" = United States
    var pronouns = ""               // "" = leave blank / decline
    var relatives = ""              // companies where a relative works, one per line; "" = none
    var eeoExtra = ""               // transgender / sexual orientation questions; "" = decline to self-identify
    /// The phone's remote control for the Mac's hunt, riding on this synced record (no extra table needed).
    var remote = HuntRemote()
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
    var isComplete: Bool {
        !fullName.isEmpty && !email.isEmpty && !phone.isEmpty && (status != nil || !workAuthorization.isEmpty && !needsSponsorship.isEmpty)
    }
    var status: VisaStatus? { VisaStatus(rawValue: visaStatus) }

    /// A status typed into the old free-text fields ("Authorized to work in the US (F-1 STEM OPT)"), so it carries over.
    static func inferStatus(_ text: String) -> VisaStatus? {
        let t = " " + normalized(text).replacingOccurrences(of: "f 1", with: "f1").replacingOccurrences(of: "h 1b", with: "h1b") + " "
        if t.contains(" stem ") { return .f1stemopt }
        if t.contains(" opt ") { return .f1opt }
        if t.contains(" cpt ") { return .f1cpt }
        if t.contains(" h1b ") { return .h1b }
        if t.contains(" green card ") || t.contains(" permanent resident ") { return .greenCard }
        return nil
    }

    /// The US work status the immigration answers come from.
    enum VisaStatus: String, CaseIterable, Identifiable {
        case citizen, greenCard, f1opt, f1stemopt, f1cpt, h1b, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .citizen: "US citizen"
            case .greenCard: "Green card (permanent resident)"
            case .f1opt: "F-1 OPT"
            case .f1stemopt: "F-1 STEM OPT"
            case .f1cpt: "F-1 CPT"
            case .h1b: "H-1B"
            case .other: "Other (type it below)"
            }
        }
        /// How forms that ask "what is your status" get it.
        var formText: String {
            switch self {
            case .citizen: "US citizen"
            case .greenCard: "US permanent resident (green card)"
            case .f1opt: "F-1 student on OPT (EAD)"
            case .f1stemopt: "F-1 student on STEM OPT extension (EAD)"
            case .f1cpt: "F-1 student on CPT"
            case .h1b: "H-1B"
            case .other: ""
            }
        }
        var isF1: Bool { [.f1opt, .f1stemopt, .f1cpt].contains(self) }
        /// Sponsorship is needed at some point (an H-1B petition or transfer).
        var needsSponsorship: Bool { isF1 || self == .h1b }
    }

    /// The answer to an immigration question, worked out from `visaStatus` for the question's own shape ("Are you a US citizen?",
    /// "Will you now or in the future need sponsorship?", "What type of sponsorship?", "What is your visa status?"). Nil when the
    /// question is not about immigration or no status is chosen; "" when it needs a fact the bank lacks (the user is asked).
    func immigrationAnswer(for question: String) -> String? {
        guard let status, status != .other else { return nil }
        let q = " " + Self.normalized(question).replacingOccurrences(of: "u s ", with: "us ").replacingOccurrences(of: "f 1", with: "f1") + " "
        func has(_ words: String...) -> Bool { words.contains { q.contains(" " + $0 + " ") } }        // whole words ("opt", not "optional")
        func any(_ stems: String...) -> Bool { stems.contains { q.contains(" " + $0) } }   // word starts ("authoriz" → authorized)
        let yes = "Yes", no = "No"
        let about = any("sponsor", "visa", "citizen", "immigra", "authoriz", "authoris", "legally", "eligible to work", "right to work",
                        "permitted to work", "permanent resident", "green card", "nationality", "work status", "work permit")
            || has("opt", "cpt", "ead", "f1", "stem opt", "h1b")
        guard about else { return nil }
        if any("what kind", "what type", "which type", "type of sponsor", "type of visa sponsor"), any("sponsor") {
            return status == .h1b ? "H-1B transfer" : status.needsSponsorship ? "H-1B" : "None"
        }
        if any("expir", "end date", "valid until", "valid through") { return eadExpiry }
        if any("country of citizenship", "citizenship country", "nationality", "what is your citizenship", "which country") {
            return status == .citizen ? "United States" : citizenshipCountry
        }
        if any("visa status", "immigration status", "current status", "work authorization status", "work status", "type of work authorization",
               "current visa", "what visa", "which visa", "visa type", "type of visa", "best describes", "describe your") {
            return status.formText
        }
        if any("sponsor") {
            // "Do you currently need sponsorship?" asked alone: OPT / CPT already authorizes the job, so No. Any mention of the future,
            // or of OPT itself as a kind of sponsorship (DoorDash lists "STEM OPT"), is Yes for someone who will need an H-1B.
            let nowOnly = any("currently", "now", "at this time", "to start") && !any("future", "any point", "any time", "later", "eventually", "maintain")
            if !status.needsSponsorship { return no }
            if status.isF1, nowOnly, !has("opt", "stem opt", "cpt") { return no }
            return yes
        }
        if any("permanent resident", "green card", "lawful permanent") {
            return status == .greenCard || status == .citizen && any("citizen") ? yes : no
        }
        if any("citizen") { return status == .citizen ? yes : no }
        if has("opt", "cpt", "ead", "f1", "stem opt") || any("student visa") { return status.isF1 ? yes : no }
        if has("h1b") { return status == .h1b ? yes : no }
        if any("authoriz", "authoris", "legally", "eligible to work", "right to work", "permitted to work", "work permit") { return yes }
        return nil
    }

    /// Every immigration answer spelled out for the browser agent, so it can match any wording or option list on a form.
    var immigrationFacts: [String] {
        guard let status, status != .other else { return [] }
        func a(_ q: String) -> String { immigrationAnswer(for: q) ?? "" }
        let country = status == .citizen ? "United States" : citizenshipCountry
        return [
            "My status: \(status.formText)\(eadExpiry.isEmpty ? "" : ", work authorization valid until \(eadExpiry)")",
            "Legally authorized to work in the US: \(a("Are you legally authorized to work in the US?"))",
            "Need sponsorship now or in the future (e.g. H-1B): \(a("Will you now or in the future require sponsorship?"))",
            "Need sponsorship to start this job right now, when asked on its own: \(a("Do you currently require sponsorship?"))",
            "Kind of sponsorship I will need: \(a("What type of sponsorship will you require?"))",
            "US citizen: \(a("Are you a US citizen?")); US permanent resident / green card holder: \(a("Are you a permanent resident?"))",
            "On F-1 OPT, STEM OPT or CPT / hold an EAD: \(a("Are you on OPT or hold an EAD?"))",
            "Country of citizenship / nationality: \(country.isEmpty ? "(unknown; if required, stop and report it)" : country)",
            "When a form lists status options, choose the one matching \"\(status.formText)\" (e.g. \"F-1 / OPT\", \"Student visa (F-1)\", "
                + "\"STEM OPT\", \"Other\" with \"\(status.label)\" typed in). Never answer that I am a citizen or permanent resident unless the above says so.",
        ]
    }

    /// Facts in the bank that disagree with each other, e.g. a current title that is not the title on the latest job in the
    /// employment history. Forms and résumés trip over these, so the Hunt settings show them.
    var historyConflicts: [String] {
        var out: [String] = []
        let latest = employment.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = latest.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 {
            let title = parts[1], company = parts[0]
            if !currentTitle.isEmpty, Self.normalized(title) != Self.normalized(currentTitle) {
                out.append("Current title says \u{201C}\(currentTitle)\u{201D} but your latest job in Employment history says \u{201C}\(title)\u{201D}.")
            }
            let cur = Self.normalized(currentEmployer), comp = Self.normalized(company)
            if !cur.isEmpty, !comp.isEmpty, !comp.contains(cur), !cur.contains(comp),
               cur.split(separator: " ").first != comp.split(separator: " ").first {
                out.append("Current employer says \u{201C}\(currentEmployer)\u{201D} but Employment history starts with \u{201C}\(company)\u{201D}.")
            }
        }
        if !education.isEmpty, education.range(of: #"\d{4}"#, options: .regularExpression) == nil {
            out.append("Education history has no dates; forms that ask for start and end dates will stop.")
        }
        if !employment.isEmpty, employment.range(of: #"\d{4}"#, options: .regularExpression) == nil {
            out.append("Employment history has no dates.")
        }
        return out
    }

    /// The two titles when Current title and the latest job in Employment history disagree, so the Answer Bank can offer
    /// to use one of them in both places. Nil when they agree or either is missing.
    var titleConflict: (current: String, history: String)? {
        let latest = employment.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = latest.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[1].isEmpty, !currentTitle.isEmpty,
              Self.normalized(parts[1]) != Self.normalized(currentTitle) else { return nil }
        return (currentTitle, parts[1])
    }

    /// The bank with `title` as both Current title and the latest job's title in Employment history.
    func usingTitle(_ title: String) -> AnswerBank {
        var b = self
        b.currentTitle = title
        var lines = employment.components(separatedBy: "\n")
        if let first = lines.first {
            var parts = first.components(separatedBy: "|")
            if parts.count >= 2 {
                let lead = parts[1].prefix(while: \.isWhitespace), trail = parts[1].reversed().prefix(while: \.isWhitespace)
                parts[1] = String(lead) + title + String(trail.reversed())
                lines[0] = parts.joined(separator: "|")
            }
        }
        b.employment = lines.joined(separator: "\n")
        return b
    }

    /// What still stops applications from going out on their own (shown on the Mac's run card and the phone's remote card).
    var setupIssues: [String] {
        var out: [String] = []
        if status == nil { out.append("Choose your US work status, so visa questions answer themselves.") }
        if status != nil, status != .citizen, citizenshipCountry.isEmpty { out.append("Add your country of citizenship.") }
        if zipCode.isEmpty { out.append("Add your zip code; many forms require it.") }
        let missing = missingStopping.filter { status == nil || !["work authorization", "sponsorship", "citizenship"].contains($0) }
        if !missing.isEmpty { out.append("Fill in " + missing.joined(separator: ", ") + ".") }
        return out + historyConflicts
    }

    /// Education or employment history too thin for forms that ask for each entry's dates (empty, or no year anywhere).
    var historyIsThin: Bool {
        [education, employment].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.range(of: #"\d{4}"#, options: .regularExpression) == nil }
    }

    /// Routine screening questions with one honest everyday answer, so they never stop an application: privacy notices and
    /// declarations get acknowledged, marketing texts declined, "have you worked here" checked against my employment history.
    /// Saved answers win over these. Nil when the question is not one of them.
    func screeningAnswer(for question: String) -> String? {
        let q = " " + Self.normalized(question) + " "
        func any(_ stems: String...) -> Bool { stems.contains { q.contains(" " + $0) } }
        if any("sms", "text message", "whatsapp", "marketing", "newsletter", "promotional") { return "No" }
        if any("worked at", "worked for", "been employed", "employed by", "former employee", "previously employed", "current or former",
               "currently employed by", "ever worked") {
            let past = Self.normalized(employment + " " + currentEmployer)
            let words = Set(past.split(separator: " ").map(String.init).filter { $0.count > 3 })
            let named = Self.normalized(question).split(separator: " ").map(String.init).filter { $0.count > 3 && $0.first?.isLetter == true }
            // A company I worked for named in the question needs a real answer; otherwise No.
            let generic: Set<String> = ["have", "worked", "work", "ever", "been", "employed", "previously", "company", "former", "current",
                                        "employee", "with", "your", "this", "before", "subsidiar", "affiliate", "currently", "while", "were"]
            return named.contains { words.contains($0) && !generic.contains($0) } ? nil : "No"
        }
        if any("18 years", "at least 18", "over 18", "over the age of 18", "18 or older") { return "Yes" }
        if any("essential functions") { return "Yes" }
        if any("relative", "family member", "related to anyone", "related to an employee") {
            let mine = Set(relatives.split(whereSeparator: \.isNewline).map { Self.normalized(String($0)) }.filter { !$0.isEmpty })
            return mine.contains { q.contains(" " + $0 + " ") } ? "Yes" : "No"
        }
        if any("background check", "drug test", "drug screen") { return "Yes" }
        if any("privacy", "i acknowledge", "acknowledge", "i agree", "i certify", "i confirm", "i have read", "i understand", "attest",
               "consent to the processing", "accurate and complete", "true and complete") {
            return "Yes, I acknowledge"
        }
        return nil
    }


    init() {}
    /// Tolerates partial JSON (the table default is `{}`), so missing keys stay empty instead of failing the sync.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        fullName = s(.fullName); email = s(.email); phone = s(.phone); city = s(.city)
        linkedin = s(.linkedin); github = s(.github); portfolio = s(.portfolio); resumeLink = s(.resumeLink)
        workAuthorization = s(.workAuthorization); needsSponsorship = s(.needsSponsorship); citizenship = s(.citizenship)
        visaStatus = s(.visaStatus); citizenshipCountry = s(.citizenshipCountry); eadExpiry = s(.eadExpiry)
        zipCode = s(.zipCode); state = s(.state); country = s(.country); pronouns = s(.pronouns); relatives = s(.relatives); eeoExtra = s(.eeoExtra)
        remote = (try? c.decodeIfPresent(HuntRemote.self, forKey: .remote)) ?? HuntRemote()
        if visaStatus.isEmpty { visaStatus = Self.inferStatus(workAuthorization + " " + citizenship)?.rawValue ?? "" }
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
    enum WhenEmpty { case ask, decline, blank, portfolio, unitedStates }
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
        if has("transgender", "sexual orientation", "lgbt", "gender identity") { return legal(\.eeoExtra, .decline) }
        if has("pronoun") { return Rule(field: \.pronouns, legal: false, whenEmpty: .blank) }
        if has("relocat") { return legal(\.relocation) }
        if has("start date", "available to start", "availability", "earliest", "notice period") { return legal(\.startDate) }
        if has("hear about", "hear of", "how did you find", "referral source", "source of application") { return plain(\.referralSource) }
        if has("employment history", "work history", "previous employers", "past employers") { return plain(\.employment) }
        if has("education history", "educational background", "education background") { return plain(\.education) }
        if has("graduat") { return plain(\.graduation) }
        if has("gpa", "grade point") { return plain(\.gpa) }
        if has("zip", "postal code", "postcode") { return plain(\.zipCode) }
        if normalized(question) == "state" || normalized(question).hasPrefix("state of residence") { return plain(\.state) }
        if has("state or province", "state/province", "which state", "what state", "u.s. state", "us state", "province"),
           !has("statement") { return plain(\.state) }
        if has("country"), !has("citizenship", "nationality", "country of birth") { return Rule(field: \.country, legal: false, whenEmpty: .unitedStates) }
        if has("field of study", "area of study", "major", "discipline"), !has("accomplish", "achievement", "project", "challenge") { return plain(\.major) }
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
        if let derived = immigrationAnswer(for: question) {
            return derived.isEmpty ? ("", "needs_you", true) : (derived, "bank", true)
        }
        if Self.rule(for: question) == nil, savedAnswer(for: question) == nil, let routine = screeningAnswer(for: question) {
            return (routine, "bank", false)
        }
        if let rule = Self.rule(for: question) {
            let value = self[keyPath: rule.field]
            if !value.isEmpty { return (value, "bank", rule.legal) }
            if let saved = savedAnswer(for: question), !saved.isEmpty { return (saved, "bank", rule.legal) }
            switch rule.whenEmpty {
            case .decline: return ("Decline to self-identify", "bank", rule.legal)
            case .blank: return ("", "bank", rule.legal)
            case .portfolio: return portfolio.isEmpty ? ("", "needs_you", rule.legal) : (portfolio, "bank", rule.legal)
            case .unitedStates: return ("United States", "bank", rule.legal)
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
    /// The keyword score Tailor recorded at the end of `reason` ("Keywords: 92%."), if any.
    var keywordScore: Int? {
        guard let r = reason.range(of: #"Keywords: (\d+)%\."#, options: .regularExpression) else { return nil }
        return Int(reason[r].filter(\.isNumber))
    }
    /// What the ATS check found: [] when the PDF parses cleanly, nil when it never ran.
    var atsIssues: [String]? {
        guard let r = reason.range(of: "ATS: ") else { return nil }
        let rest = String(reason[r.upperBound...])
        return rest.hasPrefix("parses cleanly") ? [] : rest.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// `reason` without the quality notes the badges show.
    var displayReason: String {
        let cut = [reason.range(of: "Keywords: ")?.lowerBound, reason.range(of: "ATS: ")?.lowerBound].compactMap { $0 }.min()
        return cut.map { String(reason[..<$0]).trimmingCharacters(in: .whitespaces) } ?? reason
    }

    /// Skipped leads with this reason need the user to apply themselves (an account to create, an assessment); Hunt lists them apart.
    static let byHandPrefix = "Apply by hand: "
    /// The last line of a submitted lead's reason: which account the application used.
    static let accountPrefix = "Account: "
    /// For a submitted lead: (confirmation, account), split from `reason`.
    var appliedDetails: (confirmation: String, account: String) {
        let lines = reason.components(separatedBy: "\n")
        if let last = lines.last, last.hasPrefix(Self.accountPrefix) {
            return (lines.dropLast().joined(separator: "\n"), String(last.dropFirst(Self.accountPrefix.count)))
        }
        return (reason, "")
    }
    var isByHand: Bool { status == .skipped && reason.hasPrefix(Self.byHandPrefix) }

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
