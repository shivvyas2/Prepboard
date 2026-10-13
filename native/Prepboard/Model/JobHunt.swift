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
}

#if os(macOS)
import Observation

/// Finds jobs, tailors a résumé variant for each good match and submits the ones the user queued, all through
/// the user's local Claude Code. Discovery only reads; `submit` is the only step that acts on a site.
@MainActor
@Observable
final class JobHunt {
    enum Phase: Equatable { case idle, discovering, tailoring(done: Int, total: Int), submitting(String), honesty(String) }

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
    var isRunning: Bool { phase != .idle }
    var tailoredToday: Int { Self.dailyCount("tailored") }
    var submittedToday: Int { Self.dailyCount("submitted") }

    private var container: ModelContainer?
    private weak var claude: ClaudeCode?
    private weak var cloud: Cloud?
    private weak var github: GitHub?
    private var scheduleTimer: Timer?
    private var queueTimer: Timer?
    private var lastSubmit: Date? = UserDefaults.standard.object(forKey: "hunt.lastSubmit") as? Date {
        didSet { UserDefaults.standard.set(lastSubmit, forKey: "hunt.lastSubmit") }
    }

    /// Starts the schedule: a daily run checked every 5 minutes, the submit queue every minute.
    func attach(container: ModelContainer, claude: ClaudeCode, cloud: Cloud, github: GitHub) {
        self.container = container; self.claude = claude; self.cloud = cloud; self.github = github
        scheduleTimer?.invalidate(); queueTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        queueTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processSubmitQueue() }
        }
        rescan()
        runIfDue()
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

    /// The Answer Bank value for a form question, if the question is one the bank covers.
    /// `legal` answers (plus relocation and start date) always come from the bank; the others keep a drafted answer when the bank is empty.
    /// Citizenship, immigration status and nationality have no bank field and are always left to the user.
    static func bankAnswer(for question: String, bank: AnswerBank) -> (answer: String, kind: String, legal: Bool)? {
        let q = question.lowercased()
        func has(_ words: String...) -> Bool {
            words.contains { q.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0), options: .regularExpression) != nil }
        }
        var value: String, legal = true, decline = false, blank = false
        if has("citizen", "immigration", "nationality") { return ("", "needs_you", true) }
        if has("sponsor", "visa") { value = bank.needsSponsorship }
        else if has("authoriz", "authoris", "legally", "eligible to work", "right to work", "work permit") { value = bank.workAuthorization }
        else if has("salary", "compensation", "pay expectation") { value = bank.salary; blank = true }
        else if has("gender", "sex") { value = bank.gender; decline = true }
        else if has("race", "ethnic") { value = bank.race; decline = true }
        else if has("veteran", "military") { value = bank.veteran; decline = true }
        else if has("disabilit") { value = bank.disability; decline = true }
        else if has("relocat") { value = bank.relocation }
        else if has("start date", "available to start", "availability", "earliest", "notice period") { value = bank.startDate }
        else if has("linkedin") { value = bank.linkedin; legal = false }
        else if has("github") { value = bank.github; legal = false }
        else if has("portfolio", "website", "personal site") { value = bank.portfolio; legal = false }
        else if has("email") { value = bank.email; legal = false }
        else if has("phone", "telephone", "mobile number") { value = bank.phone; legal = false }
        else if has("full name", "your name", "first name", "last name", "legal name") { value = bank.fullName; legal = false }
        else if has("city", "where are you located", "current location", "where do you live") { value = bank.city; legal = false }
        else if let saved = bank.saved.first(where: { $0.key.lowercased() == q })?.value { value = saved; legal = false }
        else { return nil }
        if !value.isEmpty { return (value, "bank", legal) }
        if decline { return ("Decline to self-identify", "bank", legal) }
        if blank { return ("", "bank", legal) }
        return ("", "needs_you", legal)
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
        answers.map { a in
            guard let b = bankAnswer(for: a.question, bank: bank) else { return a }
            if !b.legal, b.answer.isEmpty, a.kind == "drafted", !a.answer.isEmpty { return a }
            var m = a; m.answer = b.answer; m.kind = b.kind
            return m
        }
    }

    // MARK: schedule

    func runIfDue() {
        guard phase == .idle, let container, let claude, claude.isReady, !claude.busy, let s = settings(in: container.mainContext), s.auto else { return }
        guard Calendar.current.component(.hour, from: .now) >= s.runHour else { return }
        if let lastRun, Calendar.current.isDateInToday(lastRun) { return }
        Task { await run() }
    }

    /// Submits the oldest queued lead, one at a time, at least 2 minutes apart and within the daily limit.
    func processSubmitQueue() {
        guard phase == .idle, let container, let claude, claude.isReady, !claude.busy else { return }
        if let lastSubmit, Date.now.timeIntervalSince(lastSubmit) < Self.submitSpacing { return }
        let context = container.mainContext
        guard let s = settings(in: context), Self.dailyCount("submitted") < s.dailySubmitLimit else { return }
        let ready = LeadStatus.ready.rawValue
        let queued = (try? context.fetch(FetchDescriptor<Lead>(predicate: #Predicate { $0.submitRequested && $0.statusRaw == ready }))) ?? []
        guard let lead = queued.min(by: { $0.updatedAt < $1.updatedAt }) else { return }
        Task { await submit(lead) }
    }

    /// Refreshes `variants` from the résumé folder.
    func rescan() {
        guard let container else { return }
        let folder = settings(in: container.mainContext)?.resumeFolder ?? HuntSettings.defaultResumeFolder
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
        let context = container.mainContext
        let settings = HuntSettings.current(context)
        phase = .discovering
        error = nil
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        rescan()
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
            let prompt = Self.discoverPrompt(settings: settings, variants: variants, known: knownLines)
            let result = try await Self.check(DiscoverResult.self, prompt: prompt, schema: Self.discoverSchema, chrome: true, tools: Self.discoverTools, cwd: nil)
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
                else { fresh.append(lead) }
                context.insert(lead)
                found += 1
            }
            try context.save()
            if result.notes.uppercased().hasPrefix("SIGNED_OUT") {
                error = "Sign in to LinkedIn in Chrome, then run the hunt again. " + result.notes.dropFirst("SIGNED_OUT".count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
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
        let room = max(0, settings.dailyTailorLimit - Self.dailyCount("tailored"))
        let batch = Array(pending.sorted { $0.score > $1.score }.prefix(room))
        var ready = 0, needsYou = 0, failed = 0
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
        lastRun = .now
        lastSummary = found == 0 && batch.isEmpty ? "Nothing new" : [
            "\(found) found", "\(batch.count) tailored", ready > 0 ? "\(ready) ready" : nil, needsYou > 0 ? "\(needsYou) need you" : nil,
            failed > 0 ? "\(failed) failed" : nil, skipped > 0 ? "\(skipped) skipped" : nil, pending.count > batch.count ? "\(pending.count - batch.count) waiting for tomorrow" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: tailor

    /// Writes a tailored variant for one lead; also used by Regenerate on a card.
    func tailor(_ lead: Lead) async {
        guard phase == .idle, let container, let claude else { return }
        guard claude.isReady else { error = "Connect Claude Code in Profile to tailor a résumé."; return }
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
        // Variants other leads generated but nobody has reviewed are neither evidence nor a base; only submitted ones count.
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        let generated = Set(leads.filter { $0.id != lead.id && $0.status != .submitted && !$0.variantName.isEmpty }.map(\.variantName))
        let evidence = variants.filter { !generated.contains($0.name) && $0.name != lead.variantName }
        guard let (base, why) = ResumeLibrary.pickBase(for: lead, variants: evidence, winners: ResumeLibrary.winners(roles: roles)) else {
            return fail("No résumé variants found in \(folder)")
        }
        guard let baseTex = try? String(contentsOfFile: base.path, encoding: .utf8) else { return fail("Couldn't read \(base.name).tex") }
        lead.baseVariant = base.name; lead.baseReason = why
        let bank = settings.answerBank
        let userName = bank.fullName.isEmpty ? "Shiv Vyas" : bank.fullName
        if lead.variantName.isEmpty {
            let existing = Set(variants.map(\.name) + leads.filter { $0.id != lead.id && !$0.variantName.isEmpty }.map(\.variantName))
            lead.variantName = ResumeLibrary.variantName(userName: userName, company: lead.company, title: lead.title, existing: existing)
        }
        let name = lead.variantName
        let texPath = folder + "/" + name + ".tex"
        let githubContext = github?.context ?? ""
        do {
            let prompt = Self.tailorPrompt(lead: lead, base: base, baseTex: baseTex, variants: evidence, github: githubContext, bank: bank, name: name, folder: folder)
            var result = try await Self.check(TailorResult.self, prompt: prompt, schema: Self.tailorSchema, chrome: false, tools: Self.fileTools, cwd: folder)
            try result.tex.write(toFile: texPath, atomically: true, encoding: .utf8)
            var pdfPath: String
            do {
                pdfPath = try await LatexBuild.build(texPath: texPath)
            } catch let first as LatexBuild.Failure {
                let retry = prompt + "\n\nYOUR PREVIOUS ATTEMPT DID NOT COMPILE. Fix the LaTeX (keep the same content rules) and return the whole file again.\n<compile_log>\n\(first.log)\n</compile_log>\n<previous_tex>\n\(result.tex)\n</previous_tex>"
                result = try await Self.check(TailorResult.self, prompt: retry, schema: Self.tailorSchema, chrome: false, tools: Self.fileTools, cwd: folder)
                try result.tex.write(toFile: texPath, atomically: true, encoding: .utf8)
                pdfPath = try await LatexBuild.build(texPath: texPath)
            }
            lead.coverage = result.coverage
            var uploadNote = ""   // a failed upload never fails a built variant; the PDF is still on disk
            if let cloud {
                if !lead.pdfDocId.isEmpty, let old = try? context.fetch(FetchDescriptor<Doc>()).first(where: { $0.id == lead.pdfDocId }) {
                    await cloud.deleteFile(for: old); context.delete(old)
                }
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: pdfPath))
                    let doc = try await cloud.importPDF(data, fileName: name + ".pdf", roleId: "", context: context)
                    doc.tags = ["pdf", "resume", "hunt"]
                    lead.pdfDocId = doc.id
                } catch {
                    lead.pdfDocId = ""
                    uploadNote = "PDF not uploaded (\(error.localizedDescription)); it is at \(pdfPath)"
                }
            }
            func reason(_ text: String) -> String { [text, uploadNote].filter { !$0.isEmpty }.joined(separator: " ") }
            Self.bump("tailored")
            rescan()
            phase = .honesty(lead.company)
            let answers = Self.mergeAnswers(result.answers, bank: bank)
            do {
                let sources = evidence.map(\.name).filter { $0 != name }
                let honesty = try await Self.check(HonestyResult.self, prompt: Self.honestyPrompt(tex: result.tex, sources: sources, github: githubContext, folder: folder),
                                                   schema: Self.honestySchema, chrome: false, tools: Self.fileTools, cwd: folder)
                lead.answers = answers
                if honesty.ok && honesty.untraceable.isEmpty {
                    lead.status = .ready; lead.reason = reason(result.notes)
                } else {
                    lead.status = .needsYou
                    lead.flagged = honesty.untraceable.isEmpty ? "Honesty check reported a problem without details; review the résumé" : honesty.untraceable.joined(separator: "\n")
                    lead.reason = reason("Check these claims")
                }
            } catch {
                lead.answers = answers
                lead.status = .needsYou; lead.flagged = "Honesty check could not run: \(error.localizedDescription)"; lead.reason = reason("Check the résumé yourself")
            }
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

    // MARK: submit

    /// The only place that presses Submit. Creates the Role on success; clears `submitRequested` either way.
    func submit(_ lead: Lead) async {
        guard phase == .idle, let container, let claude else { return }
        guard claude.isReady else { error = "Connect Claude Code in Profile to submit applications."; return }
        let context = container.mainContext
        let settings = HuntSettings.current(context)
        guard Self.dailyCount("submitted") < settings.dailySubmitLimit else { error = "Daily submit limit reached (\(settings.dailySubmitLimit)). The queue continues tomorrow."; return }
        guard lead.canSubmit else {
            lead.submitRequested = false; lead.status = .needsYou; lead.reason = "Fill in the remaining answers first"; lead.updatedAt = .now
            try? context.save()
            return
        }
        guard lead.submitRequested else { return }
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
        error = nil
        claude.busy = true
        defer { phase = .idle; claude.busy = false }
        lead.status = .submitting; lead.updatedAt = .now
        try? context.save()
        let pdfPath = settings.resumeFolder + "/" + lead.variantName + ".pdf"
        if lead.variantName.isEmpty || !FileManager.default.fileExists(atPath: pdfPath) {
            lead.status = .failed; lead.reason = "The PDF is missing; regenerate the résumé first"
        } else {
            lastSubmit = .now   // every real attempt counts toward the spacing, even one that throws
            do {
                let result = try await Self.check(SubmitResult.self, prompt: Self.submitPrompt(lead: lead, pdfPath: pdfPath, bank: settings.answerBank),
                                                  schema: Self.submitSchema, chrome: true, tools: Self.submitTools, cwd: nil)
                switch result.status {
                case "submitted":
                    let role = Role(company: lead.company, title: lead.title.isEmpty ? "Role" : lead.title, location: lead.location,
                                    roleNumber: lead.roleNumber, link: lead.link, stage: .applied)
                    role.source = "hunt"; role.appliedAt = .now; role.resumeVariant = lead.variantName
                    role.activity = "- \(DateCoding.dayString(.now)) · Hunt · Applied with \(lead.variantName)"
                    context.insert(role)
                    lead.roleId = role.id; lead.status = .submitted; lead.reason = result.confirmation
                    Self.bump("submitted")
                case "needs_you":
                    lead.status = .needsYou; lead.flagged = result.unknown_questions.joined(separator: "\n")
                    lead.reason = result.reason.isEmpty ? "The form needs you" : result.reason
                    lead.answers = Self.addingUnknown(result.unknown_questions, to: lead.answers)
                default:
                    lead.status = .failed; lead.reason = result.reason.isEmpty ? "Submit failed" : result.reason
                }
            } catch {
                lead.status = .needsYou; lead.flagged = "Submit ended without a result; check the open Chrome tab before trying again"
                lead.reason = error.localizedDescription
            }
        }
        lead.submitRequested = false; lead.updatedAt = .now
        try? context.save()
    }

    // MARK: Claude

    /// Chrome reading tools only (JobSync's list without Gmail and Calendar).
    static let discoverTools = JobSync.tools.split(separator: " ").filter { $0.hasPrefix("mcp__claude-in-chrome") }.joined(separator: " ")
    static let submitTools = discoverTools + " mcp__claude-in-chrome__form_input mcp__claude-in-chrome__file_upload mcp__claude-in-chrome__read_page"
    static let fileTools = "Read Grep Glob"

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

    static let honestySchema = #"""
    {"type":"object","required":["ok","untraceable"],"properties":{
      "ok":{"type":"boolean"},"untraceable":{"type":"array","items":{"type":"string"}}}}
    """#

    static let submitSchema = #"""
    {"type":"object","required":["status","reason","unknown_questions","confirmation"],"properties":{
      "status":{"type":"string","enum":["submitted","needs_you","failed"]},"reason":{"type":"string"},
      "unknown_questions":{"type":"array","items":{"type":"string"}},"confirmation":{"type":"string"}}}
    """#

    private static func bullets(_ items: [String], empty: String = "(none)") -> String {
        items.isEmpty ? empty : items.map { "- " + $0 }.joined(separator: "\n")
    }

    static func discoverPrompt(settings: HuntSettings, variants: [ResumeVariant], known: [String]) -> String {
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
        You are my job scout. Using my signed-in Chrome, find job postings for me and return them as structured data. \
        Now: \(DateCoding.string(.now)), my time zone: \(TimeZone.current.identifier).

        READ ONLY, HUMAN PACE: only navigate, scroll and read. Never press Apply or Easy Apply, never save, follow, connect, \
        message, like, dismiss or change anything, never fill a form. Move like a person reading: a few seconds between pages, \
        no rapid-fire tab opening. Look at about 150 listings at most across all sources, then stop. If LinkedIn shows a sign-in \
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
        below my level (Director, VP, Principal, intern) unless a keyword asks for them. Skip \
        anything already in KNOWN below (same company and posting id, or same company and title). One entry per posting, no duplicates \
        across sources: if the same job appears on LinkedIn and the careers site, keep the careers-site link and the posting id.

        SCORING (0-100): how well the posting matches my résumé variants, judged from its requirements against the JD MAP lines below. \
        90-100: nearly every requirement is covered by one variant. 70-89: most are. 50-69: about half. Below 50: a stretch. Subtract \
        heavily for a hard requirement none of my variants mention (a language, platform or clearance). `score_reason`: one line naming \
        the requirements that decided the score.

        FIELDS: company (the hiring company, not the job board), title, location (as posted), link (the posting URL; for LinkedIn \
        https://www.linkedin.com/jobs/view/<id>/), role_number (the posting, requisition or job id if shown, else ""), source, jd, score, \
        score_reason. `notes`: two or three sentences on what you covered and anything that blocked you.

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
        built only from my material; or kind "needs_you" with "" for legal questions. required is true when the listing says so. An empty \
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

    static func submitPrompt(lead: Lead, pdfPath: String, bank: AnswerBank) -> String {
        let answers = lead.answers.map { "- Q: \($0.question)\($0.required ? " (required)" : "")\n  A: \($0.answer)" }
        let facts = [("Full name", bank.fullName), ("Email", bank.email), ("Phone", bank.phone), ("City / location", bank.city),
                     ("LinkedIn", bank.linkedin), ("GitHub", bank.github), ("Portfolio / website", bank.portfolio),
                     ("Work authorization", bank.workAuthorization), ("Needs visa sponsorship", bank.needsSponsorship),
                     ("Earliest start date", bank.startDate), ("Willing to relocate", bank.relocation),
                     ("Salary expectation", bank.salary.isEmpty ? "(leave blank; if required, stop and report it)" : bank.salary),
                     ("Gender", bank.gender.isEmpty ? "Decline to self-identify" : bank.gender),
                     ("Race / ethnicity", bank.race.isEmpty ? "Decline to self-identify" : bank.race),
                     ("Veteran status", bank.veteran.isEmpty ? "Decline to self-identify" : bank.veteran),
                     ("Disability status", bank.disability.isEmpty ? "Decline to self-identify" : bank.disability)]
            .map { "- \($0.0): \($0.1.isEmpty ? "(unknown; if the form requires it, stop and report it)" : $0.1)" }
        let saved = bank.saved.sorted { $0.key < $1.key }.map { "- Q: \($0.key)\n  A: \($0.value)" }
        return """
        You submit one job application for me in my signed-in Chrome, using only the answers below. Fill the form, upload my résumé PDF, \
        press Submit exactly once when everything required is answered from this list, and report what happened. \
        Now: \(DateCoding.string(.now)).

        Posting: \(lead.link)
        Company: \(lead.company); Title: \(lead.title)\(lead.roleNumber.isEmpty ? "" : "; Posting id: \(lead.roleNumber)")
        Résumé PDF to upload wherever the form asks for a résumé or CV: \(pdfPath)

        RULES:
        - Open the posting and go to its own application form through its Apply button. Prefer the company's application page; use \
        LinkedIn Easy Apply only when it is the posting's only way to apply.
        - Fill every field from the APPROVED ANSWERS and STANDARD FACTS below. Never make up an answer, never guess, never reuse text from \
        elsewhere. Optional fields with no answer here: leave blank. EEO questions: use the given answers, otherwise "Decline to self-identify" \
        or the closest "I don't wish to answer" option.
        - Upload the PDF given above; do not use a profile résumé or paste text instead.
        - STOP CONDITIONS. Do not submit, leave the tab open exactly where you stopped, and return status "needs_you" with the reason and every \
        question you could not answer in `unknown_questions` (the question text as shown), when any of these happens: a required question is \
        not covered by the answers below; the site asks you to create an account, sign in, or complete two-factor authentication; a CAPTCHA; \
        an assessment, test, video or coding exercise; a cover letter or other document you do not have; a request to pay; the posting is \
        closed or a different job opens; an error you cannot resolve; or anything else unexpected.
        - Return status "failed" with the reason only when the application page cannot be reached at all.
        - Before pressing Submit, re-read the whole form: every required field is filled, the PDF is attached, and nothing contradicts the \
        answers below. Press Submit once. Then read the confirmation (confirmation number, "application received" message or the email \
        notice) into `confirmation` and return status "submitted". If you cannot tell whether it went through, return "needs_you" and say \
        so; never submit twice.
        - Do nothing else in the browser: no other applications, no profile edits, no messages, no saving jobs.

        APPROVED ANSWERS (questions from this posting, approved by me):
        \(bullets(answers, empty: "(none beyond the standard facts)"))

        STANDARD FACTS (count as approved answers for the usual fields):
        \(facts.joined(separator: "\n"))

        SAVED ANSWERS (reuse when the form asks the same question):
        \(bullets(saved))
        """
    }

    /// One headless `claude -p` call with a JSON schema; `cwd` is where Claude may read files.
    nonisolated static func check<T: Decodable>(_ type: T.Type, prompt: String, schema: String, chrome: Bool, tools: String, cwd: String?) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-hunt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schemaFile = dir.appendingPathComponent("schema-\(UUID().uuidString.prefix(8)).json")
        try schema.write(to: schemaFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: schemaFile) }
        let cmd = "cd '\(LatexBuild.quoted(cwd ?? dir.path))' && claude -p \(chrome ? "--chrome " : "")--output-format json "
            + "--json-schema \"$(cat '\(LatexBuild.quoted(schemaFile.path))')\" --allowedTools \(tools) 2>/dev/null"
        let out = await ClaudeCode.shell(cmd, stdin: prompt)
        guard let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else {
            throw Learning.Failure.message("Claude Code didn't respond. Check it works in Terminal.")
        }
        if obj["is_error"] as? Bool == true {
            throw Learning.Failure.message((obj["result"] as? String) ?? "Claude Code returned an error.")
        }
        let structured = obj["structured_output"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            ?? (obj["result"] as? String).map { Data($0.utf8) }
        guard let structured, let value = try? JSONDecoder().decode(T.self, from: structured) else {
            throw Learning.Failure.message("Couldn't read Claude's result.")
        }
        return value
    }
}
#endif
