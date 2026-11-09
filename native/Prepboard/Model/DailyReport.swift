#if os(macOS)
import Foundation
import SwiftData
import WebKit

/// The end-of-day summary of what Keep applying did: every application sent that day (time, role, résumé, the account it went in
/// under, the confirmation), plus what is waiting. Saved as a PDF in Documents and emailed to me through the Gmail connector.
@MainActor
enum DailyReport {
    struct Entry: Equatable {
        var time: Date, company: String, title: String, location: String, link: String
        var resume: String, account: String, confirmation: String
    }

    static let enabledKey = "hunt.dailyReport", lastDayKey = "hunt.dailyReport.lastDay"
    /// On unless turned off in Hunt settings.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Sent once a day, at or after this hour.
    static let hour = 21

    /// Due now: enabled, past the hour, and not sent yet today.
    static func isDue(now: Date = .now) -> Bool {
        enabled && Calendar.current.component(.hour, from: now) >= hour
            && UserDefaults.standard.string(forKey: lastDayKey) != DateCoding.dayString(now)
    }

    static func entries(on day: Date, context: ModelContext) -> [Entry] {
        let cal = Calendar.current
        let all: [Role] = (try? context.fetch(FetchDescriptor<Role>())) ?? []
        let roles = all.filter { (r: Role) -> Bool in
            guard r.source == "hunt", let at = r.appliedAt else { return false }
            return cal.isDate(at, inSameDayAs: day)
        }
        let leads: [Lead] = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        var out: [Entry] = []
        for role in roles {
            let lead: Lead? = leads.first { (l: Lead) -> Bool in l.roleId == role.id }
            let confirmation: String = lead?.appliedDetails.confirmation ?? ""
            let account: String = lead?.appliedDetails.account ?? ""
            out.append(Entry(time: role.appliedAt ?? day, company: role.company, title: role.title, location: role.location,
                             link: role.link, resume: role.resumeVariant, account: account.isEmpty ? "Not recorded" : account,
                             confirmation: confirmation))
        }
        return out.sorted { (a: Entry, b: Entry) -> Bool in a.time < b.time }
    }

    /// One line per thing still waiting, for the end of the report.
    static func waiting(context: ModelContext) -> [String] {
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        let needs = leads.filter { $0.status == .needsYou }.count, ready = leads.filter { $0.status == .ready }.count
        let byHand = leads.filter(\.isByHand).count
        return [needs > 0 ? "\(needs) need your input" : nil, ready > 0 ? "\(ready) ready to send" : nil,
                byHand > 0 ? "\(byHand) to apply by hand" : nil].compactMap { $0 }
    }

    static func subject(_ entries: [Entry], day: Date) -> String {
        "PrepBoard: \(entries.count) application\(entries.count == 1 ? "" : "s") on \(day.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Plain text, for the email body.
    static func text(_ entries: [Entry], waiting: [String], day: Date) -> String {
        var lines = ["\(entries.count) application\(entries.count == 1 ? "" : "s") sent on \(day.formatted(date: .complete, time: .omitted)).", ""]
        for (i, e) in entries.enumerated() {
            lines.append("\(i + 1). \(e.company): \(e.title)\(e.location.isEmpty ? "" : " (\(e.location))")")
            lines.append("   Sent \(e.time.formatted(date: .omitted, time: .shortened)) with \(e.resume.isEmpty ? "the default résumé" : e.resume)")
            lines.append("   Account: \(e.account)")
            if !e.confirmation.isEmpty { lines.append("   Confirmation: \(e.confirmation.replacingOccurrences(of: "\n", with: " "))") }
            if !e.link.isEmpty { lines.append("   \(e.link)") }
            lines.append("")
        }
        if entries.isEmpty { lines.append("Nothing went out today."); lines.append("") }
        if !waiting.isEmpty { lines.append("Still waiting: " + waiting.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }

    static func html(_ entries: [Entry], waiting: [String], day: Date) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let rows = entries.map { e in
            """
            <tr><td class=t>\(e.time.formatted(date: .omitted, time: .shortened))</td>
            <td><b>\(esc(e.company))</b><br>\(esc(e.title))\(e.location.isEmpty ? "" : "<br><span class=m>\(esc(e.location))</span>")</td>
            <td>\(esc(e.resume))</td><td>\(esc(e.account))</td>
            <td>\(esc(e.confirmation))\(e.link.isEmpty ? "" : "<br><a href=\"\(esc(e.link))\">Posting</a>")</td></tr>
            """
        }.joined()
        return """
        <html><head><meta charset=utf-8><style>
        body{font:12px -apple-system,Helvetica,sans-serif;color:#15171C;margin:36px}
        h1{font-size:22px;margin:0 0 4px} .m{color:#6A7080} table{border-collapse:collapse;width:100%;margin-top:18px}
        th{text-align:left;font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:#6A7080;border-bottom:1px solid #D8DBE1;padding:6px}
        td{vertical-align:top;border-bottom:1px solid #E8EAEE;padding:8px 6px} .t{white-space:nowrap;color:#474D5A} a{color:#1E4FE0}
        .w{margin-top:18px;padding:10px 12px;background:#FDEBDD;border-radius:8px;color:#B4470F}
        </style></head><body>
        <h1>\(entries.count) application\(entries.count == 1 ? "" : "s") sent</h1>
        <div class=m>\(day.formatted(date: .complete, time: .omitted)) · PrepBoard Keep applying</div>
        \(entries.isEmpty ? "<p>Nothing went out today.</p>" : "<table><tr><th>Time</th><th>Role</th><th>Résumé</th><th>Account</th><th>Confirmation</th></tr>\(rows)</table>")
        \(waiting.isEmpty ? "" : "<div class=w>Still waiting: \(esc(waiting.joined(separator: ", "))).</div>")
        </body></html>
        """
    }

    /// ~/Documents/Career/Applications/Daily reports, next to the résumés.
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Career/Applications/Daily reports", isDirectory: true)
    }

    /// Renders the HTML to a PDF in an off-screen web view.
    static func pdf(_ html: String) async throws -> Data {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
        let loader = Loader()
        view.navigationDelegate = loader
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loader.done = { c.resume(with: $0) }
            view.loadHTMLString(html, baseURL: nil)
        }
        return try await view.pdf(configuration: WKPDFConfiguration())
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var done: ((Result<Void, Error>) -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?(.success(())); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?(.failure(error)); done = nil }
    }

    /// The headless run that sends the email: only Gmail's send tool, only to my own address, the text exactly as given.
    static func emailPrompt(to address: String, subject: String, body: String) -> String {
        """
        Send one email with the Gmail send tool and do nothing else: no other tools, no other recipients, no drafts, no edits to the text.
        To: \(address)
        Subject: \(subject)
        Body (plain text, exactly as below):
        ---
        \(body)
        ---
        Reply with {"sent": true, "note": ""} once it is sent, or {"sent": false, "note": "<why>"} if you could not send it.
        """
    }

    static let emailSchema = #"{"type":"object","required":["sent","note"],"properties":{"sent":{"type":"boolean"},"note":{"type":"string"}}}"#
    struct EmailResult: Decodable { let sent: Bool; let note: String }
}
#endif
