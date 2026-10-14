import SwiftData
import SwiftUI

struct DocumentsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Doc.order) private var allDocs: [Doc]
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @Query(sort: \PrepTask.start) private var tasks: [PrepTask]
    @Environment(Cloud.self) private var cloud
    @State private var importingPDF = false

    private var filtered: [Doc] {
        switch app.docFilter {
        case "all": allDocs
        case "none": allDocs.filter { $0.roleId.isEmpty }
        default: allDocs.filter { $0.roleId == app.docFilter }
        }
    }

    /// Documents grouped by role (roles first, then General), ordered by guide number.
    private var groups: [(title: String, docs: [Doc])] {
        let byRole = Dictionary(grouping: filtered, by: \.roleId)
        var out: [(String, [Doc])] = roles.compactMap { r in byRole[r.id].map { ("\(r.company) · \(r.title)", $0) } }
        if let general = byRole[""] { out.append(("General", general)) }
        let known = Set(roles.map(\.id))
        let orphans = byRole.filter { !$0.key.isEmpty && !known.contains($0.key) }.flatMap(\.value)
        if !orphans.isEmpty { out.append(("Other", orphans)) }
        return out.map { ($0.0, $0.1.sorted { ($0.order, $1.updatedAt) < ($1.order, $0.updatedAt) }) }
    }

    var body: some View {
        content
            .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
                guard case let .success(url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { app.message = "Couldn't read that PDF."; return }
                let roleId = ["all", "none"].contains(app.docFilter) ? "" : app.docFilter
                Task {
                    do {
                        let doc = try await cloud.importPDF(data, fileName: url.lastPathComponent, roleId: roleId, context: context)
                        app.openDoc(doc.id)
                    } catch { app.message = "Upload failed: \(error.localizedDescription)" }
                }
            }
    }

    private var content: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 600   // iPad portrait and up: list + document side by side
            let selected = allDocs.first { $0.id == app.selectedDocID }
            if wide {
                HStack(alignment: .top, spacing: 16) {
                    list.frame(width: geo.size.width > 1000 ? 310 : 250)
                    if let doc = selected ?? groups.first?.docs.first {
                        DocEditorView(doc: doc, tasks: tasks, roles: roles).id(doc.id)
                    } else {
                        Text("Create a document to get started.").foregroundStyle(PB.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).pbCard()
                    }
                }
            } else if let doc = selected {
                VStack(alignment: .leading, spacing: 12) {
                    Button { app.selectedDocID = nil } label: { Label("Documents", systemImage: "chevron.left") }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    DocEditorView(doc: doc, tasks: tasks, roles: roles).id(doc.id)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    Button("All documents") { app.docFilter = "all" }
                    Button("General") { app.docFilter = "none" }
                    ForEach(roles) { r in Button("\(r.company) · \(r.title)") { app.docFilter = r.id } }
                } label: {
                    HStack {
                        Text(filterTitle).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16).frame(height: 36)
                    .overlay(Capsule().strokeBorder(PB.line2))
                    .contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain)
                Button { importingPDF = true } label: {
                    Text("PDF").font(.system(size: 11, weight: .bold)).frame(width: 44, height: 44)
                        .foregroundStyle(PB.ink2).background(Circle().fill(PB.card)).overlay(Circle().strokeBorder(PB.line))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("Upload a PDF")
                CircleIconButton(systemImage: "plus", label: "New document") {
                    app.newDoc(context, roleId: ["all", "none"].contains(app.docFilter) ? "" : app.docFilter)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title).pbLabelStyle().padding(.top, 12).padding(.horizontal, 4)
                        ForEach(group.docs) { docCard($0) }
                    }
                    if allDocs.isEmpty { Text("No documents.").foregroundStyle(PB.muted).padding(32) }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var filterTitle: String {
        switch app.docFilter {
        case "all": "All documents"
        case "none": "General"
        default: roles.first { $0.id == app.docFilter }.map { "\($0.company) · \($0.title)" } ?? "All documents"
        }
    }

    private func docCard(_ d: Doc) -> some View {
        let active = d.id == (app.selectedDocID ?? groups.first?.docs.first?.id)
        let next = tasks.first { t in !t.done && t.end > .now && t.refs.contains { $0.docId == d.id } }
        return Button { app.selectedDocID = d.id; app.docEditing = false } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(d.isPDF ? "PDF" : d.tags.contains("research") ? "Rs" : String(format: "%02d", min(d.order, 99)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(PB.muted)
                    .frame(width: 24, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.title.isEmpty ? "Untitled" : d.title).font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text(next.map { "Next: \($0.start.formatted(.dateTime.weekday(.abbreviated))) \(TimeFmt.hm($0.start))" }
                         ?? "Edited \(d.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(PB.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous).fill(PB.card))
            .overlay(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous).strokeBorder(active ? PB.cobalt : PB.line, lineWidth: active ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: PB.rLG))
        }
        .buttonStyle(.plain)
    }
}

struct DocEditorView: View {
    @Bindable var doc: Doc
    let tasks: [PrepTask]
    let roles: [Role]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var blocks: [MDBlock] = []
    @Environment(Cloud.self) private var cloud
    @Query private var allDocs: [Doc]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var sidePad: CGFloat { sizeClass == .compact ? 16 : 40 }
    #else
    private let sidePad: CGFloat = 40
    #endif

    /// Formatted copy ↔ original PDF (planner attachments are saved as both).
    private var originalID: String? { doc.tags.first { $0.hasPrefix("original:") }.map { String($0.dropFirst(9)) } }
    private var formattedCopy: Doc? { doc.isPDF ? allDocs.first { $0.tags.contains("original:\(doc.id)") } : nil }

    var body: some View {
        @Bindable var app = app
        let schedule = tasks.filter { $0.refs.contains { $0.docId == doc.id } }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if doc.isPDF {
                    Label("PDF", systemImage: "doc.richtext").font(.system(size: 12, weight: .semibold)).foregroundStyle(PB.muted)
                } else {
                    Picker("", selection: $app.docEditing) {
                        Text("Read").tag(false)
                        Text("Edit").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    Text("\(doc.body.split(whereSeparator: \.isWhitespace).count) words · edited \(doc.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let id = originalID, allDocs.contains(where: { $0.id == id }) {
                    Button { app.openDoc(id, heading: nil) } label: { Label("Original PDF", systemImage: "doc.richtext") }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true)).help("Open the PDF exactly as uploaded")
                } else if let copy = formattedCopy {
                    Button { app.openDoc(copy.id, heading: nil) } label: { Label("Formatted version", systemImage: "doc.text") }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                if blocks.contains(where: { if case .heading(2, _) = $0 { true } else { false } }) && !app.docEditing {
                    Menu {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { idx, b in
                            if case let .heading(2, text) = b { Button(text) { app.docScrollHeading = text } }
                        }
                    } label: { Image(systemName: "list.bullet").frame(width: 32, height: 32) }
                    .menuStyle(.button).buttonStyle(.plain).help("Contents")
                    .overlay(Circle().strokeBorder(PB.line))
                }
                CircleIconButton(systemImage: "square.and.arrow.down", size: 32, label: "Export Markdown") { exporting = true }
                CircleIconButton(systemImage: "trash", size: 32, label: "Delete document") { confirmDelete = true }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(PB.line).frame(height: 1) }

            if doc.isPDF {
                // PDFs get the full height with their own scrolling and pinch-zoom (no nested scroll views).
                VStack(alignment: .leading, spacing: 8) {
                    Text(doc.title).font(.system(size: 22, weight: .bold)).kerning(-0.4).lineLimit(2)
                    PDFDocView(doc: doc).frame(maxHeight: .infinity)
                }
                .padding(.horizontal, sidePad).padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TextField("Untitled", text: $doc.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 34, weight: .bold)).kerning(-1)
                            .onChange(of: doc.title) { doc.updatedAt = .now }
                        HStack(spacing: 8) {
                            Picker("", selection: $doc.roleId) {
                                Text("General").tag("")
                                ForEach(roles) { Text("\($0.company) · \($0.title)").tag($0.id) }
                            }
                            .labelsHidden().pickerStyle(.menu).tint(PB.ink2).fixedSize()
                            TextField("tags, comma separated", text: Binding(
                                get: { doc.tags.joined(separator: ", ") },
                                set: { doc.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(PB.surface)).overlay(Capsule().strokeBorder(PB.line))
                                .frame(maxWidth: 260)
                        }
                        .padding(.top, 8).padding(.bottom, 16)

                        if !schedule.isEmpty { scheduleCard(schedule) }

                        if app.docEditing {
                            TextEditor(text: $doc.body)
                                .font(.system(size: 13, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 480)
                                .onChange(of: doc.body) { doc.updatedAt = .now }
                        } else if doc.body.isEmpty {
                            Text("Empty. Switch to Edit to start writing.").foregroundStyle(PB.muted)
                        } else {
                            MarkdownView(blocks: blocks).frame(maxWidth: 820, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, sidePad).padding(.vertical, sidePad == 16 ? 16 : 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { blocks = parsedBody(); scrollToHeading(proxy) }
                .onChange(of: app.docEditing) { if !app.docEditing { blocks = parsedBody() } }
                .onChange(of: doc.body) { if !app.docEditing { blocks = parsedBody() } }
                .onChange(of: app.docScrollHeading) { scrollToHeading(proxy) }
            }
            }
        }
        .background(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).fill(PB.card))
        .overlay(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).strokeBorder(PB.line))
        .clipShape(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous))
        .shadow(color: PB.shadow.opacity(0.06), radius: 14, y: 6)
        .confirmationDialog("Delete this document?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                for t in tasks where t.refs.contains(where: { $0.docId == doc.id }) { t.refs.removeAll { $0.docId == doc.id } }
                app.selectedDocID = nil
                let removed = doc
                Task { await cloud.deleteFile(for: removed) }
                context.delete(doc)
            }
        } message: { Text("Links to it on the timeline are removed.") }
        .fileExporter(isPresented: $exporting, document: MarkdownFile(text: doc.body), contentType: .plainText,
                      defaultFilename: (doc.title.isEmpty ? "Untitled" : doc.title) + ".md") { _ in }
    }

    private func scheduleCard(_ schedule: [PrepTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On your timeline").pbLabelStyle().padding(.bottom, 4)
            ForEach(schedule) { t in
                Button { app.gotoSession(t) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(t.start.formatted(.dateTime.weekday(.abbreviated).day())) · \(TimeFmt.hm(t.start))")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(PB.ink2).frame(width: 110, alignment: .leading)
                        Text((t.done ? "✓ " : "") + t.title).font(.system(size: 13))
                            + Text(t.refs.filter { $0.docId == doc.id && !$0.heading.isEmpty }
                                    .map { "  › " + TimeFmt.cleanHeading($0.heading) }.joined())
                                .font(.system(size: 13)).foregroundStyle(PB.muted)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: PB.rLG).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: PB.rLG).strokeBorder(PB.line))
        .padding(.bottom, 24)
    }

    /// Parsed body, minus a leading "# Title" that just repeats the document title shown above it.
    private func parsedBody() -> [MDBlock] {
        var b = MarkdownParser.parse(doc.body)
        if case let .heading(1, t)? = b.first, t.trimmingCharacters(in: .whitespaces) == doc.title.trimmingCharacters(in: .whitespaces) { b.removeFirst() }
        return b
    }

    private func scrollToHeading(_ proxy: ScrollViewProxy) {
        guard let heading = app.docScrollHeading else { return }
        app.docEditing = false
        let idx = blocks.firstIndex { if case let .heading(_, text) = $0 { text == heading } else { false } }
        guard let idx else { app.docScrollHeading = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.snappy) { proxy.scrollTo(idx, anchor: .top) }
            app.docScrollHeading = nil
        }
    }
}
