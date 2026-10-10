import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query private var roles: [Role]
    @Query private var docs: [Doc]
    @Query private var tasks: [PrepTask]

    private struct Result: Identifiable {
        let id: String
        let kind: String
        let title: String
        let snippet: String
        let score: Int
        let open: () -> Void
    }

    var body: some View {
        @Bindable var app = app
        let q = app.searchText.trimmingCharacters(in: .whitespaces)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search").pbLabelStyle()
                    Text(q.isEmpty ? "Find anything" : "“\(q)”").font(.pbDisplay).kerning(-1.4).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PB.muted)
                    TextField("Search roles, docs, sessions…", text: $app.searchText).textFieldStyle(.plain)
                }
                .padding(.horizontal, 16).frame(height: 44)
                .background(Capsule().fill(PB.card)).overlay(Capsule().strokeBorder(PB.line))
                if !q.isEmpty { webCard(q) }
                let results = search(q)
                if q.isEmpty {
                    Text("Type to search everything in your workspace.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(40)
                } else if results.isEmpty {
                    Text("No matches in your workspace.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(40)
                }
                ForEach(results) { r in
                    Button(action: r.open) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.kind).pbLabelStyle()
                            Text(r.title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.leading)
                            if !r.snippet.isEmpty {
                                Text(r.snippet).font(.system(size: 13)).foregroundStyle(PB.muted).lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                        .pbCard(padding: 16, radius: PB.rLG)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }

    private func webCard(_ q: String) -> some View {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let links: [(String, String)] = [
            ("Apple Developer", "https://developer.apple.com/search/?q=\(enc)"),
            ("LeetCode", "https://leetcode.com/problemset/?search=\(enc)"),
            ("Web", "https://www.google.com/search?q=\(enc)"),
            ("Glassdoor", "https://www.glassdoor.com/Search/results.htm?keyword=\(enc)"),
        ]
        let roleId = roles.filter { ($0.interviewAt ?? .distantPast) > .now }.min { $0.interviewAt! < $1.interviewAt! }?.id ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Research on the web")
            FlowLayout(spacing: 8) {
                ForEach(links, id: \.0) { name, url in
                    Button(name) { if let u = URL(string: url) { app.openInBrowser(u) } }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                Button("Save as research note") { app.saveResearch(q, roleId: roleId, context: context) }
                    .buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .pbCard()
    }

    private func search(_ q: String) -> [Result] {
        let terms = q.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        func hit(_ s: String) -> Bool { let l = s.lowercased(); return terms.allSatisfy { l.contains($0) } }
        func score(_ s: String) -> Int { let l = s.lowercased(); return terms.reduce(0) { $0 + l.components(separatedBy: $1).count - 1 } }
        func snippet(_ s: String) -> String {
            let flat = s.replacingOccurrences(of: "\n", with: " ")
            guard let r = flat.range(of: terms[0], options: .caseInsensitive) else { return String(flat.prefix(200)) }
            let start = flat.index(r.lowerBound, offsetBy: -70, limitedBy: flat.startIndex) ?? flat.startIndex
            let end = flat.index(start, offsetBy: 220, limitedBy: flat.endIndex) ?? flat.endIndex
            return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
        }
        var out: [Result] = []
        for r in roles {
            let blob = [r.company, r.title, r.team, r.notes, r.location, r.stageRaw].joined(separator: " ")
            if hit(blob) { out.append(.init(id: r.id, kind: "Role", title: "\(r.company) — \(r.title)", snippet: r.notes, score: score(blob) + 50) { app.openRole(r.id) }) }
        }
        for t in tasks {
            let blob = t.title + " " + t.refs.map(\.heading).joined(separator: " ")
            if hit(blob) {
                out.append(.init(id: t.id, kind: "Session · \(t.start.formatted(.dateTime.weekday(.abbreviated).day())) \(TimeFmt.hm(t.start))",
                                 title: t.title, snippet: t.refs.map { TimeFmt.cleanHeading($0.heading) }.filter { !$0.isEmpty }.joined(separator: " · "),
                                 score: 30 + score(blob)) { app.gotoSession(t) })
            }
        }
        for d in docs {
            let blob = d.title + " " + d.body + " " + d.tags.joined(separator: " ")
            guard hit(blob) else { continue }
            let heading = d.body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
                .first { h in terms.contains { h.lowercased().contains($0) } }
            out.append(.init(id: d.id, kind: "Document", title: d.title + (heading.map { " › " + TimeFmt.cleanHeading($0) } ?? ""),
                             snippet: snippet(d.body), score: score(d.title) * 20 + score(blob)) { app.openDoc(d.id, heading: heading) })
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(60))
    }
}
