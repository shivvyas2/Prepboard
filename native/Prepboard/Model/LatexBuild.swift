#if os(macOS)
import Foundation

/// Builds a .tex file into a PDF with `tectonic` (found through ClaudeCode.searchPath).
enum LatexBuild {
    struct Failure: LocalizedError {
        var log: String
        var errorDescription: String? { "PDF build failed: " + log }
    }

    /// Single-quotes a path for the shell.
    static func quoted(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }

    /// Runs `tectonic <file>` in the file's folder; returns the PDF path or throws Failure with the tail of the log.
    static func build(texPath: String) async throws -> String {
        let folder = (texPath as NSString).deletingLastPathComponent, file = (texPath as NSString).lastPathComponent
        let pdf = (texPath as NSString).deletingPathExtension + ".pdf"
        let start = Date.now
        let log = await ClaudeCode.shell("cd '\(quoted(folder))' && tectonic '\(quoted(file))' 2>&1")
        let modified = (try? FileManager.default.attributesOfItem(atPath: pdf))?[.modificationDate] as? Date
        guard let modified, modified >= start.addingTimeInterval(-1) else {
            throw Failure(log: String(log.suffix(1500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pdf
    }
}
#endif
