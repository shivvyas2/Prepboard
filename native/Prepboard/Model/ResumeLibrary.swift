import Foundation

/// One .tex résumé variant in the user's folder, described by the comment header at the top of the file.
struct ResumeVariant: Identifiable, Hashable {
    var id: String { name }
    var name: String            // file name without extension
    var path: String
    var company: String         // from "APPLE VARIANT:" → "Apple"; "" if no VARIANT line
    var roleTag: String         // rest of the VARIANT line
    var family: String          // ResumeLibrary.family(of:)
    var jdMap: [String]         // bullets of the JD MAP block
    var ledger: [String]        // bullets of the HONESTY LEDGER block
    var modified: Date
}

/// Reads, classifies and picks résumé variants. The pure parts run everywhere; folder scanning is Mac-only.
enum ResumeLibrary {
    /// True when `text` contains a word starting with `word` ("swift" matches "SwiftUI", "ios" does not match "bios").
    private static func has(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0), options: .regularExpression) != nil }
    }

    /// "ios" | "fullstack" | "frontend" | "reactnative" | "backend" | "sde" from a title or role tag.
    static func family(of text: String) -> String {
        let t = text.lowercased()
        if has(t, ["react native", "react-native"]) { return "reactnative" }
        if has(t, ["ios", "swift", "mobile", "apple platforms", "iphone", "ipad", "macos", "watchos", "visionos"]) { return "ios" }
        if has(t, ["full stack", "fullstack", "full-stack"]) { return "fullstack" }
        if has(t, ["front end", "frontend", "front-end", "react", "web"]) { return "frontend" }
        if has(t, ["backend", "back end", "back-end", "distributed", "infrastructure", "platform"]) { return "backend" }
        return "sde"
    }

    /// "GOLDMAN SACHS" → "Goldman Sachs"; short vowel-less initialisms ("JPMC", "NYT") stay upper-case.
    static func companyName(_ raw: String) -> String {
        raw.split(separator: " ").map { w -> String in
            let word = String(w), letters = word.filter(\.isLetter)
            guard !letters.isEmpty, letters == letters.uppercased() else { return word }
            if letters.count <= 4, !letters.lowercased().contains(where: { "aeiou".contains($0) }) { return word }
            return word.prefix(1) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// A "SOMETHING:" heading: only capitals before the colon, parenthesised asides ignored.
    private static func isHeading(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        var head = String(line[..<colon])
        while let open = head.firstIndex(of: "("), let close = head[open...].firstIndex(of: ")") { head.removeSubrange(open...close) }
        let letters = head.filter(\.isLetter)
        return letters.count >= 2 && !letters.contains(where: \.isLowercase)
    }

    private enum Block { case other, jdMap, ledger }

    /// The block a "JD MAP…:" / "HONESTY LEDGER…:" line opens (prefix, case-insensitive, any aside before the colon).
    private static func knownBlock(_ line: String) -> Block? {
        guard line.contains(":") else { return nil }
        let upper = line.uppercased()
        if upper.hasPrefix("JD MAP") { return .jdMap }
        if upper.hasPrefix("HONESTY LEDGER") { return .ledger }
        return nil
    }

    /// Parses the comment header of one .tex file (the leading lines that start with "%").
    static func parse(name: String, path: String, header: String, modified: Date) -> ResumeVariant {
        var company = "", roleTag = "", jdMap: [String] = [], ledger: [String] = []
        var block = Block.other, entries: [String] = [], open = false, inVariant = false, sawVariant = false
        func finish() {
            switch block { case .jdMap: jdMap += entries; case .ledger: ledger += entries; case .other: break }
            block = .other; entries = []; open = false
        }
        for raw in header.split(separator: "\n", omittingEmptySubsequences: false) {
            guard raw.hasPrefix("%") else { break }
            let line = raw.drop { $0 == "%" }.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.allSatisfy({ "-=% ".contains($0) }) { open = false; inVariant = false; continue }
            if !sawVariant, let r = line.range(of: " VARIANT:") {
                company = companyName(String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces))
                roleTag = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                sawVariant = true; inVariant = true
                continue
            }
            if line.hasPrefix("*") {
                inVariant = false
                guard block != .other else { continue }
                entries.append(line.dropFirst().trimmingCharacters(in: .whitespaces)); open = true
                continue
            }
            if let known = knownBlock(line) ?? (isHeading(line) ? Block.other : nil) {
                inVariant = false
                finish()
                guard known != .other else { continue }
                block = known
                let rest = line[line.index(after: line.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { entries.append(rest); open = true }
                continue
            }
            if inVariant { roleTag += " " + line; continue }
            if open, !entries.isEmpty { entries[entries.count - 1] += " " + line }
        }
        finish()
        return ResumeVariant(name: name, path: path, company: company, roleTag: roleTag, family: family(of: roleTag.isEmpty ? name : roleTag),
                             jdMap: jdMap, ledger: ledger, modified: modified)
    }

    /// Variant names attached to roles that reached Technical, Onsite or Offer.
    static func winners(roles: [Role]) -> Set<String> {
        Set(roles.filter { [.technical, .onsite, .offer].contains($0.stage) && !$0.resumeVariant.isEmpty }.map(\.resumeVariant))
    }

    private static let stopwords: Set<String> = ["and", "the", "for", "with", "you", "our", "are", "will", "that", "this", "your", "from", "have", "work",
                                                 "team", "experience", "years", "role", "engineer", "software", "about", "who", "what", "all", "can", "not"]

    /// Lower-cased words of three or more letters, minus filler, for keyword overlap.
    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "+" || $0 == "#") }
            .map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// Base-variant choice, in order: a winner with the same company and family; a winner with the same family; any variant
    /// with the same company and family; the variant with the most keyword overlap with the lead (ties → most recently modified).
    static func pickBase(for lead: Lead, variants: [ResumeVariant], winners: Set<String>) -> (ResumeVariant, String)? {
        guard !variants.isEmpty else { return nil }
        let family = family(of: lead.title), company = JobMerge.key(lead.company)
        func newest(_ vs: [ResumeVariant]) -> ResumeVariant? { vs.max { $0.modified < $1.modified } }
        let sameCompany = { (v: ResumeVariant) in !company.isEmpty && JobMerge.key(v.company) == company }
        if let v = newest(variants.filter { winners.contains($0.name) && sameCompany($0) && $0.family == family }) {
            return (v, "Winner at \(lead.company) for \(family) roles")
        }
        if let v = newest(variants.filter { winners.contains($0.name) && $0.family == family }) {
            return (v, "Winner for \(family) roles")
        }
        if let v = newest(variants.filter { sameCompany($0) && $0.family == family }) {
            return (v, "Earlier \(lead.company) \(family) variant")
        }
        let wanted = keywords(lead.title + " " + lead.jd)
        let scored = variants.map { v in (v, keywords(v.roleTag + " " + v.jdMap.joined(separator: " ")).intersection(wanted).count) }
        let best = scored.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.modified < b.0.modified }!
        return (best.0, best.1 > 0 ? "Most keyword overlap with the posting (\(best.1) terms)" : "No keyword overlap; newest variant")
    }

    /// Dedupe key for a lead: company + posting id, or company + title when there is no id.
    static func dedupeKey(company: String, title: String, roleNumber: String) -> String {
        let number = roleNumber.trimmingCharacters(in: .whitespaces)
        return JobMerge.key(company) + "|" + (number.isEmpty ? JobMerge.key(title) : number)
    }

    private static let filler: Set<String> = ["a", "an", "and", "at", "for", "in", "of", "or", "the", "to", "with"]

    /// "Software Development Engineer, Screen Sharing" → "SoftwareDevelopmentEngineer" (first `limit` words, filler dropped).
    private static func camel(_ text: String, limit: Int = .max) -> String {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !filler.contains($0.lowercased()) }.prefix(limit)
            .map { $0.contains(where: \.isUppercase) ? $0 : $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// "Shiv-Vyas-Apple-SoftwareDevelopmentEngineer" style name, made unique with -2, -3… against `existing`.
    static func variantName(userName: String, company: String, title: String, existing: Set<String>) -> String {
        let person = userName.split(separator: " ").prefix(2).map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }.joined(separator: "-")
        var parts = [person.isEmpty ? "Resume" : person, camel(company), camel(title, limit: 3)].filter { !$0.isEmpty }
        if parts.count == 1 { parts.append("Role") }
        let base = parts.joined(separator: "-")
        var name = base, n = 2
        while existing.contains(name) { name = "\(base)-\(n)"; n += 1 }
        return name
    }

    // MARK: contact details

    /// The contact block at the top of a résumé: the name in `\LARGE{…}` (or `\Huge`), then the `$|$`-separated line with the city,
    /// phone, email and links. Only what is found is set; everything else stays empty.
    static func contact(fromTex tex: String) -> AnswerBank {
        var bank = AnswerBank()
        let body = tex.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }.joined(separator: "\n")
        func first(_ pattern: String, in text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let namePattern = #"\\(?:LARGE|Huge|huge|Large)\s*\{(?:\\textbf\{)?([^{}\\]+)"#
        guard let nameRange = body.range(of: namePattern, options: .regularExpression) else { return bank }
        bank.fullName = first(namePattern, in: body) ?? ""
        // The header ends at the first section; contact lines sit between the name and there.
        var rest = body[nameRange.upperBound...]
        if let close = rest.firstIndex(of: "}"), !rest[..<close].contains("\n") { rest = rest[rest.index(after: close)...] }   // the name's own brace
        let end = [rest.range(of: "\\section"), rest.range(of: "\\end{tabularx}"), rest.range(of: "\\end{center}")]
            .compactMap { $0?.lowerBound }.min() ?? rest.endIndex
        let header = String(rest[..<end])
        bank.email = first(#"mailto:([^}\s]+)"#, in: header) ?? first(#"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})"#, in: header) ?? ""
        let links = (try? NSRegularExpression(pattern: #"\\href\{(https?://[^}]+)\}"#))?
            .matches(in: header, range: NSRange(header.startIndex..., in: header))
            .compactMap { Range($0.range(at: 1), in: header).map { String(header[$0]) } } ?? []
        bank.linkedin = links.first { $0.contains("linkedin.com/") } ?? ""
        bank.github = links.first { $0.contains("github.com/") } ?? ""
        bank.portfolio = links.first { !$0.contains("linkedin.com/") && !$0.contains("github.com/") } ?? ""
        let lines = header.components(separatedBy: "\n").filter { line in
            !["\\normalsize", "\\small{", "\\large", "\\textit"].contains { line.contains($0) }   // the headline under the name
        }
        let segments = lines.joined(separator: " ").components(separatedBy: "$|$").map { seg -> String in
            var s = seg.replacingOccurrences(of: #"\\\\(\[[^\]]*\])?"#, with: " ", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\ ", with: " ").replacingOccurrences(of: "~", with: " ")
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for seg in segments where bank.phone.isEmpty {
            let digits = seg.filter(\.isNumber)
            if !seg.contains("\\"), !seg.contains("@"), (10...13).contains(digits.count),
               seg.allSatisfy({ $0.isNumber || " +-().".contains($0) }) { bank.phone = seg }
        }
        bank.city = segments.first { seg in
            !seg.isEmpty && seg.count <= 40 && !seg.contains("\\") && !seg.contains("@") && !seg.contains(where: \.isNumber)
                && !seg.contains("{") && !seg.contains("}") && !seg.lowercased().contains(".com") && seg.contains(where: \.isLetter)
        } ?? ""
        return bank
    }

    /// `bank` with its empty contact fields taken from `found`; never overwrites an answer. Returns the labels it filled.
    static func filling(_ bank: AnswerBank, from found: AnswerBank) -> (bank: AnswerBank, filled: [String]) {
        var result = bank, filled: [String] = []
        let fields: [(String, WritableKeyPath<AnswerBank, String>)] = [("name", \.fullName), ("email", \.email), ("phone", \.phone),
            ("city", \.city), ("LinkedIn", \.linkedin), ("GitHub", \.github), ("portfolio", \.portfolio)]
        for (label, kp) in fields where result[keyPath: kp].trimmingCharacters(in: .whitespaces).isEmpty && !found[keyPath: kp].isEmpty {
            result[keyPath: kp] = found[keyPath: kp]; filled.append(label)
        }
        return (result, filled)
    }

    #if os(macOS)
    /// Reads every *.tex in the folder (not subfolders) and parses its header; sorted by name.
    /// Cover letters and short-answer files are left out: no VARIANT line and no JD MAP / HONESTY LEDGER block, or "coverletter" in the name.
    static func scan(folder: String) throws -> [ResumeVariant] {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: folder).filter {
            $0.lowercased().hasSuffix(".tex") && !$0.hasPrefix(".") && !$0.lowercased().contains("coverletter")
        }
        return files.compactMap { file -> ResumeVariant? in
            let path = folder + "/" + file
            guard let data = fm.contents(atPath: path) else { return nil }
            let header = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                .prefix { $0.hasPrefix("%") }.joined(separator: "\n")
            let modified = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
            let v = parse(name: (file as NSString).deletingPathExtension, path: path, header: header, modified: modified)
            guard !v.company.isEmpty || !v.roleTag.isEmpty || !v.jdMap.isEmpty || !v.ledger.isEmpty else { return nil }
            return v
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    #endif
}
