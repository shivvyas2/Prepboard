#if os(macOS)
import Foundation

/// Builds a .tex file into a PDF with `tectonic` (found through ClaudeCode.searchPath).
enum LatexBuild {
    struct Failure: LocalizedError {
        var log: String
        var errorDescription: String? { "PDF build failed: " + log }
    }

    /// US applications get US Letter: `a4paper` in the \\documentclass or geometry options becomes `letterpaper`. Older variants
    /// were A4 and every tailored copy kept their preamble, so recruiters' printers and ATS previews got an A4 page.
    static func usLetter(_ tex: String) -> String {
        let pattern = #"(\\(?:documentclass|usepackage)\[[^\]]*?)\ba4paper\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return tex }
        return re.stringByReplacingMatches(in: tex, range: NSRange(tex.startIndex..., in: tex), withTemplate: "$1letterpaper")
    }

    /// Single-quotes a path for the shell.
    static func quoted(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }

    /// Runs `tectonic <file>` in the file's folder, writing the PDF to the mirrored PDF/ folder (ResumeFolders.pdfFolder);
    /// returns the PDF path or throws Failure with the tail of the log.
    static func build(texPath: String) async throws -> String {
        if let tex = try? String(contentsOfFile: texPath, encoding: .utf8), case let letter = usLetter(tex), letter != tex {
            try? letter.write(toFile: texPath, atomically: true, encoding: .utf8)
        }
        let folder = (texPath as NSString).deletingLastPathComponent, file = (texPath as NSString).lastPathComponent
        let out = ResumeFolders.pdfFolder(forTex: texPath)
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let pdf = out + "/" + ((file as NSString).deletingPathExtension) + ".pdf"
        let start = Date.now
        let log = await ClaudeCode.shell("cd '\(quoted(folder))' && tectonic -o '\(quoted(out))' '\(quoted(file))' 2>&1")
        let modified = (try? FileManager.default.attributesOfItem(atPath: pdf))?[.modificationDate] as? Date
        guard let modified, modified >= start.addingTimeInterval(-1) else {
            throw Failure(log: String(log.suffix(1500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pdf
    }

    /// Builds `tex` in a scratch folder (nothing in the résumé folder changes) and returns the PDF bytes; for the live preview.
    static func preview(tex: String, name: String) async throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-hunt/preview/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let texPath = dir.appendingPathComponent(name + ".tex").path
        try tex.write(toFile: texPath, atomically: true, encoding: .utf8)
        let pdf = try await build(texPath: texPath)
        return try Data(contentsOf: URL(fileURLWithPath: pdf))
    }
}
#endif
