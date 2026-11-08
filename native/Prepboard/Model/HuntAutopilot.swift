import Foundation
import PDFKit

/// What "Keep applying" does on its own when something stops: decides whether a stop is one PrepBoard can recover from (a Claude
/// usage limit, a timeout, a missing file) and measures how well a tailored résumé fills its page and mirrors the posting's terms.
/// Pure functions; `JobHunt` acts on them.
enum HuntAutopilot {
    /// What to do about a failure message.
    enum Recovery: Equatable {
        case waitUntil(Date)        // Claude's usage limit: pause everything until it resets
        case retry                  // a passing problem: try the same step again on the next tick
        case retailor               // the résumé is missing or unreadable: write it again
        case none                   // needs a person (or is a real "no")
    }

    /// Each lead gets this many automatic retries before it is left for the user.
    static let maxAttempts = 3

    /// Classifies a reason / error text. `now` and `zone` anchor the reset time of a usage limit.
    static func classify(_ message: String, now: Date = .now, zone: TimeZone = .current) -> Recovery {
        let m = message.lowercased()
        if m.contains("session limit") || m.contains("usage limit") || m.contains("hit your limit") || m.contains("rate limit")
            || m.contains("limit reached") && m.contains("claude") {
            return .waitUntil(resetTime(message, now: now, zone: zone) ?? now.addingTimeInterval(3600))
        }
        let retailor = ["no résumé variants found", "no resume variants found", "the pdf is missing", "while the résumé was being written",
                        "couldn't read", "pdf build failed", "honesty check could not run"]
        if retailor.contains(where: m.contains) { return .retailor }
        let passing = ["timed out", "timeout", "offline", "failed to connect", "could not load", "couldn't load", "network",
                       "connection", "overloaded", "529", "500 internal", "returned no result", "incomplete result",
                       "ended without a result", "prepboard quit", "econnreset", "socket",
                       "browser couldn't start", "chrome isn't connected", "no_chrome"]
        if passing.contains(where: m.contains) { return .retry }
        return .none
    }

    /// "resets 12:30pm (America/New_York)" / "resets 7am" / "resets at 3:15 PM" → the next such time after `now`.
    static func resetTime(_ message: String, now: Date, zone: TimeZone) -> Date? {
        let pattern = #"resets?(?: at)? (\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)(?:\s*\(([^)]+)\))?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: message).map { String(message[$0]) } }
        guard var hour = group(1).flatMap(Int.init), hour >= 1, hour <= 12 else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        let pm = group(3)?.lowercased().hasPrefix("p") == true
        if hour == 12 { hour = pm ? 12 : 0 } else if pm { hour += 12 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = group(4).flatMap(TimeZone.init(identifier:)) ?? zone
        guard let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        // A minute of slack so the retry lands after the reset, not on it.
        let target = today > now ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
        return target.addingTimeInterval(60)
    }

    // MARK: résumé fit

    /// How a one-page résumé sits on its page.
    struct PageFit: Equatable {
        var pages: Int
        /// Empty space under the last line of text on page 1, as a share of the page height (negative: text runs off the page).
        var bottomGap: Double
        /// Lines on page 1 that are the short tail of a wrapped bullet (widows that waste a line).
        var shortLines: Int

        var overflows: Bool { pages > 1 || bottomGap < 0.01 }
        /// More than ~0.45 in of letter paper left blank.
        var underfilled: Bool { pages == 1 && bottomGap > 0.04 }
        var isGood: Bool { !overflows && !underfilled }

        var summary: String {
            if pages > 1 { return "It runs onto \(pages) pages." }
            if bottomGap < 0.01 { return "Text runs into or past the bottom margin." }
            let inches = bottomGap * 11
            return String(format: "%.1f in of the page is empty under the last line", inches)
                + (shortLines > 0 ? " and \(shortLines) line\(shortLines == 1 ? "" : "s") are the short tail of a wrapped bullet." : ".")
        }
    }

    /// Measures the PDF at `path`; nil when it cannot be read.
    static func measure(pdfAt path: String) -> PageFit? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.height > 0 else { return nil }
        // Select well past the page edges, so text set below the bottom of the page still counts.
        let all = box.insetBy(dx: -box.width, dy: -box.height)
        let lines = (page.selection(for: all)?.selectionsByLine() ?? [])
            .map { (text: ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), bounds: $0.bounds(for: page)) }
            .filter { !$0.text.isEmpty && $0.bounds.height > 0 }
        guard let lowest = lines.map(\.bounds.minY).min() else { return PageFit(pages: doc.pageCount, bottomGap: 1, shortLines: 0) }
        // Lines top to bottom, so the header block comes first for shortLineCount.
        let text = lines.sorted { $0.bounds.maxY > $1.bounds.maxY }.map(\.text).joined(separator: "\n")
        return PageFit(pages: doc.pageCount, bottomGap: Double((lowest - box.minY) / box.height), shortLines: shortLineCount(text))
    }

    /// Short wrapped tails of body text (under 30 characters, continuing a sentence), skipping the header block and section titles (single words in small caps
    /// such as "Experience" are headings, not widows).
    static func shortLineCount(_ text: String) -> Int {
        let headings: Set<String> = ["summary", "experience", "projects", "education", "technical skills", "skills", "publications",
                                     "awards", "leadership", "certifications", "work experience", "professional experience"]
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst(3).filter { line in
            // A wrapped bullet's tail that fills under a third of a line (about 30 of ~110 characters).
            guard line.count < 30, !headings.contains(line.lowercased()) else { return false }
            // Dates, locations and one-word skill labels sit on short lines by design.
            if line.range(of: #"\d{4}|present|remote|, [A-Z]{2}\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
            return line.first?.isLowercase == true || line.last == "." || line.last == ","
        }.count
    }

    /// The posting's terms (as the posting spells them) that the résumé text does not contain. Matching ignores case, spaces,
    /// dots and hyphens, so "Node.js" matches "NodeJS" and "CI/CD" matches "ci / cd".
    static func missingKeywords(_ keywords: [String], in text: String) -> [String] {
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" } }
        let body = squash(text)
        var seen = Set<String>()
        return keywords.filter { k in
            let key = squash(k)
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return !body.contains(key)
        }
    }

    /// Share of `keywords` the text contains, 0…1 (1 when there are none).
    static func keywordScore(_ keywords: [String], in text: String) -> Double {
        let unique = Set(keywords.map { $0.lowercased() }).count
        guard unique > 0 else { return 1 }
        return 1 - Double(missingKeywords(keywords, in: text).count) / Double(unique)
    }

    /// What an applicant tracking system (Ashby, Greenhouse, Lever, Workday) would get wrong reading this résumé's text layer:
    /// missing contact details, non-standard or missing section headings, characters that do not extract as plain text, dates in
    /// mixed formats. Empty when it parses cleanly.
    static func atsIssues(text: String, name: String, email: String, phone: String) -> [String] {
        var issues: [String] = []
        let head = String(text.prefix(400))
        let lower = text.lowercased()
        if !name.isEmpty, !head.localizedCaseInsensitiveContains(name.split(separator: " ").first.map(String.init) ?? name) {
            issues.append("My name is not in the first lines of the extracted text, so a parser may take something else as the name.")
        }
        if !email.isEmpty, !lower.contains(email.lowercased()) { issues.append("My email \(email) does not extract as plain text.") }
        let digits = phone.filter(\.isNumber)
        if digits.count >= 10, !text.filter(\.isNumber).contains(String(digits.suffix(10))) {
            issues.append("My phone number does not extract as one plain number.")
        }
        for heading in ["experience", "education", "skills"] where !lower.contains(heading) {
            issues.append("No \u{201C}\(heading.capitalized)\u{201D} heading; parsers file sections by these standard names.")
        }
        if text.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) || (0xFB00...0xFB06).contains($0.value) || $0.value == 0xFFFD }) {
            issues.append("Some characters extract as ligatures, icons or unknown glyphs; use plain letters and no icon fonts.")
        }
        let styles = [#"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.? \d{4}"#, #"\b\d{1,2}/\d{4}\b"#, #"\b\d{4}-\d{2}\b"#]
        let used = styles.filter { text.range(of: $0, options: .regularExpression) != nil }.count
        if used > 1 { issues.append("Dates use more than one format; use \u{201C}Mon YYYY \u{2013} Mon YYYY\u{201D} everywhere.") }
        return issues
    }

    /// The text of every page of the PDF at `path`.
    static func text(ofPDFAt path: String) -> String {
        PDFDocument(url: URL(fileURLWithPath: path))?.string ?? ""
    }
}
