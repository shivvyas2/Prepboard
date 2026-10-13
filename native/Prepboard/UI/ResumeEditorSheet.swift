#if os(macOS)
import AppKit
import SwiftUI

/// Last-minute edits to a tailored .tex: save and rebuild the PDF, re-check the claims, or hand the file to Finder or an editor.
/// Save is the explicit step; Close never asks about unsaved changes.
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

    private var path: String? { hunt.texPath(for: lead) }
    private var dirty: Bool { loaded && text != saved }
    private var canAct: Bool { loaded && !working && !hunt.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s4) {
            HStack {
                Text("Edit résumé · \(lead.variantName).tex" + (dirty ? " • edited" : ""))
                    .font(.system(size: 18, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 420)
                .padding(PB.s2)
                .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.surface))
                .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line))
            Text("Claims you add here are only re-checked when you press Re-check claims.")
                .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            if !buildLog.isEmpty {
                ScrollView {
                    Text(buildLog).font(.pbMono).foregroundStyle(PB.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
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
        }
        .padding(PB.s6)
        .background(PB.card)
        .frame(minWidth: 760, idealWidth: 840, minHeight: 640, idealHeight: 820)
        .onAppear(perform: load)
    }

    private func load() {
        guard let path, let file = try? String(contentsOfFile: path, encoding: .utf8) else {
            footer = "Couldn't read \(lead.variantName).tex"; return
        }
        text = file; saved = file; loaded = true
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
#endif
