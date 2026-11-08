#if os(macOS)
import AppKit
import Foundation
import SwiftData

/// The hunt as tools for a Claude Code session (`prepboard-hunt`), so a Remote Control session started from PrepBoard can be driven
/// from the Claude app on a phone: "what's my Mac doing?", "apply to the Figma role", "answer the zip code question with 07302".
/// Every application still goes out through PrepBoard's own submit run, with its limits, spacing and checks.
extension JobHunt: HuntToolProvider {
    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> MCPTool {
        MCPTool(name: name, description: description, inputSchema: ["type": "object", "properties": properties, "required": required])
    }
    private static let idProp: [String: Any] = ["id": ["type": "string", "description": "The role's id from list_roles, or its company name"]]

    static var huntTools: [MCPTool] {
        [
            tool("status", "What PrepBoard's hunt is doing now, where every role is (counts per stage), today's résumés and applications against the daily limits, and whether Keep applying is on."),
            tool("list_roles", "Roles PrepBoard found, one per line: id | company | title | status | match | what happens next. Filter by stage.",
                 ["stage": ["type": "string", "enum": ["needs_you", "ready", "applying", "applied", "failed", "by_hand", "preparing", "all"],
                            "description": "Default needs_you plus ready"],
                  "limit": ["type": "integer", "description": "Default 20"]]),
            tool("role", "Everything about one role: posting link, status and reason, résumé quality (keywords, ATS), the questions still waiting for an answer, and any suggested answers.", idProp, required: ["id"]),
            tool("answer", "Answer one waiting form question for a role, as the user. Saved to the Answer Bank for the next form that asks the same thing (unless it is about this company only).",
                 idProp.merging(["question": ["type": "string", "description": "The question text as role shows it"],
                                 "answer": ["type": "string"]]) { a, _ in a }, required: ["id", "question", "answer"]),
            tool("approve_suggestions", "Accept every answer Claude suggested for a role's waiting questions.", idProp, required: ["id"]),
            tool("apply", "Queue the role's application. PrepBoard's Mac submits it within a few minutes, continuing a stopped form where it left off. Refused while a required answer is missing.", idProp, required: ["id"]),
            tool("rewrite_resume", "Write the role's résumé again (Keep applying picks it up between searches).", idProp, required: ["id"]),
            tool("skip", "Skip a role.", idProp, required: ["id"]),
            tool("find_roles", "Start a search for new roles now (about 10 minutes; check status)."),
            tool("keep_applying", "Turn Keep applying on or off.", ["on": ["type": "boolean"]], required: ["on"]),
        ]
    }

    func callHuntTool(_ name: String, _ args: [String: Any]) async throws -> String {
        guard let container else { throw BrowserError.message("The hunt isn't attached yet.") }
        let context = container.mainContext
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        func lead() throws -> Lead {
            let key = (args["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if let l = leads.first(where: { $0.id == key }) { return l }
            let matches = leads.filter { $0.company.localizedCaseInsensitiveContains(key) && $0.status != .skipped }
            if matches.count == 1, let l = matches.first { return l }
            if matches.count > 1 { throw BrowserError.message("Several roles match \"\(key)\": " + matches.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")) }
            throw BrowserError.message("No role matches \"\(key)\". Use list_roles for ids.")
        }
        defer { try? context.save() }
        switch name {
        case "status":
            let s = HuntSettings.current(context)
            func n(_ f: (Lead) -> Bool) -> Int { leads.filter(f).count }
            return """
            \(statusLine)
            Keep applying: \(HuntPrefs.keepApplying ? "on" : "off")\(isPaused ? " (paused until \(pausedUntil.map { Self.clockText($0) } ?? ""))" : "")
            Today: \(tailoredToday)/\(s.dailyTailorLimit) résumés, \(submittedToday)/\(s.dailySubmitLimit) applications
            Preparing \(n { [.new, .tailoring].contains($0.status) }) · Ready \(n { $0.status == .ready && !$0.submitRequested }) · Applying \(n { $0.status == .submitting || $0.status == .ready && $0.submitRequested }) · Applied \(n { $0.status == .submitted }) · Needs you \(n { [.needsYou, .failed].contains($0.status) }) · By hand \(n(\.isByHand))
            \(s.answerBank.setupIssues.isEmpty ? "" : "Setup to finish: " + s.answerBank.setupIssues.joined(separator: " "))
            """
        case "list_roles":
            let stage = args["stage"] as? String ?? ""
            let limit = max(1, min(100, args["limit"] as? Int ?? 20))
            let pick: (Lead) -> Bool = switch stage {
            case "needs_you": { [.needsYou, .failed].contains($0.status) }
            case "ready": { $0.status == .ready && !$0.submitRequested }
            case "applying": { $0.status == .submitting || $0.status == .ready && $0.submitRequested }
            case "applied": { $0.status == .submitted }
            case "failed": { $0.status == .failed }
            case "by_hand": { $0.isByHand }
            case "preparing": { [.new, .tailoring].contains($0.status) }
            case "all": { _ in true }
            default: { [.needsYou, .failed, .ready].contains($0.status) }
            }
            let rows = leads.filter(pick).sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)
            return rows.isEmpty ? "No roles in that stage." : rows.map {
                "\($0.id) | \($0.company) | \($0.title) | \($0.status.rawValue)\($0.submitRequested ? " (queued)" : "") | match \($0.score) | \($0.displayReason.prefix(140))"
            }.joined(separator: "\n")
        case "role":
            let l = try lead()
            let waiting = l.answers.filter { ["needs_you", "suggested"].contains($0.kind) }
            return """
            \(l.company) · \(l.title) · \(l.location)
            Id: \(l.id) · Status: \(l.status.rawValue)\(l.submitRequested ? " (queued to apply)" : "") · Match \(l.score)
            Posting: \(l.link)
            Next: \(l.displayReason)
            \(l.flagged.isEmpty ? "" : "Flagged: " + l.flagged.replacingOccurrences(of: "\n", with: "; "))
            Résumé: \(l.variantName.isEmpty ? "not written yet" : l.variantName)\(l.keywordScore.map { " · keywords \($0)%" } ?? "")\(l.atsIssues.map { $0.isEmpty ? " · ATS ready" : " · ATS: " + $0.joined(separator: " ") } ?? "")
            Waiting questions:\(waiting.isEmpty ? " none" : "\n" + waiting.map { "- \($0.question)\($0.required ? " (required)" : "")\($0.kind == "suggested" ? " → suggested: \($0.answer)" : "")" }.joined(separator: "\n"))
            """
        case "answer":
            let l = try lead()
            let q = args["question"] as? String ?? "", text = (args["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw BrowserError.message("The answer is empty.") }
            var all = l.answers
            guard let i = all.firstIndex(where: { AnswerBank.normalized($0.question) == AnswerBank.normalized(q) })
                    ?? all.firstIndex(where: { AnswerBank.normalized($0.question).contains(AnswerBank.normalized(q)) }) else {
                throw BrowserError.message("That role has no question like \"\(q)\". Use role to see them.")
            }
            all[i].answer = text; all[i].kind = "yours"; l.answers = all; l.updatedAt = .now
            let settings = HuntSettings.current(context)
            settings.answerBank = settings.answerBank.remembering(l.answers, company: l.company); settings.updatedAt = .now
            Lead.applyBank(settings.answerBank, to: leads)
            if l.status == .needsYou, l.canSubmit, l.onlyQuestionsFlagged { l.status = .ready; l.flagged = "" }
            return "Saved. \(l.canSubmit ? "Nothing else is waiting: use apply to send it." : "Still waiting: " + l.answers.filter { $0.kind == "needs_you" }.map(\.question).joined(separator: "; "))"
        case "approve_suggestions":
            let l = try lead()
            let n = l.suggestedCount
            l.approveSuggestions()
            if l.status == .needsYou, l.canSubmit { l.status = .ready; l.flagged = "" }
            return "Approved \(n). " + (l.canSubmit ? "Ready to apply." : "Questions still waiting.")
        case "apply":
            let l = try lead()
            guard [.ready, .needsYou].contains(l.status) else { throw BrowserError.message("\(l.company) is \(l.status.rawValue); only ready or needs-you roles can be applied to.") }
            guard l.canSubmit else {
                throw BrowserError.message("Missing answers first: " + l.answers.filter { ["needs_you", "suggested"].contains($0.kind) }.map(\.question).joined(separator: "; "))
            }
            if l.status == .needsYou { l.status = .ready; l.flagged = "" }
            l.submitRequested = true; l.updatedAt = .now
            try? context.save()
            processSubmitQueue()
            return "Queued \(l.company). PrepBoard submits it within a few minutes (one at a time, 2 minutes apart, within today's limit). Check with status or role."
        case "rewrite_resume":
            let l = try lead()
            guard ![.submitted, .submitting, .tailoring].contains(l.status) else { throw BrowserError.message("\(l.company) is \(l.status.rawValue).") }
            l.status = .new; l.submitRequested = false; l.flagged = ""; l.reason = "Writing the résumé again"; l.updatedAt = .now
            return "\(l.company) will get a new résumé on the next tick."
        case "skip":
            let l = try lead()
            skip(l)
            return "Skipped \(l.company)."
        case "find_roles":
            guard phase == .idle else { return "Busy: \(statusLine). Try again when it finishes." }
            Task { await run() }
            return "Searching now. It takes about 10 minutes; check status."
        case "keep_applying":
            let on = args["on"] as? Bool ?? true
            UserDefaults.standard.set(on, forKey: HuntPrefs.keepApplyingKey)
            keepApplyingChanged()
            return "Keep applying is \(on ? "on" : "off")."
        default:
            throw BrowserError.message("Unknown tool \(name)")
        }
    }

    static func clockText(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// Opens Terminal with a Claude Code session that has the hunt tools, started with Remote Control so it shows up in the Claude
    /// app on the phone. Returns an error to show, or nil.
    func startRemoteSession() -> String? {
        guard let browser, let config = browser.huntConfigFile() else { return "PrepBoard's tool server isn't running yet. Try again in a moment." }
        let prompt = "You are my job-hunt assistant on my Mac. Use the prepboard-hunt tools for everything about applications: status, list_roles, role, answer, approve_suggestions, apply, rewrite_resume, skip, find_roles, keep_applying. Keep replies short; I'm on my phone. Never guess an answer to a form question for me: ask me."
        let cmd = "cd ~ && claude --remote-control 'PrepBoard' --name 'PrepBoard hunt' --mcp-config '\(config.path)' --allowedTools 'mcp__\(BrowserServer.huntName)' --append-system-prompt '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))'"
        // A .command file opens in Terminal by itself: no Apple Events permission needed.
        let file = config.deletingLastPathComponent().appendingPathComponent("PrepBoard Remote.command")
        try? FileManager.default.removeItem(at: file)
        let body = "#!/bin/zsh -l\n# Started by PrepBoard: a Claude Code session with the hunt tools, reachable from the Claude app (Remote Control).\n" + cmd + "\n"
        guard FileManager.default.createFile(atPath: file.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
            return "Couldn't write the session script."
        }
        return NSWorkspace.shared.open(file) ? nil : "Couldn't open Terminal."
    }
}
#endif
