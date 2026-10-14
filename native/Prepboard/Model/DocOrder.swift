import Foundation
import SwiftData

/// What a document is, from its tags. Documents are grouped and numbered per kind, so a role's guides read 1, 2, 3…
/// whatever else the role holds.
enum DocKind: Int, CaseIterable, Comparable {
    case guide, essentials, material, research, resume, pdf

    static func < (a: DocKind, b: DocKind) -> Bool { a.rawValue < b.rawValue }

    init(tags: [String], isPDF: Bool) {
        if isPDF { self = tags.contains("hunt") ? .resume : .pdf }
        else if tags.contains("essentials") { self = .essentials }
        else if tags.contains("research") || tags.contains("claude") || tags.contains("note") { self = .research }
        else if tags.contains("guide") || tags.isEmpty { self = .guide }
        else { self = .material }   // planner attachments: job posting, résumé text, recruiter notes
    }

    var title: String {
        switch self {
        case .guide: "Prep guides"
        case .essentials: "Interview essentials"
        case .material: "Your materials"
        case .research: "Research and notes"
        case .resume: "Résumés sent"
        case .pdf: "PDFs"
        }
    }
}

extension Doc {
    var kind: DocKind { DocKind(tags: tags, isPDF: isPDF) }
}

enum DocOrder {
    /// Kind first, then the stored number, then newest first.
    static func arranged(_ docs: [Doc]) -> [Doc] {
        docs.sorted { a, b in
            let ka = a.kind, kb = b.kind
            if ka != kb { return ka < kb }
            if a.order != b.order { return a.order < b.order }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Renumbers each role's documents 1…n within each kind, keeping their current order. Touches only documents whose
    /// number changes (each change syncs), and returns how many changed.
    @MainActor
    @discardableResult
    static func normalize(_ context: ModelContext, roleId: String? = nil) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Doc>())) ?? []
        let docs = roleId.map { id in all.filter { $0.roleId == id } } ?? all
        var changed = 0
        for (_, group) in Dictionary(grouping: docs, by: { "\($0.roleId)|\($0.kind.rawValue)" }) {
            for (i, doc) in arranged(group).enumerated() where doc.order != i + 1 {
                doc.order = i + 1; changed += 1
            }
        }
        if changed > 0 { try? context.save() }
        return changed
    }

    /// The number a new document of `kind` gets in `roleId`: after the last one.
    @MainActor
    static func next(_ kind: DocKind, roleId: String, context: ModelContext) -> Int {
        let docs = (try? context.fetch(FetchDescriptor<Doc>(predicate: #Predicate { $0.roleId == roleId }))) ?? []
        return (docs.filter { $0.kind == kind }.map(\.order).max() ?? 0) + 1
    }
}
