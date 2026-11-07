import Foundation

/// The résumé folder's layout: every .tex lives under TeX/ and every .pdf under PDF/. A company gets its own subfolder in both
/// once it has more than one résumé variant (any role); a company with one variant stays loose. Cover letters and other extras
/// follow their company into its folder but never make one on their own. Everything else in the folder is left alone.
enum ResumeFolders {
    static let texDir = "TeX", pdfDir = "PDF"

    private static func kindDir(_ ext: String) -> String { ext == "pdf" ? pdfDir : texDir }

    /// The company a file name names: the part after "First-Last-" in "First-Last-Company-Role…" (dashes or underscores, any case),
    /// when "First" is `firstName`. Nil for anything else ("Shiv Vyas copy.pdf", "Jainam_Resume.pdf").
    static func company(of stem: String, firstName: String) -> String? {
        let parts = stem.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard parts.count >= 4, !firstName.isEmpty, parts[0].caseInsensitiveCompare(firstName) == .orderedSame,
              !parts[2].contains(" "), parts[2].contains(where: \.isLetter) else { return nil }
        return parts[2]
    }

    /// One variant however it was copied or spelled: "X copy", "X copy 2" and "X_1" are X; dashes and underscores match; any case.
    static func variantKey(_ stem: String) -> String {
        var s = stem
        for pattern in [#" copy( \d+)?$"#, #"_\d+$"#] { s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        return s.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// False for cover letters, short answers and the like, which go with their company but never count as a variant.
    static func isResume(_ stem: String) -> Bool {
        let s = stem.lowercased().replacingOccurrences(of: "_", with: "-")
        return !["coverletter", "cover-letter", "short-answers", "exceptional-work"].contains { s.contains($0) }
    }

    /// The subfolder ("" or a company name) each stem belongs in, from all the stems in the folder.
    static func placement(stems: [String], firstName: String, existingFolders: [String] = []) -> [String: String] {
        var variants: [String: Set<String>] = [:], spellings: [String: [String]] = [:]
        for stem in stems {
            guard let c = company(of: stem, firstName: firstName) else { continue }
            spellings[c.lowercased(), default: []].append(c)
            if isResume(stem) { variants[c.lowercased(), default: []].insert(variantKey(stem)) }
        }
        func folderName(_ key: String) -> String {
            if let existing = existingFolders.first(where: { $0.lowercased() == key }) { return existing }
            let all = spellings[key] ?? [key]
            return all.max { a, b in
                let ua = a.contains(where: \.isUppercase), ub = b.contains(where: \.isUppercase)
                return ua != ub ? !ua : all.filter { $0 == a }.count < all.filter { $0 == b }.count
            } ?? key
        }
        var result: [String: String] = [:]
        for stem in stems {
            let key = company(of: stem, firstName: firstName)?.lowercased()
            result[stem] = key.flatMap { (variants[$0]?.count ?? 0) > 1 ? folderName($0) : nil } ?? ""
        }
        return result
    }

    #if os(macOS)
    /// Loose .tex/.pdf files at the top of `root` plus everything already under TeX/ and PDF/.
    private static func candidates(in root: String) -> [String] {
        let fm = FileManager.default
        var paths = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.map { root + "/" + $0 }
        for dir in [texDir, pdfDir] {
            let base = root + "/" + dir
            for rel in (fm.enumerator(atPath: base)?.allObjects as? [String]) ?? [] { paths.append(base + "/" + rel) }
        }
        return paths.filter {
            let name = ($0 as NSString).lastPathComponent, ext = ($0 as NSString).pathExtension.lowercased()
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && (ext == "tex" || ext == "pdf") && fm.fileExists(atPath: $0, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// Moves every .tex and .pdf to where the layout says, then removes company folders left empty. Safe to run any time: a
    /// tidy folder is left as it is. A file that would land on a different file of the same name gets " 2" (" 3"…) added; an
    /// identical one is dropped as the duplicate it is. Returns old path → new path for each file that moved.
    @discardableResult
    static func organize(root: String, firstName: String) -> [String: String] {
        let fm = FileManager.default
        let files = candidates(in: root)
        let existing = [texDir, pdfDir].flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: root + "/" + dir)) ?? []).filter { name in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: root + "/" + dir + "/" + name, isDirectory: &isDir) && isDir.boolValue
            }
        }
        let stems = files.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        let place = placement(stems: stems, firstName: firstName, existingFolders: existing)
        var moves: [String: String] = [:]
        for (path, stem) in zip(files, stems) {
            let file = (path as NSString).lastPathComponent, ext = (file as NSString).pathExtension.lowercased()
            let sub = place[stem] ?? ""
            let dir = root + "/" + kindDir(ext) + (sub.isEmpty ? "" : "/" + sub)
            var dest = dir + "/" + file
            guard dest != path else { continue }
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) {
                if fm.contentsEqual(atPath: path, andPath: dest) { try? fm.removeItem(atPath: path); moves[path] = dest; continue }
                var n = 2
                repeat { dest = dir + "/" + stem + " \(n)." + (file as NSString).pathExtension; n += 1 } while fm.fileExists(atPath: dest)
            }
            if (try? fm.moveItem(atPath: path, toPath: dest)) != nil { moves[path] = dest }
        }
        for dir in [texDir, pdfDir] {
            let base = root + "/" + dir
            for sub in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                let contents = (try? fm.contentsOfDirectory(atPath: base + "/" + sub)) ?? ["?"]
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: base + "/" + sub, isDirectory: &isDir), isDir.boolValue, contents.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(atPath: base + "/" + sub)
                }
            }
        }
        return moves
    }

    /// Every .tex résumé file: under TeX/ (any depth) and any still loose at the top of `root`.
    static func texFiles(in root: String) -> [String] {
        candidates(in: root).filter { ($0 as NSString).pathExtension.lowercased() == "tex" }
    }

    /// Where `name`.`ext` is now: the top of its kind folder, a company folder, or loose at the top of `root`. Nil when missing.
    static func find(_ name: String, ext: String, in root: String) -> String? {
        let fm = FileManager.default, file = name + "." + ext, base = root + "/" + kindDir(ext)
        for path in [base + "/" + file, root + "/" + file] where fm.fileExists(atPath: path) { return path }
        for sub in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !sub.hasPrefix(".") {
            let path = base + "/" + sub + "/" + file
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Where a new or regenerated variant's .tex goes: its current file, else the top of TeX/ (organize sorts it afterwards).
    static func texPath(for name: String, in root: String) -> String {
        find(name, ext: "tex", in: root) ?? root + "/" + texDir + "/" + name + ".tex"
    }

    /// A variant's .tex as Claude should open it from `root` (its working folder): "TeX/Apple/Shiv-Vyas-Apple-….tex".
    static func relativeTex(_ name: String, in root: String) -> String {
        relative(texPath(for: name, in: root), to: root)
    }

    /// `path` relative to `root` when it is inside it, else unchanged.
    static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// The folder a .tex builds its PDF into: the same place mirrored under PDF/ when the .tex is under TeX/, else beside it.
    static func pdfFolder(forTex texPath: String) -> String {
        var parts = ((texPath as NSString).deletingLastPathComponent as NSString).pathComponents
        guard let i = parts.lastIndex(of: texDir) else { return (texPath as NSString).deletingLastPathComponent }
        parts[i] = pdfDir
        return NSString.path(withComponents: parts)
    }

    /// The .tex a PDF was built from, mirrored back from PDF/ to TeX/ (or beside it for a loose PDF).
    static func texSibling(ofPDF pdfPath: String) -> String {
        var parts = ((pdfPath as NSString).deletingPathExtension as NSString).pathComponents
        if let i = parts.dropLast().lastIndex(of: pdfDir) { parts[i] = texDir }
        return NSString.path(withComponents: parts) + ".tex"
    }
    #endif
}
