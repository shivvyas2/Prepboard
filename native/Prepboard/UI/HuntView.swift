import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Applications / Hunt: every job the Mac found, grouped by what happens next.
struct HuntView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Lead.score, order: .reverse), SortDescriptor(\Lead.foundAt, order: .reverse)]) private var leads: [Lead]
    @Query(filter: #Predicate<Doc> { $0.fileType == "pdf" }) private var pdfs: [Doc]
    @Query private var settingsRows: [HuntSettings]
    @State private var showSettings = false
    @State private var showSkipped = false
    @State private var filter: HuntFilter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PB.s4) {
                header
                #if os(macOS)
                if let settings { HuntRunCard(settings: settings) }
                HuntBrowserCard()
                #endif
                if leads.isEmpty {
                    emptyState
                } else {
                    filters
                    if !leads.contains(where: filter.includes) {
                        VStack(alignment: .leading, spacing: PB.s2) {
                            Text("Nothing here yet").font(.system(size: 16, weight: .semibold))
                            Text(filter.emptyMessage).font(.system(size: 13)).foregroundStyle(PB.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Show all roles") { filter = .all }
                                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                        }
                        .pbCard(padding: PB.s4)
                    }
                    group("Ready to review", items(.ready))
                    group("Needs your input", items(.needsYou))
                    group("Needs another try", items(.failed))
                    group("In progress", leads.filter { filter.includes($0) && [.new, .tailoring, .submitting].contains($0.status) })
                    group("Submitted", items(.submitted))
                    group("Skipped", items(.skipped), collapsed: filter == .all && !showSkipped) {
                        if filter == .all {
                            Button(showSkipped ? "Hide" : "Show") { showSkipped.toggle() }
                                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, PB.s8)
        }
        .scrollIndicators(.hidden)
        .task { if settingsRows.isEmpty { _ = HuntSettings.current(context) } }
        .onAppear(perform: openFromHome)
        .onChange(of: app.huntShowNeedsYou) { openFromHome() }
        .onChange(of: app.huntShowSettings) { openFromHome() }
        .sheet(isPresented: $showSettings) { if let settings { HuntSettingsSheet(settings: settings) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            HStack(alignment: .center, spacing: PB.s3) {
                VStack(alignment: .leading, spacing: PB.s1) {
                    Text("Applications").pbLabelStyle()
                    Text("Hunt").font(.pbDisplay).kerning(-1.4)
                }
                Spacer(minLength: 0)
                Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            #if os(iOS)
            Label("Your Mac finds roles and submits what you queue here.", systemImage: "desktopcomputer")
                .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: PB.s2) {
            FlowLayout(spacing: PB.s2) {
                ForEach(HuntFilter.allCases) { item in
                    Button { filter = item } label: {
                        HStack(spacing: PB.s2) {
                            Text(item.rawValue)
                            Text("\(leads.filter(item.includes).count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(filter == item ? Color.white.opacity(0.2) : PB.surface))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(filter == item ? Color.white : PB.ink2)
                        .padding(.horizontal, PB.s3)
                        .frame(minHeight: max(36, PB.minTap))
                        .background(Capsule().fill(filter == item ? PB.cobalt : PB.card))
                        .overlay(Capsule().strokeBorder(filter == item ? PB.cobalt : PB.line2))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.rawValue), \(leads.filter(item.includes).count) roles")
                    .accessibilityAddTraits(filter == item ? [.isSelected] : [])
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 28)).foregroundStyle(PB.cobalt)
            Text("No roles yet").font(.system(size: 19, weight: .semibold))
            Text("Add target roles and a résumé folder in Settings, then run the hunt on your Mac.")
                .font(.system(size: 14)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
            Button("Set up your search") { showSettings = true }.buttonStyle(PillButtonStyle(compact: true))
        }
        .pbCard(padding: PB.s6)
    }

    private var settings: HuntSettings? { settingsRows.first }

    /// Home's "Needs you" card sends the user here on the right filter, or straight into the Answer Bank.
    private func openFromHome() {
        if app.huntShowNeedsYou { filter = .needsYou; app.huntShowNeedsYou = false }
        if app.huntShowSettings { app.huntShowSettings = false; if settings == nil { _ = HuntSettings.current(context) }; showSettings = true }
    }

    private func items(_ status: LeadStatus) -> [Lead] {
        leads.filter { $0.status == status && filter.includes($0) }
    }

    private func group(_ title: String, _ items: [Lead]) -> some View { group(title, items, collapsed: false) { EmptyView() } }

    @ViewBuilder
    private func group<T: View>(_ title: String, _ items: [Lead], collapsed: Bool, @ViewBuilder trailing: @escaping () -> T) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: title, count: "\(items.count)", trailing: trailing)
                if !collapsed {
                    LazyVStack(spacing: PB.s3) {
                        ForEach(items) { lead in LeadCard(lead: lead, pdfDoc: pdfs.first { $0.id == lead.pdfDocId }) }
                    }
                }
            }
            .pbCard(padding: PB.s4)
        }
    }
}

private enum HuntFilter: String, CaseIterable, Identifiable {
    case all = "All", review = "Review", needsYou = "Needs you", active = "In progress", submitted = "Submitted", skipped = "Skipped"
    var id: String { rawValue }

    func includes(_ lead: Lead) -> Bool {
        switch self {
        case .all: true
        case .review: lead.status == .ready
        case .needsYou: [.needsYou, .failed].contains(lead.status)
        case .active: [.new, .tailoring, .submitting].contains(lead.status)
        case .submitted: lead.status == .submitted
        case .skipped: lead.status == .skipped
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Run a search on your Mac to find matching roles."
        case .review: "Tailored applications will appear here when they’re ready for your review."
        case .needsYou: "No applications need your input right now."
        case .active: "No applications are being prepared or submitted right now."
        case .submitted: "Applications you’ve sent will appear here, with a link to track each role."
        case .skipped: "Roles you skip will stay here for reference."
        }
    }
}

/// One discovered job: match, base résumé, JD coverage, planned answers and the review actions.
struct LeadCard: View {
    let lead: Lead
    let pdfDoc: Doc?
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(JobHunt.self) private var hunt
    @Environment(ClaudeCode.self) private var claude
    @AppStorage("hunt.browser") private var browserChoice: HuntBrowserChoice = .builtin
    @AppStorage(HuntPrefs.resumePDFKey) private var resumePDF = ""
    #endif
    @State private var showPDF = false
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            VStack(alignment: .leading, spacing: PB.s1) {
                Text(lead.company).font(.system(size: 12, weight: .semibold)).foregroundStyle(PB.cobalt)
                    .fixedSize(horizontal: false, vertical: true)
                Text(lead.title).font(.system(size: 17, weight: .semibold))
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
            if ![.submitted, .submitting, .skipped].contains(lead.status) { choices }
            answers
            if let reviewHint {
                Label(reviewHint, systemImage: lead.submitRequested ? "clock" : "checklist")
                    .font(.system(size: 12)).foregroundStyle(PB.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(PB.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: PB.rMD).fill(PB.cobaltSoft))
            }
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

    /// This role's own decisions; each overrides the Answer Bank for this application only.
    private var choices: some View {
        let bank = HuntSettings.current(context).answerBank
        return VStack(alignment: .leading, spacing: PB.s2) {
            Text("Your choices for this role").font(.system(size: 13, weight: .semibold)).padding(.top, PB.s1)
            FlowLayout(spacing: PB.s2) {
                choicePicker("Relocate", .relocate, options: ["Yes", "No", "Open to it"], fallback: bank.relocation)
                choicePicker("Onsite / hybrid", .onsite, options: ["Yes", "No"], fallback: "")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: PB.s2)], alignment: .leading, spacing: PB.s2) {
                PBTextField(label: "Salary" + (bank.salary.isEmpty ? "" : " (default \(bank.salary))"), text: choiceText(.salary))
                PBTextField(label: "Start date" + (bank.startDate.isEmpty ? "" : " (default \(bank.startDate))"), text: choiceText(.startDate))
            }
        }
    }

    private func choicePicker(_ title: String, _ c: Lead.Choice, options: [String], fallback: String) -> some View {
        Picker(title, selection: Binding(get: { lead.choice(c) ?? "" }, set: { lead.setChoice(c, $0) })) {
            Text(fallback.isEmpty ? "\(title): ask me" : "\(title): default (\(fallback))").tag("")
            ForEach(options, id: \.self) { Text("\(title): \($0)").tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().tint(PB.ink).fixedSize()
    }

    private func choiceText(_ c: Lead.Choice) -> Binding<String> {
        Binding(get: { lead.choice(c) ?? "" }, set: { lead.setChoice(c, $0) })
    }

    @ViewBuilder
    private var answers: some View {
        let list = lead.answers.indices.filter { lead.answers[$0].kind != "choice" }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: PB.s2) {
                Text("Application answers").font(.system(size: 13, weight: .semibold)).padding(.top, PB.s1)
                ForEach(list, id: \.self) { i in AnswerField(answer: lead.answers[i], text: answer(i)) }
            }
        }
    }

    /// Writes one answer back into `answersJSON`; a filled-in needs_you answer becomes the user's own ("yours"), so Submit can unlock
    /// and the answer is remembered in the Answer Bank for the next form that asks.
    private func answer(_ i: Int) -> Binding<String> {
        Binding(get: { lead.answers.indices.contains(i) ? lead.answers[i].answer : "" },
                set: { value in
                    var all = lead.answers
                    guard all.indices.contains(i) else { return }
                    all[i].answer = value
                    if all[i].kind == "needs_you", !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { all[i].kind = "yours" }
                    lead.answers = all
                    lead.updatedAt = .now
                })
    }

    private var actions: some View {
        FlowLayout(spacing: PB.s2) {
            if lead.status == .ready || lead.status == .needsYou {
                Button(lead.submitRequested ? "Queued for your Mac" : "Submit application", action: submit)
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!lead.canSubmit || lead.submitRequested)
                    #if os(macOS)
                    .disabled(hunt.isOpeningChrome)
                    #endif
                if lead.submitRequested {
                    Button("Cancel queue") { lead.submitRequested = false; lead.updatedAt = .now }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            }
            #if os(macOS)
            if lead.answers.contains(where: { $0.kind == "needs_you" }), ![.submitted, .submitting, .tailoring].contains(lead.status) {
                Button("Draft answers with Claude") {
                    if lead.submitRequested { lead.submitRequested = false; lead.updatedAt = .now }
                    Task {
                        let n = await hunt.draftAnswers(lead)
                        app.message = n == 0 ? (hunt.error ?? "Nothing to draft: the remaining questions are legal or need your own answer.")
                            : "Drafted \(n) answer\(n == 1 ? "" : "s") for \(lead.company). Review them before submitting."
                    }
                }
                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                .disabled(!claude.isReady || hunt.isRunning || claude.busy)
            }
            #endif
            if lead.status == .submitted, !lead.roleId.isEmpty {
                Button("Open role") { app.openRole(lead.roleId) }.buttonStyle(PillButtonStyle(compact: true))
            }
            if pdfDoc != nil {
                Button("Review résumé") { showPDF = true }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            if let url = URL(string: lead.link), !lead.link.isEmpty {
                #if os(macOS)
                Button(browserChoice == .chrome ? "Open in Chrome" : "Open posting") {
                    if browserChoice == .chrome {
                        Task { if !(await hunt.openChrome(url.absoluteString)) { app.message = hunt.chromeStatus } }
                    } else { openURL(url) }
                }
                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                .disabled(hunt.isOpeningChrome)
                #else
                Button("Open posting") { openURL(url) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                #endif
            }
            #if os(macOS)
            if ![.submitted, .submitting, .tailoring].contains(lead.status) {
                Button(lead.variantName.isEmpty ? (resumePDF.isEmpty ? "Prepare application" : "Tailor résumé") : "Regenerate") {
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

    private var reviewHint: String? {
        guard [.ready, .needsYou].contains(lead.status) else { return nil }
        if lead.submitRequested { return "Your Mac will submit this when Claude is available. You can cancel while it’s queued." }
        if !lead.canSubmit { return "Complete the highlighted answers before submitting." }
        return nil
    }

    /// Queues the submit for the Mac; the Mac itself submits right away when Claude Code is ready and the hunt is idle.
    private func submit() {
        rememberAnswers()
        if lead.status == .needsYou { lead.status = .ready; lead.flagged = "" }
        lead.submitRequested = true
        lead.updatedAt = .now
        #if os(macOS)
        if claude.isReady, !hunt.isRunning, !claude.busy { Task { await hunt.submit(lead) } }   // else the queue timer picks it up

        #endif
    }

    /// Saves what the user typed into the Answer Bank, then re-fills every other waiting application with it.
    private func rememberAnswers() {
        let settings = HuntSettings.current(context)
        let bank = settings.answerBank.remembering(lead.answers, company: lead.company)
        guard bank != settings.answerBank else { return }
        settings.answerBank = bank; settings.updatedAt = .now
        let others = ((try? context.fetch(FetchDescriptor<Lead>())) ?? []).filter { $0.id != lead.id }
        let unblocked = Lead.applyBank(bank, to: others)
        if unblocked > 0 { app.message = "Saved your answers. \(unblocked) more application\(unblocked == 1 ? " is" : "s are") ready again." }
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
        case .ready: lead.submitRequested ? "Queued" : nil   // its group already says "Ready to review"
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
        let needsYou = answer.kind == "needs_you" || (answer.required && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        VStack(alignment: .leading, spacing: PB.s1) {
            Text(answer.question + (answer.required ? " (required)" : ""))
                .font(.system(size: 12, weight: .medium))
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
        .pbSheetFrame(minWidth: 440, idealWidth: 760, minHeight: 420, idealHeight: 820)
        #endif
        .presentationDetents([.large])
    }
}

/// Hunt settings: where to look, when to run, limits, the résumé folder, the Answer Bank and the scanned variants.
struct HuntSettingsSheet: View {
    @Bindable var settings: HuntSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
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
    @AppStorage(HuntPrefs.keepApplyingKey) private var keepApplying = false
    @AppStorage(HuntPrefs.resumePDFKey) private var resumePDF = ""
    @State private var fillOutcome = ""
    @State private var fillingHistory = false
    #endif
    @State private var regions: String
    @State private var companies: String
    @State private var keywords: String
    @State private var minScore: String
    @State private var tailorLimit: String
    @State private var submitLimit: String
    @State private var sponsorshipOutcome = ""

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
                applyingSection
                section("Application browser") {
                    Picker("Browser", selection: $browserChoice) {
                        Text("Built-in browser").tag(HuntBrowserChoice.builtin)
                        Text("Chrome + Claude").tag(HuntBrowserChoice.chrome)
                    }
                    .pickerStyle(.menu).labelsHidden().tint(PB.cobalt)
                    .disabled(hunt.isRunning || claude.busy || hunt.isOpeningChrome)
                    Text("Discovery and applications use this browser. Open Chrome and connect its Claude extension from the Hunt screen. LinkedIn sync always uses the built-in browser.")
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
                section("Answer Bank", trailing: {
                    #if os(macOS)
                    Button("Fill from résumé", action: fillFromResume).buttonStyle(PillButtonStyle(filled: false, compact: true))
                        .disabled(fillingHistory || hunt.isRunning || claude.busy)
                    #endif
                }) {
                    Text("Legal answers are filled only from here, never drafted. Answers you type on an application are saved here for the next one. Fill from résumé reads contact details, education and work history from your résumé and LinkedIn.")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    if !fillOutcome.isEmpty {
                        Text(fillOutcome).font(.system(size: 12)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    #endif
                    if !settings.answerBank.isComplete {
                        Label("Applications can't go out until name, email, phone, work authorization and sponsorship are filled in.",
                              systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(PB.sunInk).fixedSize(horizontal: false, vertical: true)
                    }
                    sponsorshipRow
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: PB.s3)], alignment: .leading, spacing: PB.s3) {
                        PBTextField(label: "Full name", text: bank(\.fullName))
                        PBTextField(label: "Email", text: bank(\.email))
                        PBTextField(label: "Phone", text: bank(\.phone))
                        PBTextField(label: "City", text: bank(\.city))
                        PBTextField(label: "LinkedIn", text: bank(\.linkedin))
                        PBTextField(label: "GitHub", text: bank(\.github))
                        PBTextField(label: "Portfolio", text: bank(\.portfolio))
                        PBTextField(label: "Résumé link (blank = portfolio)", text: bank(\.resumeLink))
                        PBTextField(label: "Work authorization", text: bank(\.workAuthorization))
                        PBTextField(label: "Citizenship / immigration status", text: bank(\.citizenship))
                        PBTextField(label: "Start date", text: bank(\.startDate))
                        PBTextField(label: "Relocation (Yes / No / Open to it)", text: bank(\.relocation))
                        PBTextField(label: "Salary expectation", text: bank(\.salary))
                        PBTextField(label: "Gender", text: bank(\.gender))
                        PBTextField(label: "Race / ethnicity", text: bank(\.race))
                        PBTextField(label: "Veteran status", text: bank(\.veteran))
                        PBTextField(label: "Disability status", text: bank(\.disability))
                        PBTextField(label: "How did you hear about us", text: bank(\.referralSource))
                    }
                    if [\AnswerBank.gender, \.race, \.veteran, \.disability].contains(where: { settings.answerBank[keyPath: $0].isEmpty }) {
                        Text("Empty voluntary self-identification fields are answered \u{201C}Decline to self-identify\u{201D}. Fill them in to answer every form the same way.")
                            .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Education and work").font(.system(size: 13, weight: .semibold)).padding(.top, PB.s2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: PB.s3)], alignment: .leading, spacing: PB.s3) {
                        PBTextField(label: "School", text: bank(\.school))
                        PBTextField(label: "Degree", text: bank(\.degree))
                        PBTextField(label: "Major", text: bank(\.major))
                        PBTextField(label: "Graduation", text: bank(\.graduation))
                        PBTextField(label: "GPA", text: bank(\.gpa))
                        PBTextField(label: "Current employer", text: bank(\.currentEmployer))
                        PBTextField(label: "Current title", text: bank(\.currentTitle))
                        PBTextField(label: "Years of experience", text: bank(\.yearsExperience))
                    }
                    PBTextField(label: "Education history, one per line", text: bank(\.education), axis: .vertical)
                    PBTextField(label: "Employment history, one per line", text: bank(\.employment), axis: .vertical)
                    if !settings.answerBank.saved.isEmpty {
                        Text("Saved answers (\(settings.answerBank.saved.count)): reused when a form asks the same question.")
                            .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                        ForEach(settings.answerBank.saved.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top, spacing: PB.s2) {
                                PBTextField(label: key, text: savedAnswer(key), axis: .vertical)
                                CircleIconButton(systemImage: "trash", size: 28, label: "Forget this answer") {
                                    var b = settings.answerBank; b.saved[key] = nil; settings.answerBank = b
                                }
                                .padding(.top, 20)
                            }
                        }
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
        .pbSheetFrame(minWidth: 440, idealWidth: 620, minHeight: 420, idealHeight: 720)
        #endif
        .presentationDetents([.large])
        .onDisappear { Lead.applyBank(settings.answerBank, to: (try? context.fetch(FetchDescriptor<Lead>())) ?? []) }
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

    /// One switch for sponsorship: it answers every sponsorship question and decides which fetched roles are worth applying to.
    private var sponsorshipRow: some View {
        VStack(alignment: .leading, spacing: PB.s1) {
            Toggle("I need visa sponsorship, now or in the future", isOn: Binding(
                get: { settings.answerBank.needsSponsorship == "Yes" },
                set: { on in
                    var b = settings.answerBank; b.needsSponsorship = on ? "Yes" : "No"; settings.answerBank = b; settings.updatedAt = .now
                    let n = Lead.applySponsorship(on, to: (try? context.fetch(FetchDescriptor<Lead>())) ?? [])
                    sponsorshipOutcome = n == 0 ? "" : on ? "Skipped \(n) role\(n == 1 ? "" : "s") that say they don't sponsor."
                        : "Brought back \(n) role\(n == 1 ? "" : "s") skipped for sponsorship."
                }))
                .toggleStyle(CheckboxToggleStyle(labeled: true))
            Text(settings.answerBank.needsSponsorship.isEmpty ? "Not set yet: forms that ask about sponsorship stop until you choose. Turn it on, or off to answer No."
                 : settings.answerBank.needsSponsorship == "Yes" ? "Forms get \u{201C}Yes\u{201D}. Roles that say they don't sponsor, need US citizenship or a clearance are skipped."
                 : "Forms get \u{201C}No\u{201D}. Every fetched role is considered.")
                .font(.system(size: 12)).foregroundStyle(settings.answerBank.needsSponsorship.isEmpty ? PB.sunInk : PB.muted)
                .fixedSize(horizontal: false, vertical: true)
            if settings.answerBank.needsSponsorship.isEmpty {
                Button("I don't need sponsorship") { var b = settings.answerBank; b.needsSponsorship = "No"; settings.answerBank = b }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            if !sponsorshipOutcome.isEmpty {
                Text(sponsorshipOutcome).font(.system(size: 12)).foregroundStyle(PB.ink2)
            }
        }
    }

    private func savedAnswer(_ key: String) -> Binding<String> {
        Binding(get: { settings.answerBank.saved[key] ?? "" },
                set: { value in var b = settings.answerBank; b.saved[key] = value; settings.answerBank = b })
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
    /// Which résumé goes out and whether the Mac submits on its own.
    private var applyingSection: some View {
        section("Applying") {
            Picker("Résumé to send", selection: Binding(get: { resumePDF.isEmpty ? 0 : 1 },
                                                         set: { $0 == 0 ? (resumePDF = "") : chooseResume() })) {
                Text("A tailored résumé for each job").tag(0)
                Text("My résumé for every job").tag(1)
            }
            .pickerStyle(.menu).tint(PB.cobalt).fixedSize()
            if !resumePDF.isEmpty {
                HStack(spacing: PB.s2) {
                    Image(systemName: HuntPrefs.usablePDF(resumePDF) ? "doc.richtext" : "exclamationmark.triangle")
                        .foregroundStyle(HuntPrefs.usablePDF(resumePDF) ? PB.cobalt : PB.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((resumePDF as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(resumeDetail).font(.system(size: 11)).foregroundStyle(HuntPrefs.usablePDF(resumePDF) ? PB.muted : PB.red)
                    }
                    Spacer(minLength: PB.s2)
                    Button("Choose…") { chooseResume() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                .padding(PB.s3)
                .background(RoundedRectangle(cornerRadius: PB.rMD).fill(PB.surface))
            }
            Toggle("Keep applying", isOn: $keepApplying).toggleStyle(CheckboxToggleStyle(labeled: true))
                .onChange(of: keepApplying) { hunt.keepApplyingChanged() }
            Text("Submits every ready application whose answers are complete, up to \(settings.dailySubmitLimit) a day, and searches again every few hours until then. A question your Answer Bank can't answer comes back to you instead.")
                .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resumeDetail: String {
        guard HuntPrefs.usablePDF(resumePDF) else { return "Not found. Choose the PDF again." }
        let modified = (try? FileManager.default.attributesOfItem(atPath: resumePDF)[.modificationDate]) as? Date
        return "Updated " + (modified?.formatted(date: .abbreviated, time: .omitted) ?? "unknown") + ". Replace the file to send a newer version."
    }

    /// Picks the PDF sent to every job. Files outside the home folder are copied into the résumé folder, the only place uploads come from.
    private func chooseResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: resumePDF.isEmpty ? settings.resumeFolder : (resumePDF as NSString).deletingLastPathComponent)
        panel.message = "Choose the résumé PrepBoard sends with every application"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.path
        if !BrowserServer.uploadAllowed(path) {
            let copy = settings.resumeFolder + "/" + url.lastPathComponent
            try? FileManager.default.removeItem(atPath: copy)
            guard (try? FileManager.default.copyItem(atPath: path, toPath: copy)) != nil else { return }
            path = copy
        }
        resumePDF = path
    }

    /// Fills the empty contact fields from the résumé: the .tex beside the chosen PDF, else the newest variant.
    private func fillFromResume() {
        hunt.rescan()
        let sibling = resumePDF.isEmpty ? nil : (resumePDF as NSString).deletingPathExtension + ".tex"
        let path = sibling.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? hunt.variants.max { $0.modified < $1.modified }?.path
        guard let path, let tex = try? String(contentsOfFile: path, encoding: .utf8) else {
            fillOutcome = "No .tex résumé found in the résumé folder."; return
        }
        let (bank, contact) = ResumeLibrary.filling(settings.answerBank, from: ResumeLibrary.contact(fromTex: tex))
        settings.answerBank = bank
        let file = (path as NSString).lastPathComponent
        func outcome(_ filled: [String]) -> String {
            filled.isEmpty ? "Nothing new in \(file); your answers already cover it." : "Filled \(ListFormatter.localizedString(byJoining: filled)) from \(file)."
        }
        fillOutcome = outcome(contact)
        guard claude.isReady else {
            fillOutcome += " Connect Claude Code to read education and work history too."; return
        }
        fillingHistory = true
        fillOutcome = "Reading education and work history from \(file)" + (bank.linkedin.isEmpty ? "…" : " and LinkedIn…")
        Task {
            defer { fillingHistory = false }
            do { fillOutcome = outcome(contact + (try await hunt.fillHistory(tex: tex, settings: settings))) }
            catch { fillOutcome = outcome(contact) + " Couldn't read history: \(error.localizedDescription)" }
        }
    }

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
            FlowLayout(spacing: PB.s2) {
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
            }
            Label(linkedInSaved ? "Saved in this Mac’s Keychain" : "No sign-in saved", systemImage: linkedInSaved ? "lock.shield" : "lock")
                .font(.system(size: 12)).foregroundStyle(PB.muted)
                .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: PB.s3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PB.s3) { browserHeading; Spacer(minLength: 0); browserPicker }
                VStack(alignment: .leading, spacing: PB.s2) { browserHeading; browserPicker }
            }
            if browserChoice == .chrome {
                Text(hunt.chromeStatus ?? "Open Chrome, then connect the Claude extension for discovery and applications.")
                    .font(.system(size: 13)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: PB.s2) {
                    Button { Task { await hunt.openChrome() } } label: {
                        Label(hunt.isOpeningChrome ? "Opening Chrome…" : "Open Chrome", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(hunt.isOpeningChrome)
                    Button("Connect Claude extension") { hunt.openChromeSetup() }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                        .disabled(claude.busy)
                }
                Divider().overlay(PB.line)
            }
            HStack(spacing: PB.s2) {
                Text(browserChoice == .chrome ? "LinkedIn sync browser" : "Built-in browser")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button(expanded ? "Hide browser" : "Show browser") { chosen = true; expanded.toggle() }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            Text(subtitle).font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if expanded {
                HStack(spacing: PB.s2) {
                    TextField("Website address", text: $address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, PB.s3).frame(height: PB.controlHeight(compact: true))
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                        .onSubmit(go)
                        .disabled(claude.busy)
                    Button("Go", action: go).buttonStyle(PillButtonStyle(compact: true)).disabled(claude.busy)
                }
                FlowLayout(spacing: PB.s2) {
                    Button { Task { try? await browser.back() } } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true)).disabled(claude.busy)
                    Button("Sign in to LinkedIn", action: signIn).buttonStyle(PillButtonStyle(filled: false, compact: true))
                        .disabled(claude.busy)
                }
                if claude.busy {
                    Text("Claude is using the browser. Navigation controls will return when it finishes.")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                }
                HuntWebViewHost(webView: browser.webView)
                    .frame(maxWidth: .infinity).frame(height: 440)
                    .clipShape(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line))
            }
        }
        .pbCard(padding: PB.s4)
        .onAppear { if !chosen { expanded = hunt.isRunning && !hunt.usingChrome }; address = browser.url?.absoluteString ?? "" }
        // Leave a stopped application visible so the user can resolve a question or sign-in.
        .onChange(of: hunt.isRunning) { if hunt.isRunning, !hunt.usingChrome { expanded = true } }
        .onChange(of: browser.url) { address = browser.url?.absoluteString ?? "" }
    }

    private var browserHeading: some View {
        Label("Application browser", systemImage: "globe")
            .font(.system(size: 14, weight: .semibold))
    }

    private var browserPicker: some View {
        Picker("Application browser", selection: $browserChoice) {
            Text("Built-in").tag(HuntBrowserChoice.builtin)
            Text("Chrome + Claude").tag(HuntBrowserChoice.chrome)
        }
        .labelsHidden().pickerStyle(.menu).tint(PB.cobalt)
        .disabled(hunt.isRunning || claude.busy)
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
    @AppStorage(HuntPrefs.keepApplyingKey) private var keepApplying = false

    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s4) {
            HStack(alignment: .top, spacing: PB.s3) {
                VStack(alignment: .leading, spacing: PB.s1) {
                    Text(keepApplying ? "Applying for you" : "Daily hunt")
                        .font(.system(size: 16, weight: .semibold))
                    Text(status).font(.system(size: 13)).foregroundStyle(hunt.error == nil || hunt.isRunning ? PB.ink2 : PB.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if hunt.isRunning { ProgressView().controlSize(.small) }
            }
            FlowLayout(spacing: PB.s2) {
                if !claude.isReady {
                    Button("Connect Claude") { app.showProfile = true }.buttonStyle(PillButtonStyle(compact: true))
                } else {
                    Button { Task { await hunt.run() } } label: {
                        Label(hunt.isRunning ? "Hunt running…" : "Find roles", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(hunt.isRunning || claude.busy || hunt.isOpeningChrome)
                }
                Button("Rescan résumés") { hunt.rescan() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    .disabled(hunt.isRunning)
            }
            FlowLayout(spacing: PB.s3) {
                HStack(spacing: PB.s2) {
                    Toggle("Daily search", isOn: $settings.auto).toggleStyle(CheckboxToggleStyle(labeled: true))
                    Picker("Daily search time", selection: $settings.runHour) {
                        ForEach(0..<24, id: \.self) { Text(TimeFmt.hour($0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Toggle("Keep applying", isOn: $keepApplying).toggleStyle(CheckboxToggleStyle(labeled: true))
                    .onChange(of: keepApplying) { hunt.keepApplyingChanged() }
                Text("\(hunt.tailoredToday) / \(settings.dailyTailorLimit) prepared today")
                    .font(.system(size: 12)).foregroundStyle(PB.muted)
                Text("\(hunt.submittedToday) / \(settings.dailySubmitLimit) submitted today")
                    .font(.system(size: 12)).foregroundStyle(PB.muted)
            }
        }
        .pbCard(padding: PB.s4)
    }

    private var status: String {
        switch hunt.phase {
        case .discovering: return hunt.usingChrome ? "Looking for jobs in Chrome… this can take a while." : "Looking for roles in the built-in browser…"
        case .tailoring(let done, let total): return "Tailoring résumés… \(done) of \(total) done."
        case .submitting(let name): return "Submitting to \(name)…"
        case .honesty(let name): return "Checking the claims in \(name)…"
        case .editing(let name): return "Rebuilding the résumé for \(name)…"
        case .readingProfile: return "Reading your education and work history…"
        case .drafting(let name): return "Drafting answers for \(name)…"
        case .idle: break
        }
        if let e = hunt.error { return e }
        if !claude.isReady { return "Connect Claude Code to discover roles and prepare applications on this Mac." }
        if claude.busy { return "Claude is working on another task. You can start a search when it finishes." }
        guard let last = hunt.lastRun else { return "Find matching roles and prepare a tailored résumé for each one." }
        return "Last run \(last.formatted(.relative(presentation: .named)))" + (hunt.lastSummary.map { " · \($0)" } ?? "")
    }
}
#endif
