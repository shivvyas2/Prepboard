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
