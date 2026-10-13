import Foundation
import SwiftData

/// One job the sync found in Gmail or LinkedIn (matches `JobSync.schema`).
struct FoundJob: Codable {
    struct Event: Codable { var date: String; var summary: String }
    var match_id: String
    var company, title, location, link: String
    var stage: String
    var recruiter, recruiter_email: String
    var source: String
    var applied_at, interview_at, interview_note: String
    var events: [Event]
}

struct FoundJobs: Codable {
    var jobs: [FoundJob]
    var notes: String
}

/// Merges what the sync found into the user's roles. Works on every platform; only the Mac runs the sync itself.
enum JobMerge {
    struct Result {
        var added = 0, updated = 0
        var newInterviews: [Role] = []
        var summary: String {
            if added == 0 && updated == 0 { return "Nothing new" }
            return [added > 0 ? "\(added) new" : nil, updated > 0 ? "\(updated) updated" : nil,
                    newInterviews.isEmpty ? nil : "\(newInterviews.count) interview\(newInterviews.count == 1 ? "" : "s") scheduled"]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func find(_ job: FoundJob, in roles: [Role]) -> Role? {
        if !job.match_id.isEmpty, let r = roles.first(where: { $0.id == job.match_id }) { return r }
        let company = key(job.company), title = key(job.title)
        guard !company.isEmpty else { return nil }
        return roles.first { key($0.company) == company && key($0.title) == title }
            ?? (title.isEmpty ? roles.first { key($0.company) == company } : nil)
    }

    /// Stages only move forward, except that a rejection closes anything short of an offer.
    static func nextStage(_ current: Stage, _ found: Stage) -> Stage {
        if found == .closed { return current == .offer ? current : .closed }
        if current == .closed { return current }
        return found.index > current.index ? found : current
    }

    static func activityLines(_ job: FoundJob) -> [String] {
        let src = job.source == "linkedin" ? "LinkedIn" : "Gmail"
        return job.events.map { "- \(String($0.date.prefix(10))) · \(src) · \($0.summary.trimmingCharacters(in: .whitespacesAndNewlines))" }
    }

    static func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return DateCoding.date(s) ?? DateCoding.date(String(s.prefix(10)) + "T12:00:00Z")
    }

    @MainActor
    @discardableResult
    static func apply(_ found: FoundJobs, to context: ModelContext) throws -> Result {
        var result = Result()
        var roles = try context.fetch(FetchDescriptor<Role>())
        for job in found.jobs where !job.company.trimmingCharacters(in: .whitespaces).isEmpty {
            let stage = Stage(rawValue: job.stage) ?? .applied
            let interview = job.interview_at.isEmpty ? nil : DateCoding.date(job.interview_at)
            let applied = date(job.applied_at)
            guard let role = find(job, in: roles) else {
                let r = Role(company: job.company, title: job.title.isEmpty ? "Role" : job.title, location: job.location, link: job.link,
                             stage: stage, interviewAt: interview, interviewNote: job.interview_note)
                r.recruiter = job.recruiter; r.recruiterEmail = job.recruiter_email; r.source = job.source
                r.appliedAt = applied; r.activity = activityLines(job).joined(separator: "\n")
                context.insert(r)
                roles.append(r)
                result.added += 1
                if let interview, interview > .now { result.newInterviews.append(r) }
                continue
            }
            var changed = false
            func fill<V: Equatable>(_ kp: ReferenceWritableKeyPath<Role, V>, _ value: V, when: Bool) {
                if when, role[keyPath: kp] != value { role[keyPath: kp] = value; changed = true }
            }
            fill(\.stageRaw, nextStage(role.stage, stage).rawValue, when: true)
            fill(\.recruiter, job.recruiter, when: role.recruiter.isEmpty && !job.recruiter.isEmpty)
            fill(\.recruiterEmail, job.recruiter_email, when: role.recruiterEmail.isEmpty && !job.recruiter_email.isEmpty)
            fill(\.location, job.location, when: role.location.isEmpty && !job.location.isEmpty)
            fill(\.link, job.link, when: role.link.isEmpty && !job.link.isEmpty)
            fill(\.source, job.source, when: role.source.isEmpty && !job.source.isEmpty)
            fill(\.appliedAt, applied, when: role.appliedAt == nil && applied != nil)
            fill(\.interviewNote, job.interview_note, when: role.interviewNote.isEmpty && !job.interview_note.isEmpty)
            if let interview, role.interviewAt.map({ abs($0.timeIntervalSince(interview)) > 60 }) ?? true {
                role.interviewAt = interview
                changed = true
                if interview > .now { result.newInterviews.append(role) }
            }
            let existing = Set(role.activity.split(separator: "\n").map(String.init))
            let fresh = activityLines(job).filter { !existing.contains($0) }
            if !fresh.isEmpty {
                role.activity = (role.activity.isEmpty ? fresh : [role.activity] + fresh).joined(separator: "\n")
                changed = true
            }
            if changed { result.updated += 1 }
        }
        try context.save()
        return result
    }
}

#if os(macOS)
import Observation
import UserNotifications

/// Checks Gmail (the Gmail connector) and LinkedIn (PrepBoard's built-in browser) with the user's local Claude Code
/// and keeps Roles up to date: new applications, recruiters, stage changes and scheduled interviews.
/// Read-only: it never sends, replies, applies or changes anything on those sites.
@MainActor
@Observable
final class JobSync {
    static let interval: TimeInterval = 3 * 3600

    var auto: Bool = UserDefaults.standard.object(forKey: "jobsync.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "jobsync.auto") }
    }
    private(set) var lastRun: Date? = UserDefaults.standard.object(forKey: "jobsync.lastRun") as? Date {
        didSet { UserDefaults.standard.set(lastRun, forKey: "jobsync.lastRun") }
    }
    private(set) var lastSummary: String? = UserDefaults.standard.string(forKey: "jobsync.summary") {
        didSet { UserDefaults.standard.set(lastSummary, forKey: "jobsync.summary") }
    }
    private(set) var isRunning = false
    var error: String?
    /// When `run()` last started, successful or not; the throttle uses it so a stop never moves `lastRun` (the Gmail window's anchor).
    private var lastAttempt: Date?

    private var container: ModelContainer?
    private weak var claude: ClaudeCode?
    private weak var browser: BrowserServer?
    private weak var huntBrowser: HuntBrowser?
    private var timer: Timer?

    /// Starts the schedule: a sync whenever one is due, checked every 15 minutes while the app is open. `browser` is the built-in
    /// browser's MCP server; `huntBrowser` the web view itself, which the LinkedIn sign-in check drives directly.
    func attach(container: ModelContainer, claude: ClaudeCode, browser: BrowserServer, huntBrowser: HuntBrowser) {
        self.container = container
        self.claude = claude
        self.browser = browser
        self.huntBrowser = huntBrowser
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        runIfDue()
    }

    func runIfDue() {
        guard auto, !isRunning, let claude, claude.isReady, !claude.busy else { return }
        if let last = lastAttempt ?? lastRun, Date.now.timeIntervalSince(last) < Self.interval { return }
        Task { await run() }
    }

    func run() async {
        guard !isRunning, let container, let claude else { return }
        guard claude.isReady else { error = "Connect Claude Code in Profile to sync Gmail and LinkedIn."; return }
        guard !claude.busy else { error = "Another Claude run is using the browser; wait for it to finish."; return }
        guard let browser, browser.isRunning else { error = "The built-in browser couldn't start"; return }
        isRunning = true
        lastAttempt = .now
        error = nil
        claude.busy = true
        defer { isRunning = false; claude.busy = false }
        browser.reset()
        // The browser signs itself in from the Keychain when LinkedIn's session is gone; a stop here waits for the next due time
        // and leaves `lastRun` alone, so the next sync still reads Gmail back to the last one that finished.
        if let huntBrowser, let stop = LinkedInSignIn.stopMessage(await LinkedInSignIn.ensure(huntBrowser)) {
            error = stop
            lastSummary = LinkedInSignIn.stoppedSummary
            return
        }

        let context = container.mainContext
        let roles = (try? context.fetch(FetchDescriptor<Role>())) ?? []
        let since = lastRun.map { $0.addingTimeInterval(-2 * 86400) } ?? Calendar.current.date(byAdding: .day, value: -60, to: .now)!
        do {
            // Read-only browser tools, and not strict: strict mode would drop the Gmail and Calendar connectors.
            let found = try await Self.check(prompt: Self.prompt(since: since, roles: roles),
                                             browserFlags: browser.claudeFlags(extraTools: Self.connectorTools, readOnly: true, strict: false))
            let result = try JobMerge.apply(found, to: context)
            lastRun = .now
            lastSummary = result.summary
            for role in result.newInterviews { notify(role) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func notify(_ role: Role) {
        let content = UNMutableNotificationContent()
        content.title = "Interview scheduled: \(role.company)"
        content.body = [role.title, role.interviewAt?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
            + "\nOpen PrepBoard to generate a prep plan."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "interview-\(role.id)", content: content, trigger: nil))
    }

    /// The Gmail and Calendar connectors; the built-in browser's tools come from `BrowserServer.allowedTools`.
    static let connectorTools = "mcp__claude_ai_Gmail mcp__claude_ai_Google_Calendar"

    static let schema = #"""
    {"type":"object","required":["jobs","notes"],"properties":{
      "notes":{"type":"string"},
      "jobs":{"type":"array","items":{"type":"object",
        "required":["match_id","company","title","location","link","stage","recruiter","recruiter_email","source","applied_at","interview_at","interview_note","events"],
        "properties":{
          "match_id":{"type":"string"},"company":{"type":"string"},"title":{"type":"string"},"location":{"type":"string"},"link":{"type":"string"},
          "stage":{"type":"string","enum":["Saved","Applied","Recruiter","Technical","Onsite","Offer","Closed"]},
          "recruiter":{"type":"string"},"recruiter_email":{"type":"string"},
          "source":{"type":"string","enum":["gmail","linkedin"]},
          "applied_at":{"type":"string"},"interview_at":{"type":"string"},"interview_note":{"type":"string"},
          "events":{"type":"array","items":{"type":"object","required":["date","summary"],
            "properties":{"date":{"type":"string"},"summary":{"type":"string"}}}}}}}}}
    """#

    static func prompt(since: Date, roles: [Role]) -> String {
        let known = roles.map { "- id=\($0.id) | \($0.company) | \($0.title) | \($0.stage.rawValue)" }.joined(separator: "\n")
        let day = DateCoding.dayString(since)
        return """
        You keep my job-search tracker up to date. Check my Gmail and LinkedIn for job-search activity since \
        \(DateCoding.string(since)) (now: \(DateCoding.string(.now)), my time zone: \(TimeZone.current.identifier)).

        READ ONLY: never send, reply, apply, archive, label, delete, accept invites or change anything.
        - Gmail: use the Gmail tools if available, otherwise skip Gmail and say so in `notes`. Search e.g. \
        `after:\(day.replacingOccurrences(of: "-", with: "/")) (application OR applied OR interview OR recruiter OR "thank you for applying" OR offer OR "next steps" OR unfortunately)` \
        and read the relevant emails. This includes LinkedIn's emails ("Your application was sent to…", InMail and message notifications).
        - LinkedIn in PrepBoard's built-in browser, where I am already signed in. Use the PrepBoard browser tools (mcp__prepboard__…): \
        navigate to a URL; read_page (interactive_only false to read a page) returns elements with refs like r12; click(ref) acts on \
        them; after a click that changes the page call wait then read_page again; page_text for the full page text; screenshot when a \
        page is unclear. There are no tabs: one page at a time, use back() to return to a list. Read \
        https://www.linkedin.com/my-items/saved-jobs/?cardType=APPLIED (applied jobs) and \
        https://www.linkedin.com/messaging/ (recruiter messages). Only read and scroll; never type, and don't press buttons that act.
        - Google Calendar tools, if available, for exact interview times.
        If a source isn't signed in or its tools aren't available, skip it and say so in `notes`.

        Return one entry per job (merge everything about the same job). Ignore newsletters, job alerts/recommendations \
        and jobs I neither applied to nor heard from a recruiter about.
        - match_id: the id of the matching role from my tracker below, or "" if it's new.
        - stage: Applied (applied/confirmation), Recruiter (recruiter screen or outreach), Technical (technical/phone \
        interview), Onsite (final/onsite loop), Offer, Closed (rejected or withdrawn).
        - interview_at: ISO 8601 with time-zone offset, only if a specific interview time is scheduled, else "". \
        interview_note: the format, e.g. "45 min technical with the team, CoderPad", or "".
        - applied_at: yyyy-MM-dd or "". recruiter / recruiter_email: the person's name and email, or "".
        - link: the job posting URL if seen, else "". source: gmail or linkedin (where you found it).
        - events: what happened, each {date: yyyy-MM-dd, summary: under 12 words}, e.g. "Recruiter asked for availability".
        - notes: one or two sentences on what you checked.

        My tracker:
        \(known.isEmpty ? "(empty)" : known)
        """
    }

    /// One headless `claude -p` call; `browserFlags` come from `BrowserServer.claudeFlags` and carry the --allowedTools list.
    /// `--tools ""` drops every built-in tool, so the user's global Bash and web allowlist never reaches this run.
    nonisolated static func check(prompt: String, browserFlags: String) async throws -> FoundJobs {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-jobsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try schema.write(to: dir.appendingPathComponent("schema.json"), atomically: true, encoding: .utf8)
        let cmd = "cd '\(dir.path)' && claude -p \(browserFlags) --output-format json --json-schema \"$(cat schema.json)\" --tools \"\" 2>/dev/null"
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
        guard let structured, let found = try? JSONDecoder().decode(FoundJobs.self, from: structured) else {
            throw Learning.Failure.message("Couldn't read the sync result.")
        }
        return found
    }
}
#endif
