#if os(macOS)
import AppKit
import SwiftTerm
import SwiftUI

/// The real, interactive Claude Code (`claude` in a terminal) inside PrepBoard, in the prep folder.
/// One session lives for the whole app run, so switching tabs or closing the panel doesn't end it.
@MainActor
final class ClaudeTerminal: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = ClaudeTerminal()

    private(set) lazy var view: LocalProcessTerminalView = {
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v.processDelegate = self
        v.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        v.nativeBackgroundColor = NSColor(PB.card)
        v.nativeForegroundColor = NSColor(PB.ink)
        v.caretColor = NSColor(PB.cobalt)
        return v
    }()
    private(set) var running = false

    /// Starts `claude` in the working folder; when it exits, the user lands in their normal shell there.
    func startIfNeeded(in directory: URL) {
        guard !running else { return }
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let path = ClaudeCode.searchPath
        env.removeAll { $0.hasPrefix("PATH=") }
        env.append("PATH=\(path)")
        env.append("PB_PATH=\(path)")
        // Interactive login shell so the user's own ~/.zshrc setup applies, exactly like Terminal.
        view.startProcess(executable: "/bin/zsh",
                          args: ["-ilc", #"export PATH="$PB_PATH:$PATH"; claude; exec zsh -il"#],
                          environment: env, execName: "-zsh", currentDirectory: directory.path)
        running = true
    }

    func restart(in directory: URL) {
        view.terminate()
        running = false
        view.getTerminal().resetToInitialState()
        startIfNeeded(in: directory)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.running = false }
    }
}

struct ClaudeTerminalView: NSViewRepresentable {
    let directory: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let term = ClaudeTerminal.shared.view
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            term.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        ClaudeTerminal.shared.startIfNeeded(in: directory)
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        return container
    }

    func updateNSView(_ v: NSView, context: Context) {}
}
#endif
