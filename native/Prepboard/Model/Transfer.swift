import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// JSON format shared with the Prepboard web app (Export / Import).
struct Snapshot: Codable {
    struct RoleDTO: Codable {
        var id: String
        var company: String?, title: String?, team: String?, location: String?, roleNumber: String?
        var salary: String?, link: String?, stage: String?, interviewAt: String?, interviewNote: String?
        var notes: String?, createdAt: String?, interviewEnd: String?
    }
    struct DocDTO: Codable {
        var id: String
        var roleId: String?, title: String?, body: String?, tags: [String]?, updatedAt: String?, order: Int?
    }
    struct RefDTO: Codable { var doc: String; var heading: String? }
    struct TaskDTO: Codable {
        var id: String
        var roleId: String?, title: String?, due: String?, done: Bool?
        var start: String?, end: String?, kind: String?, refs: [RefDTO]?
    }
    var roles: [RoleDTO]
    var docs: [DocDTO]
    var tasks: [TaskDTO]?
}

enum DateCoding {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if s.count == 10, let d = day.date(from: s) { return d.addingTimeInterval(12 * 3600) }
        return iso.date(from: s) ?? isoFrac.date(from: s)
    }
    static func string(_ d: Date?) -> String { d.map { iso.string(from: $0) } ?? "" }
    static func dayString(_ d: Date?) -> String { d.map { day.string(from: $0) } ?? "" }
}

enum Transfer {
    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Role>())) ?? 0
        let docCount = (try? context.fetchCount(FetchDescriptor<Doc>())) ?? 0
        guard count == 0, docCount == 0,
              let url = Bundle.main.url(forResource: "seed", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        try? importData(data, into: context, replace: false)
    }

    @MainActor
    static func importData(_ data: Data, into context: ModelContext, replace: Bool) throws {
        let snap = try JSONDecoder().decode(Snapshot.self, from: data)
        if replace {
            try context.delete(model: Role.self)
            try context.delete(model: Doc.self)
            try context.delete(model: PrepTask.self)
        }
        let existingRoles = Set(((try? context.fetch(FetchDescriptor<Role>())) ?? []).map(\.id))
        let existingDocs = Set(((try? context.fetch(FetchDescriptor<Doc>())) ?? []).map(\.id))
        let existingTasks = Set(((try? context.fetch(FetchDescriptor<PrepTask>())) ?? []).map(\.id))
        for r in snap.roles where replace || !existingRoles.contains(r.id) {
            context.insert(Role(id: r.id, company: r.company ?? "", title: r.title ?? "", team: r.team ?? "",
                                location: r.location ?? "", roleNumber: r.roleNumber ?? "", salary: r.salary ?? "",
                                link: r.link ?? "", stage: Stage(rawValue: r.stage ?? "") ?? .saved,
                                interviewAt: DateCoding.date(r.interviewAt), interviewNote: r.interviewNote ?? "",
                                notes: r.notes ?? "", createdAt: DateCoding.date(r.createdAt) ?? .now))
        }
        for d in snap.docs where replace || !existingDocs.contains(d.id) {
            context.insert(Doc(id: d.id, roleId: d.roleId ?? "", title: d.title ?? "", body: d.body ?? "",
                               tags: d.tags ?? [], updatedAt: DateCoding.date(d.updatedAt) ?? .now, order: d.order ?? 999))
        }
        for t in snap.tasks ?? [] where replace || !existingTasks.contains(t.id) {
            let start = DateCoding.date(t.start)
                ?? DateCoding.date(t.due).map { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) ?? $0 }
                ?? .now
            let end = DateCoding.date(t.end) ?? start.addingTimeInterval(3600)
            context.insert(PrepTask(id: t.id, roleId: t.roleId ?? "", title: t.title ?? "", start: start, end: end,
                                    kind: SessionKind(rawValue: t.kind ?? "") ?? .study,
                                    refs: (t.refs ?? []).map { DocRef(docId: $0.doc, heading: $0.heading ?? "") },
                                    done: t.done ?? false))
        }
        try context.save()
    }

    @MainActor
    static func exportData(_ context: ModelContext) throws -> Data {
        let roles = try context.fetch(FetchDescriptor<Role>())
        let docs = try context.fetch(FetchDescriptor<Doc>())
        let tasks = try context.fetch(FetchDescriptor<PrepTask>())
        let snap = Snapshot(
            roles: roles.map { .init(id: $0.id, company: $0.company, title: $0.title, team: $0.team, location: $0.location,
                                     roleNumber: $0.roleNumber, salary: $0.salary, link: $0.link, stage: $0.stageRaw,
                                     interviewAt: DateCoding.string($0.interviewAt), interviewNote: $0.interviewNote,
                                     notes: $0.notes, createdAt: DateCoding.string($0.createdAt), interviewEnd: nil) },
            docs: docs.map { .init(id: $0.id, roleId: $0.roleId, title: $0.title, body: $0.body, tags: $0.tags,
                                   updatedAt: DateCoding.string($0.updatedAt), order: $0.order) },
            tasks: tasks.map { .init(id: $0.id, roleId: $0.roleId, title: $0.title, due: DateCoding.dayString($0.start), done: $0.done,
                                     start: DateCoding.string($0.start), end: DateCoding.string($0.end), kind: $0.kindRaw,
                                     refs: $0.refs.map { .init(doc: $0.docId, heading: $0.heading) }) })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(snap)
    }
}

struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
