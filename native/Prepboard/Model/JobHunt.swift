import Foundation
import SwiftData

/// What Discover returns (matches `JobHunt.discoverSchema`).
struct DiscoverResult: Codable {
    struct Found: Codable {
        var company, title, location, link, role_number, source, jd: String
        var score: Double
        var score_reason: String
    }
    var leads: [Found]
    var notes: String
}

/// What Tailor returns: the new .tex plus coverage, form answers and the ledger (matches `JobHunt.tailorSchema`).
struct TailorResult: Codable {
    var tex: String
    var coverage: [Coverage]
    var answers: [FormAnswer]
    var ledger: [String]
    var notes: String
}

/// What an "Ask Claude" edit in the résumé editor returns (matches `JobHunt.editSchema`).
struct EditResult: Codable {
    var tex: String
    var notes: String
}

/// What the honesty check returns (matches `JobHunt.honestySchema`).
struct HonestyResult: Codable {
    var ok: Bool
    var untraceable: [String]
}

/// What Submit returns (matches `JobHunt.submitSchema`).
struct SubmitResult: Codable {
    var status: String          // "submitted" | "needs_you" | "failed"
    var reason: String
    var unknown_questions: [String]
    var confirmation: String
    var questions_only: Bool?   // true when unanswered questions were the only thing that stopped it
}

/// Answers Claude drafted for open-ended form questions (matches `JobHunt.draftSchema`).
struct DraftResult: Codable {
    var answers: [FormAnswer]
    var notes: String
}

/// Education and work facts read from the résumé (and LinkedIn) for the Answer Bank (matches `JobHunt.profileSchema`).
struct ProfileFacts: Codable {
    var school, degree, major, graduation, gpa: String
    var current_employer, current_title, years_experience: String
    var education, employment: String
    var notes: String
}

#if os(macOS)
import AppKit
import UserNotifications
import Observation

/// Which browser the heavy runs (Discover, Submit) use. Mac only, not synced; the LinkedIn sync always uses the built-in browser.
enum HuntBrowserChoice: String {
    case builtin, chrome

    /// UserDefaults "hunt.browser"; anything unknown reads as `.builtin`.
    static var current: HuntBrowserChoice {
        get { UserDefaults.standard.string(forKey: "hunt.browser").flatMap(HuntBrowserChoice.init) ?? .builtin }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hunt.browser") }
    }
}

/// How this Mac applies. Not synced: only the Mac submits, and the résumé path is a Mac path.
enum HuntPrefs {
    static let keepApplyingKey = "hunt.keepApplying", resumePDFKey = "hunt.resumePDF"
    /// Every ready lead with complete answers is queued without waiting for Submit, and the search repeats during the day.
    static var keepApplying: Bool { UserDefaults.standard.bool(forKey: keepApplyingKey) }
    /// "" tailors a résumé for each job; otherwise this PDF is sent to every application.
    static var resumePDF: String { UserDefaults.standard.string(forKey: resumePDFKey) ?? "" }
    /// While keep applying is on, the search runs again this long after the last one if the queue has emptied.
    static let rerunGap: TimeInterval = 3 * 3600

    /// True when `path` is a PDF the built-in browser may upload (inside the home folder) and it exists.
    static func usablePDF(_ path: String) -> Bool {
        !path.isEmpty && BrowserServer.uploadAllowed(path) && (path as NSString).pathExtension.lowercased() == "pdf"
            && FileManager.default.fileExists(atPath: path)
    }
}

/// Finds jobs, tailors a résumé variant for each good match and submits the ones the user queued, all through
/// the user's local Claude Code. Discovery only reads; `submit` is the only step that acts on a site.
@MainActor
@Observable
final class JobHunt {
    enum Phase: Equatable { case idle, discovering, tailoring(done: Int, total: Int), submitting(String), honesty(String), editing(String), readingProfile, drafting(String) }

    static let submitSpacing: TimeInterval = 120
    static let cooldown: TimeInterval = 7 * 86400

    private(set) var phase: Phase = .idle
    private(set) var lastRun: Date? = UserDefaults.standard.object(forKey: "hunt.lastRun") as? Date {
        didSet { UserDefaults.standard.set(lastRun, forKey: "hunt.lastRun") }
    }
    private(set) var lastSummary: String? = UserDefaults.standard.string(forKey: "hunt.summary") {
        didSet { UserDefaults.standard.set(lastSummary, forKey: "hunt.summary") }
    }
    var error: String?
    private(set) var variants: [ResumeVariant] = []
    /// The browser the current (or last) heavy run chose; `HuntRunCard` words its status with it.
    private(set) var usingChrome = false
    private(set) var chromeStatus: String?
    private(set) var isOpeningChrome = false
    var isRunning: Bool { phase != .idle }
    var tailoredToday: Int { Self.dailyCount("tailored") }
    var submittedToday: Int { Self.dailyCount("submitted") }

    private var container: ModelContainer?
    private weak var claude: ClaudeCode?
    private weak var cloud: Cloud?
    private weak var github: GitHub?
    private weak var browser: BrowserServer?
    private weak var huntBrowser: HuntBrowser?
    private var scheduleTimer: Timer?
    private var queueTimer: Timer?
    private var lastSubmit: Date? = UserDefaults.standard.object(forKey: "hunt.lastSubmit") as? Date {
        didSet { UserDefaults.standard.set(lastSubmit, forKey: "hunt.lastSubmit") }
    }

    /// Open the selected desktop browser explicitly: the default browser may be Safari, which cannot host this extension.
    /// Launching Chrome does not prove that its extension is connected; the run checks that separately.
    @discardableResult
    func openChrome(_ link: String? = nil) async -> Bool {
        guard !isOpeningChrome else { return false }
        let page: URL?
        if let link {
            guard let valid = Self.webURL(link) else {
                chromeStatus = "This posting needs a valid http or https link before it can be opened."
                error = chromeStatus
                return false
            }
            page = valid
        } else { page = nil }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            chromeStatus = "Google Chrome is not installed. Install Chrome or choose the built-in browser."
            error = chromeStatus
            return false
        }
        isOpeningChrome = true
        defer { isOpeningChrome = false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if let page {
                _ = try await NSWorkspace.shared.open([page], withApplicationAt: app, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            }
            chromeStatus = "Chrome is open. The Claude extension connection is checked when a run starts."
            return true
        } catch {
            chromeStatus = "Couldn't open Chrome: \(error.localizedDescription)"
            self.error = chromeStatus
            return false
        }
    }

    /// First-time consent, extension reconnection, and browser selection require Claude's interactive setup.
    /// The script opens a session only; it never sends an application prompt.
    func openChromeSetup() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-chrome-setup.command")
        let script = """
        #!/bin/zsh -l
        export PATH='\(LatexBuild.quoted(ClaudeCode.searchPath))':"$PATH"
        cd "$HOME"
        printf '%s\\n' 'In Claude, use /login if needed, then /chrome to connect the extension and choose Google Chrome.'
        exec claude --chrome
        """
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard NSWorkspace.shared.open(file) else { throw BrowserError.message("Terminal could not open the setup session.") }
            chromeStatus = "Finish setup in Terminal: use /chrome to reconnect, choose Chrome, and review site permissions."
        } catch {
            chromeStatus = "Couldn't open Chrome setup: \(error.localizedDescription)"
            self.error = chromeStatus
        }
    }

    nonisolated static func webURL(_ link: String) -> URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Starts the schedule: a daily run checked every 5 minutes, the submit queue every minute. `browser` is the built-in
    /// browser's MCP server; `huntBrowser` the web view itself, which the LinkedIn sign-in check drives directly.
    func attach(container: ModelContainer, claude: ClaudeCode, cloud: Cloud, github: GitHub, browser: BrowserServer, huntBrowser: HuntBrowser) {
        self.container = container; self.claude = claude; self.cloud = cloud; self.github = github; self.browser = browser
        self.huntBrowser = huntBrowser
        scheduleTimer?.invalidate(); queueTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        queueTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processSubmitQueue() }
        }
        recoverInterrupted(container.mainContext)
        rescan()
        runIfDue()
    }

    /// Leads the last launch left mid-run (the app quit while tailoring or submitting) would otherwise sit in that state for ever:
    /// nothing picks a `.submitting` lead up again. They become needs-you with a note, so the user checks the posting before retrying.
    func recoverInterrupted(_ context: ModelContext) {
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        var changed = false
        for lead in leads {
            switch lead.status {
            case .submitting:
                lead.status = .needsYou; lead.submitRequested = false
                lead.flagged = "PrepBoard quit while this was being submitted; check the posting for a sent application before pressing Submit again"
            case .tailoring:
                lead.status = .failed; lead.reason = "PrepBoard quit while the résumé was being written; press Regenerate"
            default:
                continue
            }
            lead.updatedAt = .now; changed = true
        }
        if changed { try? context.save() }
    }

    // MARK: counters and helpers

    /// Today's tailored/submitted count ("hunt.<kind>.<yyyy-MM-dd>" in UserDefaults).
    static func dailyCount(_ kind: String, on day: Date = .now) -> Int {
        UserDefaults.standard.integer(forKey: "hunt.\(kind).\(DateCoding.dayString(day))")
    }
    private static func bump(_ kind: String) {
        UserDefaults.standard.set(dailyCount(kind) + 1, forKey: "hunt.\(kind).\(DateCoding.dayString(.now))")
    }

    /// The settings record if it exists (timers never create one).
    private func settings(in context: ModelContext) -> HuntSettings? { try? context.fetch(FetchDescriptor<HuntSettings>()).first }

    /// True when a Role at the same company was applied to in the last 7 days, unless the lead carries a different posting id.
    static func cooldownBlocks(lead: Lead, roles: [Role], now: Date) -> Bool {
        let company = JobMerge.key(lead.company)
        guard !company.isEmpty else { return false }
        let number = lead.roleNumber.trimmingCharacters(in: .whitespaces)
        return roles.contains { r in
            guard JobMerge.key(r.company) == company, let applied = r.appliedAt,
                  applied <= now, now.timeIntervalSince(applied) < cooldown else { return false }
            return number.isEmpty || number == r.roleNumber.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The Answer Bank value for a form question, if the question is one the bank covers (see `AnswerBank.rule(for:)`).
    static func bankAnswer(for question: String, bank: AnswerBank) -> (answer: String, kind: String, legal: Bool)? {
        bank.answer(for: question)
    }

    /// True when the posting lives on LinkedIn, so Submit needs the LinkedIn session first.
    static func isLinkedIn(_ link: String) -> Bool {
        ATS.kind(link) == .linkedin
    }

    /// Adds a needs_you answer for each question the form asked that is not in the list yet, so `canSubmit` gates on it.
    static func addingUnknown(_ questions: [String], to answers: [FormAnswer]) -> [FormAnswer] {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var result = answers, seen = Set(answers.map { norm($0.question) })
        for q in questions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !q.isEmpty && seen.insert(norm(q)).inserted {
            result.append(FormAnswer(question: q, answer: "", kind: "needs_you", required: true))
        }
        return result
    }

    /// Fills Tailor's answers from the Answer Bank: legal questions always, the rest when the bank has a value.
    static func mergeAnswers(_ answers: [FormAnswer], bank: AnswerBank) -> [FormAnswer] {
        bank.merge(answers)
    }

    // MARK: schedule

    func runIfDue() {
        let keepApplying = HuntPrefs.keepApplying
        guard phase == .idle, !isOpeningChrome, let container, let claude, claude.isReady, !claude.busy,
              let s = settings(in: container.mainContext), s.auto || keepApplying else { return }
        guard Calendar.current.component(.hour, from: .now) >= s.runHour else { return }
        if let lastRun, Calendar.current.isDateInToday(lastRun) {
            // Keep applying searches again every few hours, once the queue is empty and today's submits have room.
            guard keepApplying, Date.now.timeIntervalSince(lastRun) >= HuntPrefs.rerunGap,
                  Self.dailyCount("submitted") < s.dailySubmitLimit, queuedLeads(container.mainContext).isEmpty else { return }
        }
        Task { await run() }
    }

    private func queuedLeads(_ context: ModelContext) -> [Lead] {
        let ready = LeadStatus.ready.rawValue
        return (try? context.fetch(FetchDescriptor<Lead>(predicate: #Predicate { $0.submitRequested && $0.statusRaw == ready }))) ?? []
    }

    /// True when Submit has a PDF to send for `lead`: its tailored one, or the résumé chosen for every job.
    func hasResume(_ lead: Lead) -> Bool {
        if let name = Self.plainName(lead.variantName) { return FileManager.default.fileExists(atPath: resumeFolder + "/" + name + ".pdf") }
        return HuntPrefs.usablePDF(HuntPrefs.resumePDF)
    }

    /// Keep applying queues a ready lead only when nothing is left for the user: answers complete, no flag, a résumé to send.
    func autoQueue(_ leads: [Lead]) -> Int {
        guard HuntPrefs.keepApplying else { return 0 }
        var queued = 0
        for lead in leads where lead.status == .ready && !lead.submitRequested && lead.canSubmit && lead.flagged.isEmpty && hasResume(lead) {
            lead.submitRequested = true; lead.updatedAt = .now; queued += 1
        }
        return queued
    }

    /// Turning keep applying on queues what is already ready; turning it off empties the queue so nothing more goes out.
    func keepApplyingChanged() {
        guard let container else { return }
        let context = container.mainContext
        let ready = LeadStatus.ready.rawValue
        let leads = (try? context.fetch(FetchDescriptor<Lead>(predicate: #Predicate { $0.statusRaw == ready }))) ?? []
        if HuntPrefs.keepApplying { _ = autoQueue(leads) }
        else { for lead in leads where lead.submitRequested { lead.submitRequested = false; lead.updatedAt = .now } }
        try? context.save()
        processSubmitQueue()
        runIfDue()
    }

    /// Submits the oldest queued lead, one at a time, at least 2 minutes apart and within the daily limit.
    func processSubmitQueue() {
        guard phase == .idle, !isOpeningChrome, let container, let claude, claude.isReady, !claude.busy else { return }
        if let lastSubmit, Date.now.timeIntervalSince(lastSubmit) < Self.submitSpacing { return }
        let context = container.mainContext
        guard let s = settings(in: context), Self.dailyCount("submitted") < s.dailySubmitLimit else { return }
        guard let lead = queuedLeads(context).min(by: { $0.updatedAt < $1.updatedAt }) else { return }
        Task { await submit(lead) }
    }

    /// The résumé folder from settings, or the default before a settings record exists.
    private var resumeFolder: String {
        container.flatMap { settings(in: $0.mainContext)?.resumeFolder } ?? HuntSettings.defaultResumeFolder
    }

    /// The lead's tailored .tex in the résumé folder; nil until a variant has been generated (or when the synced name is not a plain file name).
    func texPath(for lead: Lead) -> String? {
        Self.plainName(lead.variantName).map { resumeFolder + "/" + $0 + ".tex" }
    }

    /// `name` when it is one plain, visible path component; nil otherwise. `variantName` syncs from Supabase, so a tampered or
    /// buggy row must never turn into a path outside the résumé folder.
    static func plainName(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("."), name != "..", (name as NSString).lastPathComponent == name, !name.contains("\0") else { return nil }
        return name
    }

    /// One "Ask Claude" edit of the editor's text: Claude reads the other variants as evidence and returns the whole file.
    /// Throws when Claude Code is away or another run has it; nothing is written.
    func edit(_ lead: Lead, tex: String, instruction: String) async throws -> EditResult {
        guard let claude, claude.isReady else { throw BrowserError.message("Connect Claude Code in Profile to edit with Claude.") }
        guard !claude.busy else { throw BrowserError.message("Another Claude run is going; wait for it to finish.") }
        let folder = resumeFolder
        let sources = variants.map(\.name).filter { $0 != lead.variantName }
        let prompt = Self.editPrompt(instruction: instruction, tex: tex, lead: lead, sources: sources, github: github?.context ?? "", folder: folder)
        claude.busy = true
        defer { claude.busy = false }
        let result = try await whileEditing(lead) {
            try await Self.check(EditResult.self, prompt: prompt, schema: Self.editSchema, browserFlags: nil, tools: Self.fileTools, cwd: folder)
        }
        guard let result, !result.tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserError.message(error ?? "Claude returned an empty file")
        }
        return result
    }

    /// Reads education and work history from `tex` (and the LinkedIn profile, when the bank has its link and the built-in browser is
    /// signed in) and fills the Answer Bank fields that are still empty. Never overwrites what the user typed. Returns the labels filled.
    func fillHistory(tex: String, settings: HuntSettings) async throws -> [String] {
        guard let claude, claude.isReady else { throw BrowserError.message("Connect Claude Code in Profile to read your résumé.") }
        guard !claude.busy, phase == .idle else { throw BrowserError.message("Another Claude run is going; wait for it to finish.") }
        phase = .readingProfile
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        var bank = settings.answerBank
        var flags: String?
        if let huntBrowser, browser?.isRunning == true, Self.webURL(bank.linkedin) != nil,
           LinkedInSignIn.stopMessage(await LinkedInSignIn.ensure(huntBrowser)) == nil {
            browser?.reset()
            flags = browser?.claudeFlags(extraTools: "", readOnly: true)
        }
        let facts = try await Self.check(ProfileFacts.self, prompt: Self.profilePrompt(tex: tex, linkedin: flags == nil ? "" : bank.linkedin),
                                         schema: Self.profileSchema, browserFlags: flags, tools: "", cwd: nil)
        let pairs: [(String, WritableKeyPath<AnswerBank, String>, String)] = [
            ("school", \.school, facts.school), ("degree", \.degree, facts.degree), ("major", \.major, facts.major),
            ("graduation", \.graduation, facts.graduation), ("GPA", \.gpa, facts.gpa), ("current employer", \.currentEmployer, facts.current_employer),
            ("current title", \.currentTitle, facts.current_title), ("years of experience", \.yearsExperience, facts.years_experience),
            ("education history", \.education, facts.education), ("employment history", \.employment, facts.employment)]
        var filled: [String] = []
        for (label, field, value) in pairs {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty, bank[keyPath: field].trimmingCharacters(in: .whitespaces).isEmpty { bank[keyPath: field] = v; filled.append(label) }
        }
        settings.answerBank = bank
        settings.updatedAt = .now
        if let container {
            Lead.applyBank(bank, to: (try? container.mainContext.fetch(FetchDescriptor<Lead>())) ?? [])
            try? container.mainContext.save()
        }
        return filled
    }

    /// The Draft button on a lead: drafts every open-ended question still waiting on the user. Returns how many it answered.
    func draftAnswers(_ lead: Lead) async -> Int {
        guard phase == .idle, let container, let claude, claude.isReady, !claude.busy else {
            error = "Claude is busy or not connected; try again in a moment."; return 0
        }
        phase = .drafting(lead.company)
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        let context = container.mainContext
        let n = await draftOpenQuestions(lead, settings: HuntSettings.current(context))
        if n > 0, lead.status == .needsYou, lead.canSubmit, lead.onlyQuestionsFlagged {
            lead.status = .ready; lead.flagged = ""; lead.reason = "Claude drafted \(n) answer\(n == 1 ? "" : "s"); review them, then submit."
        }
        try? context.save()
        return n
    }

    /// Drafts the lead's needs_you questions that the Answer Bank does not cover (never legal ones), from my résumés, GitHub,
    /// education and work history, and what Claude can read about the company on the web. Call with `claude.busy` already held.
    private func draftOpenQuestions(_ lead: Lead, settings: HuntSettings) async -> Int {
        let bank = lead.bank(settings.answerBank)
        let open = lead.answers.filter { $0.kind == "needs_you" && AnswerBank.rule(for: $0.question) == nil }.map(\.question)
        guard !open.isEmpty else { return 0 }
        let folder = settings.resumeFolder
        let tex = texPath(for: lead).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        do {
            let result = try await Self.check(DraftResult.self, prompt: Self.draftPrompt(lead: lead, questions: open, tex: tex, github: github?.context ?? "",
                                                                                        bank: bank, folder: folder),
                                              schema: Self.draftSchema, browserFlags: nil, tools: Self.draftTools, cwd: folder)
            var all = lead.answers, n = 0
            for d in result.answers where d.kind == "drafted" {
                let text = d.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let i = all.firstIndex(where: { $0.kind == "needs_you" && AnswerBank.normalized($0.question) == AnswerBank.normalized(d.question) })
                else { continue }
                all[i].answer = text; all[i].kind = "drafted"; n += 1
            }
            lead.answers = all; lead.updatedAt = .now
            return n
        } catch {
            lead.reason = [lead.reason, "Couldn't draft answers: \(error.localizedDescription)"].filter { !$0.isEmpty }.joined(separator: " ")
            return 0
        }
    }

    /// Runs `work` with the hunt held in `.editing`, so the timers start no run or submit while a hand-edited PDF is rebuilt.
    /// Nil, with `error` set, when a run is already going.
    func whileEditing<T>(_ lead: Lead, _ work: () async throws -> T) async rethrows -> T? {
        guard phase == .idle else { error = "The hunt is busy; try again when it finishes"; return nil }
        phase = .editing(lead.company)
        defer { phase = .idle }
        return try await work()
    }

    /// Refreshes `variants` from the résumé folder.
    func rescan() {
        guard container != nil else { return }
        let folder = resumeFolder
        do { variants = try ResumeLibrary.scan(folder: folder) } catch { variants = []; self.error = "Couldn't read \(folder): \(error.localizedDescription)" }
    }

    func skip(_ lead: Lead) {
        lead.status = .skipped; lead.submitRequested = false; lead.reason = "Skipped by you"; lead.updatedAt = .now
        try? container?.mainContext.save()
    }

    // MARK: run

    /// Discover → tailor each new lead at or above the minimum score (within the daily limit) → ready / needs you / failed.
    func run() async {
        guard phase == .idle, let container, let claude else { return }
        guard claude.isReady else { error = "Connect Claude Code in Profile to run the hunt."; return }
        guard !claude.busy else { error = "Another Claude run is using the browser; wait for it to finish."; return }
        let chrome = HuntBrowserChoice.current == .chrome   // read once; the built-in server guards apply only to that path
        guard !chrome || !isOpeningChrome else { error = "Chrome is opening. Start the hunt once its window is ready."; return }
        guard chrome || browser?.isRunning == true else { error = "The built-in browser couldn't start"; return }
        let context = container.mainContext
        let settings = HuntSettings.current(context)
        phase = .discovering
        usingChrome = chrome
        error = nil
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        if chrome, !(await openChrome()) { return }
        if !chrome { browser?.reset() }
        // The built-in browser signs itself in from the Keychain when LinkedIn's session is gone; Chrome has its own.
        if !chrome, let huntBrowser, let stop = LinkedInSignIn.stopMessage(await LinkedInSignIn.ensure(huntBrowser)) {
            error = stop
            lastRun = .now; lastSummary = LinkedInSignIn.stoppedSummary
            return
        }
        rescan()
        let all = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        Lead.applyBank(settings.answerBank, to: all)   // answers saved since the last run
        if settings.answerBank.needsSponsorship == "Yes" { Lead.applySponsorship(true, to: all) }
        if let github, github.repos.isEmpty, !github.username.isEmpty { await github.load() }
        let roles = (try? context.fetch(FetchDescriptor<Role>())) ?? []
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        var known = Set(leads.map { ResumeLibrary.dedupeKey(company: $0.company, title: $0.title, roleNumber: $0.roleNumber) }
                        + roles.map { ResumeLibrary.dedupeKey(company: $0.company, title: $0.title, roleNumber: $0.roleNumber) })
        let knownLines = leads.map { "\($0.company) | \($0.roleNumber.isEmpty ? "-" : $0.roleNumber) | \($0.title)" }
            + roles.map { "\($0.company) | \($0.roleNumber.isEmpty ? "-" : $0.roleNumber) | \($0.title)" }
        var fresh: [Lead] = []
        var found = 0, skipped = 0
        do {
            let prompt = Self.discoverPrompt(settings: settings, variants: variants, known: knownLines, chrome: chrome)
            // Discover never fills a form: read-only tools on both paths.
            let flags = chrome ? Self.chromeFlags(tools: Self.chromeDiscoverTools) : browser?.claudeFlags(extraTools: "", readOnly: true)
            let result = try await Self.check(DiscoverResult.self, prompt: prompt, schema: Self.discoverSchema, browserFlags: flags, tools: "", cwd: nil)
            for f in result.leads where !f.company.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = ResumeLibrary.dedupeKey(company: f.company, title: f.title, roleNumber: f.role_number)
                guard !known.contains(key) else { continue }
                known.insert(key)
                func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
                let lead = Lead(company: clean(f.company), title: clean(f.title), location: clean(f.location), link: clean(f.link),
                                roleNumber: clean(f.role_number), source: f.source, jd: clean(f.jd),
                                score: Int(max(0, min(100, f.score.rounded()))), scoreReason: clean(f.score_reason))
                if lead.score < settings.minScore { lead.status = .skipped; lead.reason = "Below match threshold"; skipped += 1 }
                else if Self.cooldownBlocks(lead: lead, roles: roles, now: .now) { lead.status = .skipped; lead.reason = "Applied to \(lead.company) in the last 7 days"; skipped += 1 }
                else if settings.answerBank.needsSponsorship == "Yes", let phrase = Lead.sponsorshipBlock(jd: lead.jd) {
                    lead.status = .skipped; lead.reason = "\(Lead.sponsorshipSkipPrefix): \u{201C}\(phrase)\u{201D}"; skipped += 1
                }
                else { fresh.append(lead) }
                context.insert(lead)
                found += 1
            }
            try context.save()
            if result.notes.uppercased().hasPrefix("NO_CHROME") {
                error = Self.noChromeMessage
                chromeStatus = Self.noChromeMessage
                lastRun = .now; lastSummary = "Stopped: Chrome isn't connected"
                return
            }
            if result.notes.uppercased().hasPrefix("SIGNED_OUT") {
                error = (chrome ? "Sign in to LinkedIn in Chrome, then run the hunt again. " : "Sign in to LinkedIn in the Browser card above, then run the hunt again. ")
                    + result.notes.dropFirst("SIGNED_OUT".count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                lastRun = .now; lastSummary = "Stopped: LinkedIn needs you to sign in"
                return
            }
        } catch {
            self.error = error.localizedDescription
            lastRun = .now; lastSummary = "Failed: " + error.localizedDescription
            return
        }
        var pending = fresh
        for lead in leads where lead.status == .new && lead.score >= settings.minScore {
            if Self.cooldownBlocks(lead: lead, roles: roles, now: .now) {
                lead.status = .skipped; lead.reason = "Applied to \(lead.company) in the last 7 days"; lead.updatedAt = .now; skipped += 1
            } else { pending.append(lead) }
        }
        try? context.save()
        let oneResume = HuntPrefs.resumePDF
        let batch: [Lead]
        var ready = 0, needsYou = 0, failed = 0
        if !oneResume.isEmpty {
            // One résumé for every job: nothing to tailor, the lead is ready as soon as it is found.
            batch = pending.sorted { $0.score > $1.score }
            for lead in batch {
                lead.status = .ready; lead.reason = "Sends \((oneResume as NSString).lastPathComponent)"; lead.updatedAt = .now
                ready += 1
            }
        } else {
            let room = max(0, settings.dailyTailorLimit - Self.dailyCount("tailored"))
            batch = Array(pending.sorted { $0.score > $1.score }.prefix(room))
            for (i, lead) in batch.enumerated() {
                phase = .tailoring(done: i, total: batch.count)
                await tailorLead(lead, settings: settings, roles: roles, context: context)
                switch lead.status {
                case .ready: ready += 1
                case .needsYou: needsYou += 1
                case .failed: failed += 1
                default: break
                }
            }
        }
        let queued = autoQueue(batch)
        try? context.save()
        lastRun = .now
        lastSummary = found == 0 && batch.isEmpty ? "Nothing new" : [
            "\(found) found", oneResume.isEmpty ? "\(batch.count) tailored" : nil, queued > 0 ? "\(queued) queued to apply" : nil, ready > 0 ? "\(ready) ready" : nil, needsYou > 0 ? "\(needsYou) need you" : nil,
            failed > 0 ? "\(failed) failed" : nil, skipped > 0 ? "\(skipped) skipped" : nil, pending.count > batch.count ? "\(pending.count - batch.count) waiting for tomorrow" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: tailor

    /// Writes a tailored variant for one lead; also used by Regenerate on a card.
    func tailor(_ lead: Lead) async {
        guard phase == .idle, let container, let claude else { return }
        guard claude.isReady else { error = "Connect Claude Code in Profile to tailor a résumé."; return }
        guard !claude.busy else { error = "Another Claude run is in progress; wait for it to finish."; return }
        let context = container.mainContext
        let settings = HuntSettings.current(context)
        guard Self.dailyCount("tailored") < settings.dailyTailorLimit else { error = "Daily tailoring limit reached (\(settings.dailyTailorLimit)). Try again tomorrow."; return }
        phase = .tailoring(done: 0, total: 1)
        error = nil
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        if variants.isEmpty { rescan() }
        if let github, github.repos.isEmpty, !github.username.isEmpty { await github.load() }
        let roles = (try? context.fetch(FetchDescriptor<Role>())) ?? []
        if Self.cooldownBlocks(lead: lead, roles: roles, now: .now) {
            lead.status = .skipped; lead.reason = "Applied to \(lead.company) in the last 7 days"; lead.submitRequested = false; lead.updatedAt = .now
            try? context.save()
            return
        }
        await tailorLead(lead, settings: settings, roles: roles, context: context)
    }

    private func tailorLead(_ lead: Lead, settings: HuntSettings, roles: [Role], context: ModelContext) async {
        let folder = settings.resumeFolder
        lead.status = .tailoring; lead.submitRequested = false; lead.reason = ""; lead.flagged = ""; lead.updatedAt = .now
        try? context.save()
        func fail(_ reason: String) { lead.status = .failed; lead.reason = reason; lead.updatedAt = .now; try? context.save() }
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        let evidence = evidenceVariants(for: lead, leads: leads)
        guard let (base, why) = ResumeLibrary.pickBase(for: lead, variants: evidence, winners: ResumeLibrary.winners(roles: roles)) else {
            return fail("No résumé variants found in \(folder)")
        }
        guard let baseTex = try? String(contentsOfFile: base.path, encoding: .utf8) else { return fail("Couldn't read \(base.name).tex") }
        lead.baseVariant = base.name; lead.baseReason = why
        let bank = settings.answerBank
        let userName = bank.fullName.isEmpty ? "Shiv Vyas" : bank.fullName
        if Self.plainName(lead.variantName) == nil {
            let existing = Set(variants.map(\.name) + leads.filter { $0.id != lead.id && !$0.variantName.isEmpty }.map(\.variantName))
            lead.variantName = ResumeLibrary.variantName(userName: userName, company: lead.company, title: lead.title, existing: existing)
        }
        let name = lead.variantName
        let texPath = folder + "/" + name + ".tex"
        let githubContext = github?.context ?? ""
        do {
            let prompt = Self.tailorPrompt(lead: lead, base: base, baseTex: baseTex, variants: evidence, github: githubContext, bank: bank, name: name, folder: folder)
            var result = try await Self.check(TailorResult.self, prompt: prompt, schema: Self.tailorSchema, browserFlags: nil, tools: Self.fileTools, cwd: folder)
            try result.tex.write(toFile: texPath, atomically: true, encoding: .utf8)
            var pdfPath: String
            do {
                pdfPath = try await LatexBuild.build(texPath: texPath)
            } catch let first as LatexBuild.Failure {
                let retry = prompt + "\n\nYOUR PREVIOUS ATTEMPT DID NOT COMPILE. Fix the LaTeX (keep the same content rules) and return the whole file again.\n<compile_log>\n\(first.log)\n</compile_log>\n<previous_tex>\n\(result.tex)\n</previous_tex>"
                result = try await Self.check(TailorResult.self, prompt: retry, schema: Self.tailorSchema, browserFlags: nil, tools: Self.fileTools, cwd: folder)
                try result.tex.write(toFile: texPath, atomically: true, encoding: .utf8)
                pdfPath = try await LatexBuild.build(texPath: texPath)
            }
            lead.coverage = result.coverage
            let uploadNote = await attachPDF(lead, pdfPath: pdfPath, context: context)   // a failed upload never fails a built variant
            Self.bump("tailored")
            rescan()
            phase = .honesty(lead.company)
            let choices = lead.answers.filter { $0.kind == "choice" }
            lead.answers = lead.bank(bank).merge(result.answers) + choices
            await checkHonesty(lead, tex: result.tex, sources: evidence.map(\.name).filter { $0 != name }, github: githubContext, folder: folder,
                               okReason: result.notes, note: uploadNote)
            lead.updatedAt = .now
            try context.save()
        } catch let build as LatexBuild.Failure {
            try? FileManager.default.removeItem(atPath: texPath)
            try? FileManager.default.removeItem(atPath: (texPath as NSString).deletingPathExtension + ".pdf")
            fail("PDF build failed twice. " + build.log)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Variants that may serve as evidence or a base for a lead. Variants other leads generated but nobody has reviewed
    /// are neither; only submitted ones count. The lead's own variant is never its own evidence.
    private func evidenceVariants(for lead: Lead, leads: [Lead]) -> [ResumeVariant] {
        let generated = Set(leads.filter { $0.id != lead.id && $0.status != .submitted && !$0.variantName.isEmpty }.map(\.variantName))
        return variants.filter { !generated.contains($0.name) && $0.name != lead.variantName }
    }

    /// Replaces the lead's PDF Doc with the file at `pdfPath` (the old Doc and its file are deleted). Returns a note when the
    /// upload failed, "" on success or when no account is attached; the PDF stays on disk either way.
    func attachPDF(_ lead: Lead, pdfPath: String, context: ModelContext) async -> String {
        guard let cloud else { return "" }
        if !lead.pdfDocId.isEmpty, let old = try? context.fetch(FetchDescriptor<Doc>()).first(where: { $0.id == lead.pdfDocId }) {
            await cloud.deleteFile(for: old); context.delete(old)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: pdfPath))
            let doc = try await cloud.importPDF(data, fileName: (pdfPath as NSString).lastPathComponent, roleId: "", context: context)
            doc.tags = ["pdf", "resume", "hunt"]
            lead.pdfDocId = doc.id
            return ""
        } catch {
            lead.pdfDocId = ""
            return "PDF not uploaded (\(error.localizedDescription)); it is at \(pdfPath)"
        }
    }

    /// The honesty pass over `tex`: `.ready` with `okReason` when every claim traces, else `.needsYou` with the untraceable
    /// claims in `flagged`. `note` (an upload warning) is appended to the reason either way. Does not save.
    private func checkHonesty(_ lead: Lead, tex: String, sources: [String], github: String, folder: String, okReason: String, note: String) async {
        func reason(_ text: String) -> String { [text, note].filter { !$0.isEmpty }.joined(separator: " ") }
        do {
            let honesty = try await Self.check(HonestyResult.self, prompt: Self.honestyPrompt(tex: tex, sources: sources, github: github, folder: folder),
                                               schema: Self.honestySchema, browserFlags: nil, tools: Self.fileTools, cwd: folder)
            if honesty.ok && honesty.untraceable.isEmpty {
                lead.status = .ready; lead.flagged = ""; lead.reason = reason(okReason)
            } else {
                lead.status = .needsYou
                lead.flagged = honesty.untraceable.isEmpty ? "Honesty check reported a problem without details; review the résumé" : honesty.untraceable.joined(separator: "\n")
                lead.reason = reason("Check these claims")
            }
        } catch {
            lead.status = .needsYou; lead.flagged = "Honesty check could not run: \(error.localizedDescription)"; lead.reason = reason("Check the résumé yourself")
        }
    }

    /// Re-runs the honesty pass on the lead's current .tex after a hand edit and sets `.ready` / `.needsYou` like `tailorLead`.
    /// False, with `error` set, when the pass could not run at all (the lead is then untouched).
    @discardableResult
    func recheck(_ lead: Lead) async -> Bool {
        guard let container, let claude else { error = "The hunt is not attached yet."; return false }
        guard phase == .idle else { error = "The hunt is busy; try again when it finishes."; return false }
        guard claude.isReady else { error = "Connect Claude Code in Profile to check the résumé."; return false }
        guard !claude.busy else { error = "Another Claude run is in progress; wait for it to finish."; return false }
        guard let texPath = texPath(for: lead), let tex = try? String(contentsOfFile: texPath, encoding: .utf8) else {
            error = "Couldn't read \(lead.variantName).tex"; return false
        }
        let context = container.mainContext
        phase = .honesty(lead.company)
        error = nil
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        rescan()
        if let github, github.repos.isEmpty, !github.username.isEmpty { await github.load() }
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        await checkHonesty(lead, tex: tex, sources: evidenceVariants(for: lead, leads: leads).map(\.name), github: github?.context ?? "",
                           folder: (texPath as NSString).deletingLastPathComponent, okReason: "Edited by you; claims re-checked", note: "")
        lead.updatedAt = .now
        try? context.save()
        return true
    }

    // MARK: submit

    /// The only place that presses Submit. Creates the Role on success; clears `submitRequested` either way.
    func submit(_ lead: Lead) async {
        guard phase == .idle, let container, let claude else { return }
        guard claude.isReady else { error = "Connect Claude Code in Profile to submit applications."; return }
        guard !claude.busy else { error = "Another Claude run is using the browser; wait for it to finish."; return }
        let chrome = HuntBrowserChoice.current == .chrome
        // Keep an approved lead queued if a manual Open Chrome action is still completing.
        guard !chrome || !isOpeningChrome else { return }
        guard chrome || browser?.isRunning == true else { error = "The built-in browser couldn't start"; return }
        let context = container.mainContext
        let settings = HuntSettings.current(context)
        guard Self.dailyCount("submitted") < settings.dailySubmitLimit else { error = "Daily submit limit reached (\(settings.dailySubmitLimit)). The queue continues tomorrow."; return }
        guard lead.canSubmit else {
            lead.submitRequested = false; lead.status = .needsYou; lead.reason = Lead.fillAnswersReason; lead.updatedAt = .now
            try? context.save()
            return
        }
        guard lead.submitRequested else { return }
        guard Self.webURL(lead.link) != nil else {
            lead.submitRequested = false; lead.status = .needsYou; lead.reason = "Add a valid http or https posting link before submitting."
            lead.updatedAt = .now
            try? context.save()
            return
        }
        // Already applied through the hunt (same link or same company + posting id / title): record it, never submit twice.
        let hunt = "hunt"
        let applied = (try? context.fetch(FetchDescriptor<Role>(predicate: #Predicate { $0.source == hunt }))) ?? []
        let key = ResumeLibrary.dedupeKey(company: lead.company, title: lead.title, roleNumber: lead.roleNumber)
        if let dup = applied.first(where: { (!lead.link.isEmpty && $0.link == lead.link)
                                            || ResumeLibrary.dedupeKey(company: $0.company, title: $0.title, roleNumber: $0.roleNumber) == key }) {
            lead.status = .submitted; lead.roleId = dup.id; lead.reason = "Already applied"; lead.submitRequested = false; lead.updatedAt = .now
            try? context.save()
            return
        }
        // Keep the 2-minute spacing even when called directly; the lead stays queued and the timer picks it up.
        if let lastSubmit, Date.now.timeIntervalSince(lastSubmit) < Self.submitSpacing { return }
        phase = .submitting(lead.company)
        usingChrome = chrome
        error = nil
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        // A stop text left in `flagged` by an earlier attempt (Chrome or LinkedIn not ready) must not outlive this one.
        lead.status = .submitting; lead.flagged = ""; lead.updatedAt = .now
        try? context.save()
        let pdfPath = Self.plainName(lead.variantName).map { settings.resumeFolder + "/" + $0 + ".pdf" } ?? HuntPrefs.resumePDF
        if !chrome { browser?.reset() }
        if pdfPath.isEmpty || !FileManager.default.fileExists(atPath: pdfPath) {
            lead.status = .failed
            lead.reason = lead.variantName.isEmpty ? "No résumé to send: choose one in Hunt settings or prepare this application"
                : "The PDF is missing; regenerate the résumé first"
        } else if chrome, !(await openChrome()) {
            lead.status = .ready; lead.flagged = chromeStatus ?? Self.noChromeMessage
        } else if !chrome, let huntBrowser, Self.isLinkedIn(lead.link),
                  let stop = LinkedInSignIn.stopMessage(await LinkedInSignIn.ensure(huntBrowser)) {
            // A LinkedIn posting needs the session first (careers sites do not). Nothing was touched: the lead stays ready, and it
            // leaves the queue, or the minute timer would keep sending the browser back to LinkedIn while the user signs in.
            lead.status = .ready; lead.flagged = stop + " Then press Submit again."; lead.submitRequested = false; error = stop
        } else {
            lastSubmit = .now   // every real attempt counts toward the spacing, even one that throws
            do {
                let flags = chrome ? Self.chromeFlags(tools: Self.chromeSubmitTools) : browser?.claudeFlags(extraTools: "")
                let result = try await Self.check(SubmitResult.self, prompt: Self.submitPrompt(lead: lead, pdfPath: pdfPath, bank: settings.answerBank, chrome: chrome),
                                                  schema: Self.submitSchema, browserFlags: flags, tools: "", cwd: settings.resumeFolder)
                switch result.status {
                case "submitted" where !result.confirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    let role = Role(company: lead.company, title: lead.title.isEmpty ? "Role" : lead.title, location: lead.location,
                                    roleNumber: lead.roleNumber, link: lead.link, stage: .applied)
                    let sent = lead.variantName.isEmpty ? ((pdfPath as NSString).lastPathComponent as NSString).deletingPathExtension : lead.variantName
                    role.source = "hunt"; role.appliedAt = .now; role.resumeVariant = sent
                    role.activity = "- \(DateCoding.dayString(.now)) · Hunt · Applied with \(sent)"
                    context.insert(role)
                    lead.roleId = role.id; lead.status = .submitted; lead.reason = result.confirmation
                    Self.bump("submitted")
                    Self.notifySubmitted(lead)
                case "submitted":
                    lead.status = .needsYou; lead.reason = "No submission confirmation was returned. Check the open application before trying again."
                case "needs_you" where result.reason.uppercased().hasPrefix("NO_CHROME"):
                    // Nothing was touched: the lead stays ready to queue again once Chrome is connected.
                    lead.status = .ready; lead.flagged = Self.noChromeMessage; error = Self.noChromeMessage
                    chromeStatus = Self.noChromeMessage
                case "needs_you":
                    lead.status = .needsYou; lead.flagged = result.unknown_questions.joined(separator: "\n")
                    lead.reason = result.reason.isEmpty ? "The form needs you" : result.reason
                    // Questions the lead already had an answer for stopped the form anyway: never loop on those.
                    let known = Set(lead.answers.filter { $0.kind != "needs_you" }.map { AnswerBank.normalized($0.question) })
                    let repeated = result.unknown_questions.contains { known.contains(AnswerBank.normalized($0)) }
                    lead.answers = lead.bank(settings.answerBank).merge(Self.addingUnknown(result.unknown_questions, to: lead.answers))
                    // Open-ended questions ("What are you proud of?") get drafted for this role; legal ones stay with the user.
                    let drafted = await draftOpenQuestions(lead, settings: settings)
                    if result.questions_only == true, !repeated, drafted > 0, lead.canSubmit {
                        lead.status = .ready; lead.flagged = ""
                        lead.reason = "Claude drafted \(drafted) answer\(drafted == 1 ? "" : "s") for this role; review them before it goes out."
                        if HuntPrefs.keepApplying { lead.submitRequested = true; lead.reason = "Claude drafted \(drafted) answer\(drafted == 1 ? "" : "s") for this role and queued it again." }
                        lead.updatedAt = .now; try? context.save()
                        return
                    }
                    Self.notifyNeedsYou(lead)
                default:
                    lead.status = .failed; lead.reason = result.reason.isEmpty ? "Submit failed" : result.reason
                }
            } catch {
                lead.status = .needsYou
                lead.flagged = "Submit ended without a result; check \(chrome ? "the open Chrome tab" : "the Browser card") before trying again"
                lead.reason = error.localizedDescription
            }
        }
        lead.submitRequested = false; lead.updatedAt = .now
        try? context.save()
    }

    /// A stopped application also shows on Home under "Needs you"; the notification gets the user there when PrepBoard is in the background.
    private static func notifyNeedsYou(_ lead: Lead) {
        let content = UNMutableNotificationContent()
        content.title = "\(lead.company) needs you"
        content.body = lead.reason.isEmpty ? "An application stopped for your input." : lead.reason
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "needs-you-\(lead.id)", content: content, trigger: nil))
    }

    private static func notifySubmitted(_ lead: Lead) {
        let content = UNMutableNotificationContent()
        content.title = "Applied: \(lead.company)"
        content.body = lead.title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "applied-\(lead.id)", content: content, trigger: nil))
    }

    // MARK: Claude

    static let fileTools = "Read Grep Glob"

    /// The Claude in Chrome tools a read-only run (Discover) may use, full names, space-separated for --allowedTools. No `computer`:
    /// it clicks and types in the user's signed-in Chrome, so Discover reads pages and pages through lists by URL instead.
    static let chromeDiscoverTools = ["tabs_context_mcp", "tabs_create_mcp", "tabs_close_mcp", "navigate", "get_page_text", "read_page", "find"]
        .map { "mcp__claude-in-chrome__" + $0 }.joined(separator: " ")
    /// Submit adds clicking, the form and upload tools.
    static let chromeSubmitTools = chromeDiscoverTools + " mcp__claude-in-chrome__computer mcp__claude-in-chrome__form_input mcp__claude-in-chrome__file_upload"
    static let noChromeMessage = "Chrome's Claude extension isn't connected. Use Connect extension, then /chrome in Terminal to reconnect or select Chrome. Sign in to the same Claude account and allow access to the application site. You can also choose the built-in browser."

    /// The `claude -p` flags for a Chrome run: strict, so the Chrome tools are the only MCP tools loaded (the built-in tools go with `--tools ""`).
    static func chromeFlags(tools: String) -> String { "--chrome --strict-mcp-config --allowedTools \(tools)" }

    /// How to drive the browser: PrepBoard's built-in one, or the user's Chrome through the Claude in Chrome extension.
    /// `upload` adds the résumé tool and the Submit-style NO_CHROME report (Submit only).
    static func browserGuide(upload: Bool, chrome: Bool) -> String {
        if chrome {
            return "Use my signed-in Chrome through the Claude in Chrome tools (mcp__claude-in-chrome__…): call tabs_context_mcp first, open "
            + "your own tab with tabs_create_mcp; "
            + (upload ? "leave the application tab open for me, including on success, needs_you, or any error; " : "close only tabs you created with tabs_close_mcp when done; ")
            + "navigate; get_page_text for the full text; "
            + "read_page / find for elements"
            + (upload ? "; computer for clicks and scrolling; form_input for fields and file_upload for the résumé"
                      : "; there is no clicking or scrolling: open each posting by its URL and page through result lists by URL "
                      + "(LinkedIn search and collections take &start=25, &start=50, …)")
            + ". If the Chrome tools are not available or Chrome is not connected, stop and "
            + (upload ? "return status \"needs_you\" with `reason` starting \"NO_CHROME:\"." : "begin `notes` with \"NO_CHROME:\".")
        }
        return "Use the PrepBoard browser tools (mcp__prepboard__…): navigate to a URL; read_page (interactive_only true for forms, false to read a "
        + "posting) returns elements with refs like r12; click(ref) / type(ref, text) act on them; after a click that changes the page call "
        + "wait then read_page again; page_text for the full posting text; screenshot when a page is unclear"
        + (upload ? "; upload_file(ref, path) attaches the résumé PDF" : "")
        + ". There are no tabs: one page at a time, use back() to return to a list."
    }

    static let discoverSchema = #"""
    {"type":"object","required":["leads","notes"],"properties":{
      "notes":{"type":"string"},
      "leads":{"type":"array","items":{"type":"object",
        "required":["company","title","location","link","role_number","source","jd","score","score_reason"],
        "properties":{
          "company":{"type":"string"},"title":{"type":"string"},"location":{"type":"string"},"link":{"type":"string"},
          "role_number":{"type":"string"},"source":{"type":"string","enum":["linkedin-rec","linkedin-search","careers"]},
          "jd":{"type":"string"},"score":{"type":"integer","minimum":0,"maximum":100},"score_reason":{"type":"string"}}}}}}
    """#

    static let tailorSchema = #"""
    {"type":"object","required":["tex","coverage","answers","ledger","notes"],"properties":{
      "tex":{"type":"string"},
      "coverage":{"type":"array","items":{"type":"object","required":["term","covered"],
        "properties":{"term":{"type":"string"},"covered":{"type":"boolean"}}}},
      "answers":{"type":"array","items":{"type":"object","required":["question","answer","kind","required"],
        "properties":{"question":{"type":"string"},"answer":{"type":"string"},"kind":{"type":"string","enum":["drafted","needs_you"]},"required":{"type":"boolean"}}}},
      "ledger":{"type":"array","items":{"type":"string"}},
      "notes":{"type":"string"}}}
    """#

    static let editSchema = #"""
    {"type":"object","required":["tex","notes"],"properties":{"tex":{"type":"string"},"notes":{"type":"string"}}}
    """#

    /// One edit of a tailored .tex on the user's instruction, under the tailor prompt's honesty and format rules.
    static func editPrompt(instruction: String, tex: String, lead: Lead, sources: [String], github: String, folder: String) -> String {
        """
        You edit my LaTeX résumé for one job posting on my instruction below. Return the complete edited .tex file as `tex`; I save \
        it myself. You cannot and must not write files. The other variants in the current folder (\(folder)) are my evidence: Read, Grep \
        and Glob them freely.

        MY INSTRUCTION:
        \(instruction)

        HONESTY, the rule that matters most:
        - Every claim on the page (every bullet, number, tool, language, framework, date, title, employer) must already appear in the \
        current file, in one of my existing variants in this folder or in my GitHub material below. Do not invent, round up, extrapolate \
        or "reasonably infer" anything. Never invent numbers. If my instruction asks for a claim with no evidence, do not add it: say so \
        in `notes` and record it in the HONESTY LEDGER block as not claimed.
        - Rewording must not change meaning or strength ("contributed to" never becomes "led"; a tool used once is not "expert").

        FORMAT:
        - Change only what the instruction needs. Keep the preamble, packages, macros, section commands and layout exactly as they are \
        unless the instruction is about them. The result must stay one page (cut bullets rather than shrink fonts or margins).
        - Keep the comment header at the top (VARIANT, JD MAP, HONESTY LEDGER) and update it when the content you changed makes it stale.
        - No emoji anywhere. Plain ASCII in comments. LaTeX that compiles with tectonic without extra packages.

        OUTPUT:
        - tex: the complete file.
        - notes: one or two sentences: what you changed, and anything you could not do honestly.

        THE JOB: \(lead.company), \(lead.title)\(lead.location.isEmpty ? "" : ", \(lead.location)")
        <job_description>
        \(lead.jd)
        </job_description>

        CURRENT FILE (\(lead.variantName).tex):
        <tex>
        \(tex)
        </tex>

        SOURCE VARIANTS in this folder: \(sources.isEmpty ? "(none)" : sources.map { $0 + ".tex" }.joined(separator: ", "))

        \(github.isEmpty ? "(No GitHub material loaded; the file and the variants are the only evidence.)" : github)
        """
    }

    static let honestySchema = #"""
    {"type":"object","required":["ok","untraceable"],"properties":{
      "ok":{"type":"boolean"},"untraceable":{"type":"array","items":{"type":"string"}}}}
    """#

    static let submitSchema = #"""
    {"type":"object","required":["status","reason","unknown_questions","confirmation","questions_only"],"properties":{
      "status":{"type":"string","enum":["submitted","needs_you","failed"]},"reason":{"type":"string"},
      "unknown_questions":{"type":"array","items":{"type":"string"}},"confirmation":{"type":"string"},"questions_only":{"type":"boolean"}}}
    """#

    private static func bullets(_ items: [String], empty: String = "(none)") -> String {
        items.isEmpty ? empty : items.map { "- " + $0 }.joined(separator: "\n")
    }

    static func discoverPrompt(settings: HuntSettings, variants: [ResumeVariant], known: [String], chrome: Bool = false) -> String {
        let companies = settings.companies.map { line -> String in
            let parts = line.components(separatedBy: " | ")
            return parts.count > 1 ? "\(parts[0].trimmingCharacters(in: .whitespaces)) (careers: \(parts[1].trimmingCharacters(in: .whitespaces)))" : line
        }
        let index = variants.map { v in
            let map = v.jdMap.prefix(6).map { String($0.prefix(140)) }.joined(separator: " | ")
            return "- \(v.name) | family: \(v.family) | company: \(v.company.isEmpty ? "general" : v.company) | role: \(v.roleTag.isEmpty ? "-" : v.roleTag)"
                + (map.isEmpty ? "" : "\n  JD MAP: \(map)")
        }
        return """
        You are my job scout. Using \(chrome ? "Chrome" : "PrepBoard's built-in browser"), find job postings for me and return them as \
        structured data. Now: \(DateCoding.string(.now)), my time zone: \(TimeZone.current.identifier).

        THE BROWSER: \(browserGuide(upload: false, chrome: chrome)) I am already signed in to LinkedIn there.

        READ ONLY, HUMAN PACE: only navigate, scroll and read. Never press Apply or Easy Apply, never save, follow, connect, \
        message, like, dismiss or change anything, never fill a form. Move like a person reading: a few seconds between pages, \
        no rapid-fire page opening. Look at about 150 listings at most across all sources, then stop. If LinkedIn shows a sign-in \
        page, a security checkpoint, a CAPTCHA or "unusual activity", do not try to get past it: stop everything and begin `notes` \
        with "SIGNED_OUT:" followed by what you saw. If a careers site does not load or blocks you, say so in `notes` and continue \
        with the other sources.

        SOURCES, in this order:
        1. LinkedIn "Recommended for you": https://www.linkedin.com/jobs/collections/recommended/ and the recommendations on \
        https://www.linkedin.com/jobs/. source = "linkedin-rec".
        2. LinkedIn search for each target company below, and for each keyword in each region, posted in the past week: \
        https://www.linkedin.com/jobs/search/?keywords=<company or keyword>&location=<region>&f_TPR=r604800 (add &f_C=<company id> \
        when you can see it). Open each promising result. source = "linkedin-search".
        3. Each target company's careers site: the URL given below, otherwise its careers/jobs page found from its own site. Search \
        there for my keywords and regions. source = "careers".

        WHAT TO COLLECT: a listing is promising when its title matches my keywords or one of my résumé families and its location is in \
        my regions (or remote within them). For each promising listing, open the posting itself and copy the full job description text \
        into `jd`: responsibilities, minimum and preferred qualifications, and any application questions that are visible without \
        pressing Apply or Easy Apply; never open the apply flow to read them. Plain text, no markup, keep it complete. Skip postings \
        older than 30 days, staffing-agency and recruiter reposts, roles that need a security clearance, and roles clearly above or \
        below my level (Director, VP, Principal, intern) unless a keyword asks for them. \(settings.answerBank.needsSponsorship == "Yes"
            ? "I need visa sponsorship: skip postings that say they do not sponsor, require US citizenship or permanent residency, or need a clearance. "
            : "")Skip \
        anything already in KNOWN below (same company and posting id, or same company and title). One entry per posting, no duplicates \
        across sources: if the same job appears on LinkedIn and the careers site, keep the careers-site link and the posting id.

        SCORING (0-100): how well the posting matches my résumé variants, judged from its requirements against the JD MAP lines below. \
        90-100: nearly every requirement is covered by one variant. 70-89: most are. 50-69: about half. Below 50: a stretch. Subtract \
        heavily for a hard requirement none of my variants mention (a language, platform or clearance). `score_reason`: one line naming \
        the requirements that decided the score.

        FIELDS: company (the hiring company, not the job board), title, location (as posted), link (the posting URL; for LinkedIn \
        https://www.linkedin.com/jobs/view/<id>/; for a careers-site posting hosted on Ashby, Greenhouse, Lever or Workable, the job page \
        there with the description, not its application form: I add /application or /apply myself), role_number (the posting, requisition \
        or job id if shown, else ""), source, jd, score, score_reason. `notes`: two or three sentences on what you covered and anything \
        that blocked you.

        MY TARGETS
        Regions:
        \(bullets(settings.regions, empty: "- United States"))
        Companies:
        \(bullets(companies, empty: "(none; use the recommendations and keyword searches only)"))
        Keywords:
        \(bullets(settings.keywords, empty: "- Software Engineer"))

        MY RÉSUMÉ VARIANTS (name | family | company | role, then the JD requirements that variant already covers):
        \(index.isEmpty ? "(none scanned yet; score on the keywords alone)" : index.joined(separator: "\n"))

        KNOWN (already in my tracker; skip these): company | posting id or - | title
        \(bullets(known))
        """
    }

    static func tailorPrompt(lead: Lead, base: ResumeVariant, baseTex: String, variants: [ResumeVariant], github: String, bank: AnswerBank, name: String, folder: String) -> String {
        let others = variants.filter { $0.name != base.name && $0.name != name }.map { v in
            let tag = [v.company, v.roleTag].filter { !$0.isEmpty }.joined(separator: ": ")
            return "\(v.name).tex" + (tag.isEmpty ? "" : " (\(tag))")
        }
        let facts = [("Name", bank.fullName), ("City", bank.city), ("Email", bank.email), ("Phone", bank.phone),
                     ("LinkedIn", bank.linkedin), ("GitHub", bank.github), ("Portfolio", bank.portfolio)]
            .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        return """
        You tailor my LaTeX résumé for one job posting. Start from the BASE VARIANT below and use the other variants in the current \
        folder (\(folder)) as evidence: Read, Grep and Glob them freely. Return the complete new .tex file as `tex`. You cannot and must \
        not write files; I save the file myself as \(name).tex.

        HONESTY, the rule that matters most:
        - Every claim on the page (every bullet, number, tool, language, framework, date, title, employer) must already appear in one of \
        my existing variants in this folder or in my GitHub material below. Do not invent, round up, extrapolate or "reasonably infer" \
        anything. Never invent numbers. If two variants disagree on a number, use the most recent one.
        - Reorder, reword and re-prioritise freely: pick the bullets that best match this JD, lead with them, cut what does not help. \
        Rewording must not change meaning or strength ("contributed to" never becomes "led"; a tool used once is not "expert").
        - A requirement in the JD with no evidence in my material is NOT claimed. It goes in the HONESTY LEDGER block as not claimed, \
        with what I could honestly say about it if asked.
        - Legal questions (work authorization, visa sponsorship, citizenship, immigration status, nationality, EEO such as gender, race, \
        veteran or disability status, and salary) are never drafted: return them with kind "needs_you" and an empty answer.

        FORMAT:
        - Keep the base's preamble, packages, macros, section commands and layout exactly as they are; change only the content. One page: \
        the result must stay one page (cut bullets rather than shrink fonts or margins).
        - Keep the comment-header convention at the top of the file, in the base's style: "%" comment lines holding a line \
        "%    \(lead.company.uppercased()) VARIANT: <role title, team, location>", then a "%    JD MAP:" block whose bullets are \
        "%      * \\"<JD requirement>\\" -> <where the page covers it and which variant or repo it came from>", then a \
        "%    HONESTY LEDGER:" block whose bullets are "%      * <requirement or term>: not claimed, <why, and what I can say if asked>". \
        Wrap comment lines at about 90 characters. Replace the base's VARIANT, JD MAP and HONESTY LEDGER with the new ones; drop the \
        base's other header notes unless they still apply.
        - No emoji anywhere. Plain ASCII in comments. LaTeX that compiles with tectonic without extra packages.

        OUTPUT:
        - tex: the complete file.
        - coverage: 8 to 15 of the JD's important requirements as {term, covered}; covered means the page now shows real evidence for it.
        - answers: only for application questions visible in the JD text below (e.g. "Why do you want to work here?", "Describe a project \
        you are proud of"). Each is {question, answer, kind, required}: kind "drafted" with an answer in first person, under 120 words, \
        built only from my material and specific to this company and role (name the product or team from the JD my work connects to); or kind "needs_you" with "" for legal questions. required is true when the listing says so. An empty \
        array when the listing shows no questions.
        - ledger: the HONESTY LEDGER bullets as plain strings.
        - notes: one or two sentences: which variants you took from and anything I should double-check.

        THE JOB
        Company: \(lead.company)
        Title: \(lead.title)
        Location: \(lead.location)
        Link: \(lead.link)
        <job_description>
        \(lead.jd)
        </job_description>

        NEW FILE NAME: \(name).tex
        BASE VARIANT: \(base.name).tex (chosen because: \(lead.baseReason))
        <base_tex>
        \(baseTex)
        </base_tex>

        OTHER VARIANTS in this folder (their headers record what each one verified; Read any of them for evidence):
        \(bullets(others))

        ABOUT ME (for the contact header only):
        \(bullets(facts, empty: "(use the base's header unchanged)"))

        \(github.isEmpty ? "(No GitHub material loaded; the variants are the only evidence.)" : github)
        """
    }

    /// Files to read my variants, plus the web to learn what the company makes. No browser, no writes.
    static let draftTools = "Read Grep Glob WebSearch WebFetch"

    static func draftPrompt(lead: Lead, questions: [String], tex: String, github: String, bank: AnswerBank, folder: String) -> String {
        let history = [("Education", bank.education), ("Employment", bank.employment), ("LinkedIn", bank.linkedin), ("GitHub", bank.github),
                       ("Portfolio", bank.portfolio)]
            .filter { !$0.1.isEmpty }.map { "\($0.0):\n\($0.1)" }
        return """
        You answer open-ended job application questions for me, written for this one role at this one company. Now: \(DateCoding.string(.now)).

        HOW:
        - First learn the company: use WebSearch and WebFetch for its products, recent launches and engineering work (its own site, \
        engineering blog, product pages). Use what you find to make each answer specific to this company and role, e.g. connect my \
        work to a product they ship. Facts about the company must come from what you read.
        - Facts about me come only from my material: the résumé variants in \(folder) (Read, Grep and Glob them), the tailored résumé \
        below, my GitHub material and my history below. Never invent a project, number, title, tool or outcome; never round up; \
        "contributed to" never becomes "led". Pick the strongest real example for each question (for "what are you proud of", a \
        concrete project with what I built and why it mattered).
        - First person, plain and specific, no buzzwords, no emoji, under 150 words unless the question asks for more.
        - Return kind "needs_you" with an empty answer for anything legal (work authorization, sponsorship, citizenship, EEO, salary), \
        anything that asks for a file or link I have not given, and anything my material cannot honestly answer.
        - Return one entry per question below, with the question text exactly as given. `notes`: one line on the sources you used.

        THE ROLE
        Company: \(lead.company)
        Title: \(lead.title)
        Location: \(lead.location)
        Link: \(lead.link)
        <job_description>
        \(lead.jd)
        </job_description>

        QUESTIONS:
        \(bullets(questions))

        <tailored_resume_tex>
        \(tex.isEmpty ? "(none yet: use the variants in the folder)" : tex)
        </tailored_resume_tex>

        \(history.joined(separator: "\n\n"))

        \(github.isEmpty ? "(No GitHub material loaded.)" : github)
        """
    }

    static let draftSchema = #"""
    {"type":"object","required":["answers","notes"],"properties":{
      "answers":{"type":"array","items":{"type":"object","required":["question","answer","kind","required"],
        "properties":{"question":{"type":"string"},"answer":{"type":"string"},"kind":{"type":"string","enum":["drafted","needs_you"]},"required":{"type":"boolean"}}}},
      "notes":{"type":"string"}}}
    """#

    static func profilePrompt(tex: String, linkedin: String) -> String {
        let sources = linkedin.isEmpty ? "my résumé below"
            : "my résumé below and my LinkedIn profile at \(linkedin) (open it in the browser and read the Experience and Education sections; change nothing there)"
        return """
        Read my education and work history for job application forms. Use only what \(sources) \
        says. Never guess, never round up, never fill a field the sources do not state: leave it "". When the résumé and LinkedIn \
        disagree, use the résumé. Now: \(DateCoding.string(.now)).

        Fields:
        - school, degree (e.g. "Master of Science"), major, graduation (month and year, "expected" if in the future), gpa (as written): \
        my most recent degree.
        - current_employer, current_title: my current job, or the most recent one if none is current.
        - years_experience: whole years of full-time professional work, counted from the dates (internships excluded); "" if unclear.
        - education: one line per degree, most recent first: "School | Degree, Major | Start – End | GPA if stated".
        - employment: one line per job, most recent first: "Company | Title | Location | Start – End".
        - notes: anything you left empty and why, briefly.

        <resume_tex>
        \(tex)
        </resume_tex>
        """
    }

    static let profileSchema = """
    {"type":"object","required":["school","degree","major","graduation","gpa","current_employer","current_title","years_experience","education","employment","notes"],
     "properties":{"school":{"type":"string"},"degree":{"type":"string"},"major":{"type":"string"},"graduation":{"type":"string"},
      "gpa":{"type":"string"},"current_employer":{"type":"string"},"current_title":{"type":"string"},"years_experience":{"type":"string"},
      "education":{"type":"string"},"employment":{"type":"string"},"notes":{"type":"string"}}}
    """

    static func honestyPrompt(tex: String, sources: [String], github: String, folder: String) -> String {
        """
        You are the honesty checker for a new résumé variant. The file below was generated from my existing variants in the current \
        folder (\(folder)) and from my GitHub material. Check every claim in the page content (each bullet, number, tool, framework, \
        language, title, employer, date). A claim passes when the same claim, at the same or weaker strength, appears in at least one \
        of the SOURCE VARIANTS (Read or Grep them in this folder) or in the GitHub material. Numbers must match a number in a source \
        exactly. Rewordings and reorderings are fine; stronger verbs, bigger numbers, added tools, added responsibilities or new \
        employers are not. Ignore the comment header and the LaTeX preamble; check only what a reader of the PDF would see.

        Return ok = true and an empty `untraceable` list when everything traces. Otherwise ok = false and `untraceable` with one entry \
        per problem: quote the claim briefly (under 25 words) and say why it does not trace, e.g. \
        "\\"Led a team of 4 engineers\\": sources say \\"worked with 4 engineers\\"". No emoji.

        SOURCE VARIANTS:
        \(bullets(sources.map { $0 + ".tex" }))

        <new_tex>
        \(tex)
        </new_tex>

        \(github.isEmpty ? "(No GitHub material loaded.)" : github)
        """
    }

    static func submitPrompt(lead: Lead, pdfPath: String, bank base: AnswerBank, chrome: Bool = false) -> String {
        let bank = lead.bank(base)
        var notes = ATS.formNotes(ATS.kind(lead.link))
        if chrome { notes = notes.replacingOccurrences(of: "upload_file", with: "file_upload") }   // the Chrome tool's name
        let target = [
            "Start here: \(ATS.applicationURL(lead.link))",
            "Posting: \(lead.link)",
            "Company: \(lead.company); Title: \(lead.title)\(lead.roleNumber.isEmpty ? "" : "; Posting id: \(lead.roleNumber)")",
            "Résumé PDF to upload wherever the form asks for a résumé or CV: \(pdfPath)",
            notes.isEmpty ? nil : "Form notes for this site: \(notes)",
        ].compactMap { $0 }.joined(separator: "\n")
        let answers = lead.answers.filter { $0.kind != "choice" }.map { "- Q: \($0.question)\($0.required ? " (required)" : "")\n  A: \($0.answer)" }
        let choices = Lead.Choice.allCases.compactMap { c in lead.choice(c).map { "- \(c.rawValue): \($0)" } }
        let facts = [("Full name", bank.fullName), ("Email", bank.email), ("Phone", bank.phone), ("City / location", bank.city),
                     ("LinkedIn", bank.linkedin), ("GitHub", bank.github), ("Portfolio / website", bank.portfolio),
                     ("Résumé link (when a form asks for a link or URL to my résumé instead of a file)", bank.resumeLink.isEmpty ? bank.portfolio : bank.resumeLink),
                     ("Work authorization", bank.workAuthorization), ("Needs visa sponsorship", bank.needsSponsorship),
                     ("Citizenship / immigration status", bank.citizenship),
                     ("Earliest start date", bank.startDate), ("Willing to relocate", bank.relocation),
                     ("Salary expectation", bank.salary.isEmpty ? "(leave blank; if required, stop and report it)" : bank.salary),
                     ("Gender", bank.gender.isEmpty ? "Decline to self-identify" : bank.gender),
                     ("Race / ethnicity", bank.race.isEmpty ? "Decline to self-identify" : bank.race),
                     ("Veteran status", bank.veteran.isEmpty ? "Decline to self-identify" : bank.veteran),
                     ("Disability status", bank.disability.isEmpty ? "Decline to self-identify" : bank.disability),
                     ("School", bank.school), ("Degree", bank.degree), ("Major / field of study", bank.major),
                     ("Graduation date", bank.graduation), ("GPA", bank.gpa), ("Current or most recent employer", bank.currentEmployer),
                     ("Current or most recent job title", bank.currentTitle), ("Years of professional experience", bank.yearsExperience),
                     ("How I heard about the job", !bank.referralSource.isEmpty ? bank.referralSource
                        : lead.source.hasPrefix("linkedin") ? "LinkedIn" : lead.source == "careers" ? "Company careers site" : "")]
            .map { "- \($0.0): \($0.1.isEmpty ? "(unknown; if the form requires it, stop and report it)" : $0.1)" }
        let history = [("EDUCATION HISTORY (most recent first)", bank.education), ("EMPLOYMENT HISTORY (most recent first)", bank.employment)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.0):\n\($0.1)" }
        let saved = bank.saved.sorted { $0.key < $1.key }.map { "- Q: \($0.key)\n  A: \($0.value)" }
        return """
        You submit one job application for me in \(chrome ? "Chrome" : "PrepBoard's built-in browser"), using only the answers below. Fill \
        the form, upload my résumé PDF, press Submit exactly once when everything required is answered from this list, and report what \
        happened. Now: \(DateCoding.string(.now)).

        THE BROWSER: \(browserGuide(upload: true, chrome: chrome)) I am already signed in to LinkedIn there.

        \(target)

        RULES:
        - Start at the "Start here" URL and reach the application form from there. On LinkedIn, use Easy Apply when it is offered; \
        otherwise press Apply, and the company's own application page (Ashby, Greenhouse, Lever, Workable or a company form) opens in \
        \(chrome ? "Chrome, sometimes in a new tab" : "this same browser"): continue there with these same rules.
        - Fill every field from the APPROVED ANSWERS and STANDARD FACTS below. Never make up an answer, never guess, never reuse text from \
        elsewhere. Optional fields with no answer here: leave blank. EEO questions: use the given answers, otherwise "Decline to self-identify" \
        or the closest "I don't wish to answer" option.
        - Upload the PDF given above; do not use a profile résumé or paste text instead.
        - STOP CONDITIONS. Do not submit, leave the page exactly where you stopped, and return status "needs_you" with the reason and every \
        question you could not answer in `unknown_questions` (the question text as shown), when any of these happens: a required question is \
        not covered by the answers below; the site asks you to create an account, sign in, or complete two-factor authentication; a CAPTCHA; \
        an assessment, test, video or coding exercise; a cover letter or other document you do not have; a request to pay; the posting is \
        closed or a different job opens; an error you cannot resolve; or anything else unexpected.
        - Return status "failed" with the reason only when the application page cannot be reached at all.
        - Before pressing Submit, re-read the whole form: every required field is filled, the PDF is attached, and nothing contradicts the \
        answers below. Press Submit once. Then read the confirmation (confirmation number, "application received" message or the email \
        notice) into `confirmation` and return status "submitted". If you cannot tell whether it went through, return "needs_you" and say \
        so; never submit twice.
        - questions_only: true when the only thing that stopped you is questions in `unknown_questions` (the form was otherwise ready \
        and nothing else, such as a sign-in, CAPTCHA, upload or error, blocked you); false otherwise, and false when you submitted.
        - Do nothing else in the browser: no other applications, no profile edits, no messages, no saving jobs.

        \(choices.isEmpty ? "" : "MY CHOICES FOR THIS ROLE (these override any answer or fact below on the same subject):\n" + choices.joined(separator: "\n") + "\n")
        APPROVED ANSWERS (questions from this posting, approved by me):
        \(bullets(answers, empty: "(none beyond the standard facts)"))

        STANDARD FACTS (count as approved answers for the usual fields):
        \(facts.joined(separator: "\n"))

        SAVED ANSWERS (reuse when the form asks the same question):
        \(bullets(saved))
        \(history.isEmpty ? "" : "\nUse these for education and work-experience sections (add one entry per line, as the form allows):\n" + history.joined(separator: "\n\n"))
        """
    }

    /// The shell line for one headless run. `tools` is the whole built-in set the run gets (`--tools`, so the user's global Bash and
    /// web allowlist never applies) and is also allowed outright; "" leaves only the MCP tools in `browserFlags`.
    nonisolated static func claudeCommand(browserFlags: String?, tools: String, schemaPath: String, cwd: String) -> String {
        let names = tools.split(separator: " ")
        return "cd '\(LatexBuild.quoted(cwd))' && claude -p \(browserFlags.map { $0 + " " } ?? "")--output-format json "
            + "--json-schema \"$(cat '\(LatexBuild.quoted(schemaPath))')\" --tools \"\(names.joined(separator: ","))\""
            + (names.isEmpty ? "" : " --allowedTools " + names.joined(separator: " "))
    }

    /// One headless `claude -p` call with a JSON schema; `browserFlags` (from `BrowserServer.claudeFlags` or `chromeFlags`, which already
    /// carry `--allowedTools`) attaches a browser, nil runs without one; `tools` is the built-in tool set; `cwd` is where Claude may read files.
    nonisolated static func check<T: Decodable>(_ type: T.Type, prompt: String, schema: String, browserFlags: String?, tools: String, cwd: String?) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-hunt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schemaFile = dir.appendingPathComponent("schema-\(UUID().uuidString.prefix(8)).json")
        try schema.write(to: schemaFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: schemaFile) }
        let cmd = claudeCommand(browserFlags: browserFlags, tools: tools, schemaPath: schemaFile.path, cwd: cwd ?? dir.path)
        let output = await ClaudeCode.shellResult(cmd, stdin: prompt)
        return try decodeResult(type, output: output)
    }

    /// A login profile may print a banner before Claude's JSON; stderr must never be mixed into the JSON document.
    /// Preserve the actual CLI failure so browser setup, permissions, and outdated CLI flags can be fixed from the app.
    nonisolated static func decodeResult<T: Decodable>(_ type: T.Type, output: ClaudeCode.ShellResult) throws -> T {
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let obj = ClaudeCode.jsonObject(stdout)
        if output.exitCode != 0 || obj?["is_error"] as? Bool == true {
            let errors = (obj?["errors"] as? [String])?.joined(separator: "\n") ?? ""
            let reason = [obj?["result"] as? String ?? "", errors, output.stderr, obj == nil ? stdout : ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            throw Learning.Failure.message(reason.map { String($0.suffix(1200)) } ?? "Claude Code exited with code \(output.exitCode).")
        }
        guard let obj else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Learning.Failure.message(detail.isEmpty ? "Claude Code returned no result. Open Claude Code in Terminal to check sign-in and browser permissions."
                                          : String(detail.suffix(1200)))
        }
        let structured = obj["structured_output"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            ?? (obj["result"] as? String).map { Data($0.utf8) }
        guard let structured, let value = try? JSONDecoder().decode(T.self, from: structured) else {
            let denials = obj["permission_denials"] as? [[String: Any]] ?? []
            if !denials.isEmpty {
                throw Learning.Failure.message("Claude couldn't use a required tool. Open Connect extension and review the application's site and file permissions, then try again.")
            }
            throw Learning.Failure.message("Claude returned an incomplete result. \(String((obj["result"] as? String ?? "Try again after checking Claude Code in Terminal.").suffix(800)))")
        }
        return value
    }

}
#endif
