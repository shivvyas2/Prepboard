import Foundation

/// The interview note (a few sentences the email sync or the planner wrote) split into what the dashboard shows as facts:
/// the round, its length, the tools, when to join, and one line per remaining detail.
struct InterviewBrief: Equatable {
    enum Kind: Equatable { case person, contact, phone, language, warning, timing, info }
    struct Detail: Equatable { var kind: Kind; var text: String }

    var round = ""              // "Second technical round"
    var minutes: Int?           // 45
    var tools: [String] = []    // ["Webex", "CoderPad"]
    var earlyMinutes: Int?      // "join no more than 10 minutes early" → 10
    var details: [Detail] = []

    static let toolNames = ["Microsoft Teams", "Google Meet", "Webex", "Zoom", "Teams", "Chime", "FaceTime", "CoderPad", "HackerRank",
                            "CodeSignal", "Karat", "HackerEarth", "Codility", "Onsite", "On-site", "Phone screen"]

    init(note: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        minutes = Self.number(#"(\d{2,3})[ -]?(?:min\b|mins\b|minutes?\b)"#, in: text).flatMap { (10...480).contains($0) ? $0 : nil }
        earlyMinutes = Self.number(#"(\d{1,2})[ -]?(?:min|mins|minutes?) early"#, in: text)
        for name in Self.toolNames where Self.contains(word: name, in: text) {
            if !tools.contains(where: { $0.localizedCaseInsensitiveContains(name) }) { tools.append(name) }
        }
        for sentence in Self.sentences(text) {
            let lower = sentence.lowercased()
            // The time, length and tools already show as facts above the list.
            if sentence.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { continue }
            if round.isEmpty, lower.contains("round") || lower.hasSuffix("interview"), sentence.split(separator: " ").count <= 6 {
                round = sentence; continue
            }
            // "Join no more than 10 minutes early" is the join step on the track.
            if earlyMinutes != nil, lower.contains("early"), Self.kind(lower) == .timing { continue }
            details.append(Detail(kind: Self.kind(lower), text: sentence))
        }
    }

    private static func kind(_ s: String) -> Kind {
        func has(_ words: String...) -> Bool { words.contains { s.contains($0) } }
        if has("no coderpad", "no link", "unlike", "missing", "not yet", "hasn't", "has not") { return .warning }
        if has("will call", "phone", "dial") { return .phone }
        if has("interviewer", "panel", "hiring manager") { return .person }
        if has("coordinator", "recruiter", "sourcer", "@") { return .contact }
        if has("early", "join", "arrive", "log in") { return .timing }
        if has("c++", "swift", "python", "java", "language", "objective-c") { return .language }
        return .info
    }

    /// Sentences, each without its final period. A split needs ". " and a capital next, so emails, numbers and "e.g." stay whole.
    static func sentences(_ text: String) -> [String] {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var result: [String] = [], start = flat.startIndex
        let re = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z0-9(])"#)
        for m in re?.matches(in: flat, range: NSRange(flat.startIndex..., in: flat)) ?? [] {
            guard let r = Range(m.range, in: flat) else { continue }
            result.append(String(flat[start..<r.lowerBound])); start = r.upperBound
        }
        result.append(String(flat[start...]))
        return result.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    private static func number(_ pattern: String, in text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    private static func contains(word: String, in text: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
