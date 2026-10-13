import SwiftData
import SwiftUI

/// Applications / Hunt: every job the Mac found, grouped by what happens next.
struct HuntView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Lead.score, order: .reverse), SortDescriptor(\Lead.foundAt, order: .reverse)]) private var leads: [Lead]
    @Query(filter: #Predicate<Doc> { $0.fileType == "pdf" }) private var pdfs: [Doc]
    @Query private var settingsRows: [HuntSettings]
    @State private var showSettings = false
    @State private var showSkipped = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PB.s4) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: PB.s1) {
                        Text("Applications").pbLabelStyle()
                        Text("Hunt").font(.pbDisplay).kerning(-1.4)
                    }
                    Spacer()
                    Button("Settings") { showSettings = true }.buttonStyle(PillButtonStyle(filled: false))
                }
                #if os(macOS)
                HuntBrowserCard()
                if let settings { HuntRunCard(settings: settings) }
                #endif
                if leads.isEmpty {
                    Text("No jobs found yet. Run the hunt on your Mac.").foregroundStyle(PB.muted)
                        .frame(maxWidth: .infinity).padding(PB.s8).pbCard()
                }
                group("Ready to submit", leads.filter { $0.status == .ready })
                group("Needs you", leads.filter { $0.status == .needsYou })
                group("Failed", leads.filter { $0.status == .failed })
                group("In progress", leads.filter { [.new, .tailoring, .submitting].contains($0.status) })
                group("Submitted", leads.filter { $0.status == .submitted })
                group("Skipped", leads.filter { $0.status == .skipped }, collapsed: !showSkipped) {
                    Button(showSkipped ? "Hide" : "Show") { showSkipped.toggle() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            }
            .padding(.bottom, PB.s8)
        }
        .scrollIndicators(.hidden)
        .task { if settingsRows.isEmpty { _ = HuntSettings.current(context) } }
        .sheet(isPresented: $showSettings) { if let settings { HuntSettingsSheet(settings: settings) } }
    }

    private var settings: HuntSettings? { settingsRows.first }

    private func group(_ title: String, _ items: [Lead]) -> some View { group(title, items, collapsed: false) { EmptyView() } }

    @ViewBuilder
    private func group<T: View>(_ title: String, _ items: [Lead], collapsed: Bool, @ViewBuilder trailing: @escaping () -> T) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: title, count: "\(items.count)", trailing: trailing)
                if !collapsed {
                    VStack(spacing: PB.s3) {
                        ForEach(items) { lead in LeadCard(lead: lead, pdfDoc: pdfs.first { $0.id == lead.pdfDocId }) }
                    }
                }
            }
            .pbCard()
        }
    }
}

/// One discovered job: match, base résumé, JD coverage, planned answers and the review actions.
struct LeadCard: View {
    let lead: Lead
    let pdfDoc: Doc?
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(JobHunt.self) private var hunt
    @Environment(ClaudeCode.self) private var claude
    #endif
    @State private var showPDF = false
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            VStack(alignment: .leading, spacing: PB.s1) {
                Text("\(lead.company) — \(lead.title)").font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !lead.location.isEmpty { Text(lead.location).font(.system(size: 12)).foregroundStyle(PB.muted) }
            }
            FlowLayout(spacing: PB.s2) {
                Chip(text: "Score \(lead.score)", style: lead.score >= 80 ? .dark : .plain)
                Chip(text: sourceName)
                if let s = statusLabel { Chip(text: s, style: lead.status == .failed ? .red : .plain) }
            }
            if !lead.scoreReason.isEmpty {
                Text(lead.scoreReason).font(.system(size: 13)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if !lead.reason.isEmpty {
                Text(lead.reason).font(.system(size: 12)).foregroundStyle(lead.status == .failed ? PB.red : PB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !lead.baseVariant.isEmpty {
                VStack(alignment: .leading, spacing: PB.s1) {
                    Text("Based on \(lead.baseVariant)").font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if !lead.baseReason.isEmpty {
                        Text(lead.baseReason).font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let coverage = lead.coverage
            if !coverage.isEmpty {
                FlowLayout(spacing: PB.s2) {
                    ForEach(Array(coverage.enumerated()), id: \.offset) { Chip(text: $0.element.term, style: $0.element.covered ? .dark : .plain) }
                }
            }
            if !lead.flagged.isEmpty {
                VStack(alignment: .leading, spacing: PB.s1) {
                    ForEach(lead.flagged.split(separator: "\n").map(String.init), id: \.self) { line in
                        Text(line).font(.system(size: 12)).foregroundStyle(PB.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            answers
            actions
        }
        .padding(PB.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous).strokeBorder(PB.line))
        .sheet(isPresented: $showPDF) { if let pdfDoc { ResumeSheet(doc: pdfDoc) } }
        #if os(macOS)
        .sheet(isPresented: $showEditor) { ResumeEditorSheet(lead: lead) }
        #endif
    }

    @ViewBuilder
    private var answers: some View {
        let list = lead.answers
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: PB.s2) {
                Text("Answers").font(.system(size: 13, weight: .semibold)).padding(.top, PB.s1)
                ForEach(list.indices, id: \.self) { i in AnswerField(answer: list[i], text: answer(i)) }
            }
        }
    }

    /// Writes one answer back into `answersJSON`; a filled-in needs_you answer becomes a drafted one, so Submit can unlock.
    private func answer(_ i: Int) -> Binding<String> {
        Binding(get: { lead.answers.indices.contains(i) ? lead.answers[i].answer : "" },
                set: { value in
                    var all = lead.answers
                    guard all.indices.contains(i) else { return }
                    all[i].answer = value
                    if all[i].kind == "needs_you", !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { all[i].kind = "drafted" }
                    lead.answers = all
                })
    }

    private var actions: some View {
        FlowLayout(spacing: PB.s2) {
            if lead.status == .ready || lead.status == .needsYou {
                Button(lead.submitRequested ? "Queued for your Mac" : "Submit", action: submit)
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!lead.canSubmit || lead.submitRequested)
            }
            if lead.status == .submitted, !lead.roleId.isEmpty {
                Button("Open role") { app.openRole(lead.roleId) }.buttonStyle(PillButtonStyle(compact: true))
            }
            if pdfDoc != nil {
                Button("Résumé") { showPDF = true }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            if let url = URL(string: lead.link), !lead.link.isEmpty {
                Button("Open posting") { openURL(url) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            #if os(macOS)
            if ![.submitted, .submitting, .tailoring].contains(lead.status) {
                Button("Regenerate") {
                    lead.submitRequested = false; lead.updatedAt = .now
                    Task { await hunt.tailor(lead) }
                }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    .disabled(!claude.isReady || hunt.isRunning)
            }
            // Last-minute edits to the .tex; the rebuilt PDF is what Submit uploads. Opening the editor takes the lead out of the
            // queue (like Regenerate), so nothing goes out until the user presses Submit on what they edited.
            if !lead.variantName.isEmpty, [.ready, .needsYou, .failed].contains(lead.status) {
                Button("Edit résumé") {
                    if lead.submitRequested { lead.submitRequested = false; lead.updatedAt = .now }
                    showEditor = true
                }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    .disabled(hunt.isRunning)
            }
            #endif
            if ![.submitted, .submitting, .skipped].contains(lead.status) {
                Button("Skip") {
                    lead.status = .skipped; lead.reason = "Skipped by you"; lead.submitRequested = false; lead.updatedAt = .now
                }
                .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
        }
        .padding(.top, PB.s1)
    }

    /// Queues the submit for the Mac; the Mac itself submits right away when Claude Code is ready and the hunt is idle.
    private func submit() {
        if lead.status == .needsYou { lead.status = .ready; lead.flagged = "" }
        lead.submitRequested = true
        lead.updatedAt = .now
        #if os(macOS)
        if claude.isReady, !hunt.isRunning, !claude.busy { Task { await hunt.submit(lead) } }   // else the queue timer picks it up

        #endif
    }

    private var sourceName: String {
        switch lead.source {
        case "linkedin-rec": "LinkedIn recommended"
        case "linkedin-search": "LinkedIn search"
        case "careers": "Careers site"
        default: lead.source.isEmpty ? "Unknown source" : lead.source
        }
    }

    private var statusLabel: String? {
        switch lead.status {
        case .ready: nil
        case .new: "New"
        case .tailoring: "Tailoring"
        case .needsYou: "Needs you"
        case .submitting: "Submitting"
        case .submitted: "Submitted"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

/// One planned form answer, styled like PBTextField; the label turns red while the question still needs the user.
private struct AnswerField: View {
    let answer: FormAnswer
    @Binding var text: String

    var body: some View {
        let needsYou = answer.kind == "needs_you"
        VStack(alignment: .leading, spacing: PB.s1) {
            Text(answer.question + (answer.required ? " (required)" : ""))
                .font(.pbLabel).kerning(0.9).textCase(.uppercase)
                .foregroundStyle(needsYou ? PB.red : PB.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField(answer.question, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, PB.s3).padding(.vertical, PB.s3)
                .background(RoundedRectangle(cornerRadius: 12).fill(PB.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(needsYou ? PB.red.opacity(0.5) : PB.line))
        }
    }
}

/// The tailored PDF in a sheet, through the same viewer as Documents.
private struct ResumeSheet: View {
    let doc: Doc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s4) {
            HStack {
                Text(doc.title.isEmpty ? "Résumé" : doc.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
            }
            PDFDocView(doc: doc).frame(maxHeight: .infinity)
        }
        .padding(PB.s6)
        .background(PB.card)
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 820)
        #endif
        .presentationDetents([.large])
    }
}

/// Hunt settings: where to look, when to run, limits, the résumé folder, the Answer Bank and the scanned variants.
struct HuntSettingsSheet: View {
    @Bindable var settings: HuntSettings
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(JobHunt.self) private var hunt
    @Environment(HuntBrowser.self) private var huntBrowser
    @Environment(ClaudeCode.self) private var claude
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @AppStorage("hunt.browser") private var browserChoice: HuntBrowserChoice = .builtin
    @State private var linkedInEmail = ""
    @State private var linkedInPassword = ""
    @State private var linkedInSaved = LinkedInSignIn.hasCredentials
    @State private var linkedInOutcome = ""
    @State private var signingIn = false
    #endif
    @State private var regions: String
    @State private var companies: String
    @State private var keywords: String
    @State private var minScore: String
    @State private var tailorLimit: String
    @State private var submitLimit: String

    init(settings: HuntSettings) {
        _settings = Bindable(wrappedValue: settings)
        _regions = State(initialValue: settings.regions.joined(separator: "\n"))
        _companies = State(initialValue: settings.companies.joined(separator: "\n"))
        _keywords = State(initialValue: settings.keywords.joined(separator: "\n"))
        _minScore = State(initialValue: String(settings.minScore))
        _tailorLimit = State(initialValue: String(settings.dailyTailorLimit))
        _submitLimit = State(initialValue: String(settings.dailySubmitLimit))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PB.s6) {
                HStack {
                    Text("Hunt settings").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                section("Where to look") {
                    PBTextField(label: "Regions, one per line or comma-separated", text: $regions, axis: .vertical)
                    PBTextField(label: "Companies, one per line (name | careers URL)", text: $companies, axis: .vertical)
                    PBTextField(label: "Keywords, one per line or comma-separated", text: $keywords, axis: .vertical)
                }
                section("Schedule and limits") {
                    HStack(spacing: PB.s3) {
                        Toggle("Run daily at", isOn: $settings.auto).toggleStyle(CheckboxToggleStyle(labeled: true))
                        Picker("", selection: $settings.runHour) {
                            ForEach(0..<24, id: \.self) { Text(TimeFmt.hour($0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).tint(PB.ink)
                        Spacer(minLength: 0)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: PB.s3)], alignment: .leading, spacing: PB.s3) {
                        PBTextField(label: "Min score (0-100)", text: $minScore)
                        PBTextField(label: "Résumés per day", text: $tailorLimit)
                        PBTextField(label: "Submits per day", text: $submitLimit)
                    }
                }
                #if os(macOS)
                section("Browser for heavy runs") {
                    Picker("Browser", selection: $browserChoice) {
                        Text("Built-in browser").tag(HuntBrowserChoice.builtin)
                        Text("Chrome with the Claude extension").tag(HuntBrowserChoice.chrome)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("Discovery and submitting run there; the LinkedIn sync always uses the built-in browser. Chrome must be open with the Claude in Chrome extension connected.")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                }
                linkedInSection
                section("Résumé folder") {
                    HStack(spacing: PB.s2) {
                        Text(settings.resumeFolder).font(.system(size: 12, design: .monospaced)).foregroundStyle(PB.ink2)
                            .lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Choose…") { chooseFolder() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    }
                }
                #endif
                section("Answer Bank") {
                    Text("Legal answers are filled only from here, never drafted. Leave a field empty to decline.")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: PB.s3)], alignment: .leading, spacing: PB.s3) {
                        PBTextField(label: "Full name", text: bank(\.fullName))
                        PBTextField(label: "Email", text: bank(\.email))
                        PBTextField(label: "Phone", text: bank(\.phone))
                        PBTextField(label: "City", text: bank(\.city))
                        PBTextField(label: "LinkedIn", text: bank(\.linkedin))
                        PBTextField(label: "GitHub", text: bank(\.github))
                        PBTextField(label: "Portfolio", text: bank(\.portfolio))
                        PBTextField(label: "Work authorization", text: bank(\.workAuthorization))
                        PBTextField(label: "Needs sponsorship (Yes / No)", text: bank(\.needsSponsorship))
                        PBTextField(label: "Start date", text: bank(\.startDate))
                        PBTextField(label: "Relocation (Yes / No / Open to it)", text: bank(\.relocation))
                        PBTextField(label: "Salary expectation", text: bank(\.salary))
                        PBTextField(label: "Gender", text: bank(\.gender))
                        PBTextField(label: "Race / ethnicity", text: bank(\.race))
                        PBTextField(label: "Veteran status", text: bank(\.veteran))
                        PBTextField(label: "Disability status", text: bank(\.disability))
                    }
                }
                #if os(macOS)
                variantsSection
                #endif
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(PB.s6)
        }
        .scrollIndicators(.hidden)
        .background(PB.card)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .presentationDetents([.large])
        .onChange(of: regions) { settings.regions = lines(regions, commas: true) }
        .onChange(of: companies) { settings.companies = lines(companies) }
        .onChange(of: keywords) { settings.keywords = lines(keywords, commas: true) }
        .onChange(of: minScore) { if let v = Int(minScore.trimmingCharacters(in: .whitespaces)) { settings.minScore = min(100, max(0, v)) } }
        .onChange(of: tailorLimit) { if let v = Int(tailorLimit.trimmingCharacters(in: .whitespaces)) { settings.dailyTailorLimit = max(0, v) } }
        .onChange(of: submitLimit) { if let v = Int(submitLimit.trimmingCharacters(in: .whitespaces)) { settings.dailySubmitLimit = max(0, v) } }
    }

    /// One entry per line; with `commas`, commas split too (companies keep the "name | url" form, so newline only).
    private func lines(_ text: String, commas: Bool = false) -> [String] {
        text.split { $0 == "\n" || (commas && $0 == ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func bank(_ kp: WritableKeyPath<AnswerBank, String>) -> Binding<String> {
        Binding(get: { settings.answerBank[keyPath: kp] },
                set: { value in var b = settings.answerBank; b[keyPath: kp] = value; settings.answerBank = b })
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<T: View, C: View>(_ title: String, @ViewBuilder trailing: () -> T, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            HStack(spacing: PB.s3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                trailing()
            }
            content()
        }
    }

    #if os(macOS)
    /// The stored LinkedIn sign-in: Keychain only, typed into LinkedIn's page by PrepBoard itself, never shown to Claude.
    private var linkedInSection: some View {
        section("LinkedIn sign-in") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: PB.s3)], alignment: .leading, spacing: PB.s3) {
                PBTextField(label: "Email", text: $linkedInEmail)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password").pbLabelStyle()
                    SecureField("Password", text: $linkedInPassword)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                }
            }
            HStack(spacing: PB.s2) {
                Button("Save") {
                    LinkedInSignIn.save(email: linkedInEmail.trimmingCharacters(in: .whitespacesAndNewlines), password: linkedInPassword)
                    linkedInPassword = ""
                    linkedInSaved = LinkedInSignIn.hasCredentials
                    linkedInOutcome = ""
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(linkedInEmail.trimmingCharacters(in: .whitespaces).isEmpty || linkedInPassword.isEmpty)
                if linkedInSaved {
                    Button("Remove") {
                        LinkedInSignIn.remove()
                        linkedInSaved = LinkedInSignIn.hasCredentials
                        linkedInOutcome = ""
                    }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    // Never while a Claude run drives the browser: the sign-in would take its page and leave the email in the form.
                    Button("Sign in now") {
                        guard !claude.busy else { return }
                        signingIn = true
                        Task {
                            let outcome = await LinkedInSignIn.signIn(huntBrowser)
                            linkedInOutcome = switch outcome {
                            case .signedIn: "Signed in to LinkedIn"
                            case .noCredentials: "Save your email and password first"
                            case .needsYou(let m), .failed(let m): m
                            }
                            signingIn = false
                        }
                    }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    .disabled(hunt.isRunning || claude.busy || signingIn)
                }
                if signingIn { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Text(linkedInSaved ? "Saved in this Mac's Keychain" : "Not saved").font(.system(size: 12)).foregroundStyle(PB.muted)
            }
            if !linkedInOutcome.isEmpty {
                Text(linkedInOutcome).font(.system(size: 12)).foregroundStyle(linkedInOutcome == "Signed in to LinkedIn" ? PB.muted : PB.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("PrepBoard types these into LinkedIn's sign-in page itself; Claude never sees them. If LinkedIn asks for a code or a check, finish it in the Browser card.")
                .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var variantsSection: some View {
        section("Résumé variants", trailing: {
            Button("Rescan") { hunt.rescan() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
        }) {
            if hunt.variants.isEmpty {
                Text("No .tex files found in the résumé folder.").font(.system(size: 12)).foregroundStyle(PB.muted)
            }
            let winners = ResumeLibrary.winners(roles: roles)
            ForEach(hunt.variants) { v in
                HStack(spacing: PB.s3) {
                    VStack(alignment: .leading, spacing: PB.s1) {
                        Text(v.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text([v.family, v.company].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(PB.muted)
                    }
                    Spacer(minLength: PB.s2)
                    Text(outcome(v.name, winners: winners)).font(.pbMono)
                        .foregroundStyle(winners.contains(v.name) ? PB.cobalt : PB.muted)
                }
                .padding(.vertical, PB.s1)
            }
        }
    }

    /// Winner, else the furthest stage a role sent with this variant reached, else a dash.
    private func outcome(_ name: String, winners: Set<String>) -> String {
        if winners.contains(name) { return "★ Winner" }
        return roles.filter { $0.resumeVariant == name }.map(\.stage).max { $0.index < $1.index }?.rawValue ?? "—"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.resumeFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.resumeFolder = url.path
        hunt.rescan()
    }
    #endif
}

#if os(macOS)
import WebKit

/// The built-in browser the hunt drives: watch a run here, step in when a page needs you, or sign in to LinkedIn once.
struct HuntBrowserCard: View {
    @Environment(HuntBrowser.self) private var browser
    @Environment(JobHunt.self) private var hunt
    @Environment(ClaudeCode.self) private var claude
    @AppStorage("hunt.browser") private var browserChoice: HuntBrowserChoice = .builtin
    @State private var address = ""
    @State private var expanded = false
    @State private var chosen = false   // the user toggled it by hand; their choice holds for the session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Browser") {
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button(expanded ? "Hide" : "Show") { chosen = true; expanded.toggle() }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            Text(subtitle).font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1).truncationMode(.middle)
                .padding(.bottom, expanded ? PB.s3 : 0)
            if expanded {
                HStack(spacing: PB.s2) {
                    TextField("https://", text: $address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, PB.s3).frame(height: PB.controlHeight(compact: true))
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                        .onSubmit(go)
                    Button("Go", action: go).buttonStyle(PillButtonStyle(compact: true))
                    Button("Back") { Task { try? await browser.back() } }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    Button("Sign in to LinkedIn", action: signIn).buttonStyle(PillButtonStyle(filled: false, compact: true))
                        .disabled(claude.busy)   // a run (hunt or sync) owns the page meanwhile
                }
                .padding(.bottom, PB.s3)
                HuntWebViewHost(webView: browser.webView)
                    .frame(height: 520)
                    .clipShape(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line))
            }
        }
        .pbCard(padding: PB.s4)
        .onAppear { if !chosen { expanded = hunt.isRunning && !hunt.usingChrome }; address = browser.url?.absoluteString ?? "" }
        // A run in Chrome has nothing to show here, so it does not pull the card open.
        .onChange(of: hunt.isRunning) { if hunt.isRunning { if !hunt.usingChrome { expanded = true } } else if !chosen { expanded = false } }
        .onChange(of: browser.url) { address = browser.url?.absoluteString ?? "" }
    }

    /// Title and URL of the current page, then what the hunt last did on it.
    private var subtitle: String {
        let page = [browser.title, browser.url?.absoluteString ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let line = [page, browser.lastAction].filter { !$0.isEmpty }.joined(separator: " — ")
        if !line.isEmpty { return line }
        return browserChoice == .chrome ? "Heavy runs use Chrome; the LinkedIn sync still uses this browser."
            : "Sign in to LinkedIn here once; the hunt and the LinkedIn sync use this browser."
    }

    private func go() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        load(text.contains("://") ? text : "https://" + text)
    }

    private func load(_ string: String) {
        guard let url = URL(string: string) else { return }
        Task { try? await browser.navigate(url) }
    }

    /// With a saved sign-in PrepBoard fills the form itself (the outcome shows in the subtitle through `lastAction`);
    /// without one the sign-in page opens for the user.
    private func signIn() {
        guard !claude.busy else { return }
        guard LinkedInSignIn.hasCredentials else { return load("https://www.linkedin.com/login") }
        chosen = true; expanded = true
        Task { _ = await LinkedInSignIn.signIn(browser) }
    }
}

private struct HuntWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> HuntWebViewContainer { HuntWebViewContainer(webView: webView) }
    func updateNSView(_ v: HuntWebViewContainer, context: Context) { v.adoptIfFree() }
}

/// Hosts the one shared web view. When Hunt is open in two windows the view follows the window that showed it last,
/// and comes back to the surviving card when that window closes, instead of leaving a blank card behind.
final class HuntWebViewContainer: NSView {
    let webView: WKWebView
    private var observer: NSObjectProtocol?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let closing = n.object as? NSWindow, closing !== self.window, self.webView.window === closing else { return }
                self.adopt()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { adopt() }
    }

    override func layout() {
        super.layout()
        if webView.superview === self { webView.frame = bounds }
    }

    /// Takes the web view when nobody on screen is showing it.
    func adoptIfFree() {
        guard window != nil, webView.superview !== self, webView.window?.isVisible != true else { return }
        adopt()
    }

    private func adopt() {
        guard window != nil, webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

/// Hunt status, the daily schedule and the manual controls (like JobSyncCard).
struct HuntRunCard: View {
    @Bindable var settings: HuntSettings
    @Environment(JobHunt.self) private var hunt
    @Environment(ClaudeCode.self) private var claude

    var body: some View {
        HStack(alignment: .center, spacing: PB.s3) {
            VStack(alignment: .leading, spacing: PB.s1) {
                Text("Daily hunt").font(.system(size: 14, weight: .semibold))
                Text(status).font(.system(size: 12)).foregroundStyle(hunt.error == nil || hunt.isRunning ? PB.muted : PB.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PB.s2)
            Toggle("Run daily at", isOn: $settings.auto).toggleStyle(.checkbox).font(.system(size: 12))
            Picker("", selection: $settings.runHour) {
                ForEach(0..<24, id: \.self) { Text(TimeFmt.hour($0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button("Rescan résumés") { hunt.rescan() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            if hunt.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Run now") { Task { await hunt.run() } }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!claude.isReady || hunt.isRunning || claude.busy)
            }
        }
        .pbCard(padding: PB.s4)
    }

    private var status: String {
        switch hunt.phase {
        case .discovering: return hunt.usingChrome ? "Looking for jobs in Chrome… this can take a while." : "Looking for jobs in the browser above… this can take a while."
        case .tailoring(let done, let total): return "Tailoring résumés… \(done) of \(total) done."
        case .submitting(let name): return "Submitting to \(name)…"
        case .honesty(let name): return "Checking the claims in \(name)…"
        case .editing(let name): return "Rebuilding the résumé for \(name)…"
        case .idle: break
        }
        if let e = hunt.error { return e }
        if !claude.isReady { return "Connect Claude Code in Profile to run the hunt." }
        guard let last = hunt.lastRun else { return "Finds jobs, tailors a résumé for each and fills the application. Not run yet." }
        return "Last run \(last.formatted(.relative(presentation: .named)))" + (hunt.lastSummary.map { " · \($0)" } ?? "")
    }
}
#endif
