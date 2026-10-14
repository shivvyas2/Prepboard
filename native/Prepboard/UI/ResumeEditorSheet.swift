#if os(macOS)
import AppKit
import PDFKit
import SwiftUI

/// Last-minute edits to a tailored .tex: the source on the left, a live PDF preview on the right (rebuilt in a scratch folder as
/// you type), an "Ask Claude" box that rewrites the file under the honesty rules, then Save and Re-check as the explicit steps.
/// Close never asks about unsaved changes.
struct ResumeEditorSheet: View {
    let lead: Lead
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(JobHunt.self) private var hunt
    @Environment(ClaudeCode.self) private var claude
    @State private var text = ""
    @State private var saved = ""        // the file as last read or written; the title says "edited" while the editor differs
    @State private var loaded = false    // false when the .tex could not be read: nothing to save over
    @State private var working = false
    @State private var buildLog = ""
    @State private var footer = ""
    @State private var preview: Data?
    @State private var previewState = "" // "Building preview…", "Preview up to date", or the failure
    @State private var previewTask: Task<Void, Never>?
    @State private var instruction = ""
    @State private var asking = false
    @State private var beforeClaude: String?   // the text before the last Claude edit, for Undo

    private var path: String? { hunt.texPath(for: lead) }
    private var dirty: Bool { loaded && text != saved }
    private var canAct: Bool { loaded && !working && !asking && !hunt.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s4) {
            HStack {
                Text("Edit résumé · \(lead.variantName).tex" + (dirty ? " • edited" : ""))
                    .font(.system(size: 18, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: PB.s4) {
                VStack(alignment: .leading, spacing: PB.s2) {
                    Text("LaTeX").font(.system(size: 12, weight: .semibold)).foregroundStyle(PB.muted)
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(PB.s2)
                        .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.surface))
                        .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line))
                }
                VStack(alignment: .leading, spacing: PB.s2) {
                    HStack(spacing: PB.s2) {
                        Text("PDF preview").font(.system(size: 12, weight: .semibold)).foregroundStyle(PB.muted)
                        Spacer(minLength: 0)
                        if previewState.hasPrefix("Building") { ProgressView().controlSize(.mini) }
                        Text(previewState).font(.system(size: 11)).foregroundStyle(PB.muted).lineLimit(1)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.surface)
                        if let preview {
                            PDFPreview(data: preview).clipShape(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous))
                        } else {
                            Text(buildLog.isEmpty ? "The preview appears here once the file builds." : "The build failed; see the log below.")
                                .font(.system(size: 12)).foregroundStyle(PB.muted).padding(PB.s4)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line))
                }
            }
            .frame(minHeight: 460)
            askClaude
            if !buildLog.isEmpty {
                ScrollView {
                    Text(buildLog).font(.pbMono).foregroundStyle(PB.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(PB.s3)
                .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.red.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.red.opacity(0.3)))
            }
            HStack(spacing: PB.s2) {
                Button("Save & rebuild PDF", action: saveAndRebuild).buttonStyle(PillButtonStyle(compact: true)).disabled(!canAct)
                Button("Re-check claims", action: recheck).buttonStyle(PillButtonStyle(filled: false, compact: true))
                    .disabled(!canAct || !claude.isReady)
                Button("Reveal in Finder") { if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true)).disabled(!loaded)
                Button("Open in editor") { if let path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true)).disabled(!loaded)
                if working { ProgressView().controlSize(.small) }
                Spacer(minLength: PB.s2)
                Text(footer).font(.system(size: 12)).foregroundStyle(buildLog.isEmpty ? PB.muted : PB.red).lineLimit(2).truncationMode(.tail)
            }
            Text("The preview rebuilds as you type and changes nothing on disk. Save & rebuild PDF writes the file and replaces the synced PDF; "
                 + "claims you add are only re-checked when you press Re-check claims.")
                .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(PB.s6)
        .background(PB.card)
        .frame(minWidth: 1180, idealWidth: 1280, minHeight: 760, idealHeight: 900)
        .onAppear(perform: load)
        .onChange(of: text) { schedulePreview() }
        .onDisappear { previewTask?.cancel() }
    }

    /// One instruction to Claude; the reply replaces the editor text (Undo brings the previous text back).
    private var askClaude: some View {
        VStack(alignment: .leading, spacing: PB.s2) {
            Text("Ask Claude").font(.system(size: 12, weight: .semibold)).foregroundStyle(PB.muted)
            HStack(spacing: PB.s2) {
                TextField("e.g. Shorten the summary to two lines and lead with the Swift concurrency bullet", text: $instruction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...3)
                    .padding(.horizontal, PB.s3).padding(.vertical, PB.s2)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                    .onSubmit(ask)
                Button(asking ? "Working…" : "Apply", action: ask).buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!canAct || !claude.isReady || claude.busy || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let beforeClaude {
                    Button("Undo Claude edit") { text = beforeClaude; self.beforeClaude = nil; footer = "Claude's edit undone" }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true)).disabled(asking)
                }
                if asking { ProgressView().controlSize(.small) }
            }
            if !claude.isReady {
                Text("Connect Claude Code in Profile to edit with Claude.").font(.system(size: 11)).foregroundStyle(PB.muted)
            } else {
                Text("Claude reads your other variants as evidence and keeps to the honesty rules: nothing is added that your material does not back.")
                    .font(.system(size: 11)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() {
        guard let path, let file = try? String(contentsOfFile: path, encoding: .utf8) else {
            footer = "Couldn't read \(lead.variantName).tex"; return
        }
        text = file; saved = file; loaded = true
        schedulePreview(delay: 0)
    }

    /// Rebuilds the preview in a scratch folder once typing pauses; a failed build keeps the last good preview and shows the log.
    private func schedulePreview(delay: Double = 1.2) {
        guard loaded else { return }
        previewTask?.cancel()
        let tex = text, name = lead.variantName
        previewState = "Building preview…"
        previewTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            do {
                let data = try await LatexBuild.preview(tex: tex, name: name)
                guard !Task.isCancelled else { return }
                preview = data; buildLog = ""; previewState = "Preview up to date"
                if footer.hasPrefix("The build failed") { footer = "" }
            } catch let failure as LatexBuild.Failure {
                guard !Task.isCancelled else { return }
                buildLog = failure.log; previewState = "Build failed"
            } catch {
                guard !Task.isCancelled else { return }
                previewState = error.localizedDescription
            }
        }
    }

    private func ask() {
        let what = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAct, claude.isReady, !what.isEmpty else { return }
        asking = true; footer = "Claude is editing the résumé…"
        let before = text
        Task {
            defer { asking = false }
            do {
                let result = try await hunt.edit(lead, tex: before, instruction: what)
                beforeClaude = before
                text = result.tex
                instruction = ""
                footer = result.notes.isEmpty ? "Claude's edit is in the editor; Save when it looks right" : result.notes
            } catch {
                footer = error.localizedDescription
            }
        }
    }

    /// Writes the editor to the .tex; false with the error in the footer when it could not.
    private func save() -> Bool {
        guard let path, loaded else { return false }
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); saved = text; return true }
        catch { footer = "Couldn't save: \(error.localizedDescription)"; return false }
    }

    /// Save, build with tectonic, then swap the lead's PDF Doc. A failed build shows its log and keeps the previous PDF.
    /// The hunt is held meanwhile, so the submit queue cannot upload a PDF that is still being written.
    private func saveAndRebuild() {
        guard let path, save() else { return }
        working = true; buildLog = ""; footer = "Building PDF…"
        Task {
            defer { working = false }
            do {
                let note = try await hunt.whileEditing(lead) {
                    let pdf = try await LatexBuild.build(texPath: path)
                    return await hunt.attachPDF(lead, pdfPath: pdf, context: context)
                }
                guard let note else { footer = hunt.error ?? "The hunt is busy; try again when it finishes"; return }
                lead.reason = ["Edited by you; PDF rebuilt", note].filter { !$0.isEmpty }.joined(separator: " ")
                lead.updatedAt = .now
                try? context.save()
                footer = note.isEmpty ? "PDF rebuilt" : "PDF rebuilt, but not uploaded; see the card"
            } catch let failure as LatexBuild.Failure {
                buildLog = failure.log
                footer = "The build failed; the previous PDF is kept"
            } catch {
                footer = error.localizedDescription
            }
        }
    }

    /// Save, then the honesty pass; the outcome lands on the card (status and flagged claims) and in the footer.
    private func recheck() {
        guard save() else { return }
        working = true; buildLog = ""; footer = "Checking claims…"
        Task {
            defer { working = false }
            // False means the pass never ran (a timer took the hunt first, Claude is away): the status on the card is still the old one.
            guard await hunt.recheck(lead) else { footer = "Couldn't re-check right now; try again" + (hunt.error.map { " (\($0))" } ?? ""); return }
            if let e = hunt.error { footer = e }
            else if lead.status == .ready { footer = "Every claim traces to your material" }
            else { footer = "Some claims need you; they are listed on the card" }
        }
    }
}

/// PDFKit view for the preview; keeps the scroll position when the document is replaced after a rebuild.
private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = NSColor(PB.surface)
        v.document = PDFDocument(data: data)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        guard v.document?.dataRepresentation() != data else { return }
        let point = v.currentDestination
        v.document = PDFDocument(data: data)
        if let point { v.go(to: point) }
    }
}
#endif
