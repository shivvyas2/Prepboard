#if os(macOS)
import AppKit
import Foundation
import Observation

/// Runs the user's local Claude Code CLI in headless mode (`claude -p`) and streams the reply.
///
/// The CLI is started through a login shell so it gets the same PATH and auth as the user's terminal.
/// Only read-only and research tools are allowed, so Claude can read the prep folder and search the web
/// but can't edit files or run commands from inside the app.
@MainActor
@Observable
final class ClaudeCode {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    static let allowedTools = "Read Grep Glob WebSearch WebFetch"

    enum Connection: Equatable { case unknown, checking, notInstalled, signedOut, connected(String) }

    /// Use the Claude Code already on this Mac automatically; only off if the user chose Disconnect.
    var enabled: Bool = UserDefaults.standard.object(forKey: "claude.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "claude.enabled") }
    }
    var connection: Connection = .unknown
    var isReady: Bool { enabled && { if case .connected = connection { true } else { false } }() }
    /// True while a headless run (JobSync or JobHunt) has the built-in browser; the schedulers wait for it.
    var busy = false

    /// Checks that the `claude` CLI is installed and signed in.
    func checkConnection() async {
        connection = .checking
        let result = await Self.shellResult(#"command -v claude >/dev/null || { echo NOT_INSTALLED; exit 0; }; claude --version; claude auth status"#)
        let out = result.stdout
        if out.contains("NOT_INSTALLED") { connection = .notInstalled; return }
        let version = out.split(separator: "\n").first.map(String.init) ?? "Claude Code"
        let signedIn = Self.jsonObject(out)?["loggedIn"] as? Bool ?? false
        connection = signedIn ? .connected(version) : .signedOut
    }

    func connect() async {
        await checkConnection()
        if case .connected = connection { enabled = true }
    }

    func disconnect() { enabled = false; reset() }

    /// Opens Terminal running `claude auth login` so the user signs in with their own account.
    func openSignIn() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-claude-login.command")
        try? "#!/bin/zsh -l\nclaude auth login\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// PATH for running `claude`: the usual install folders first, then the login shell's PATH.
    /// Apps opened from Finder don't read ~/.zshrc, which is where many installs (e.g. ~/.local/bin) add themselves.
    nonisolated static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                    "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.asdf/shims"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        return (dirs + [ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
    }

    struct ShellResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    /// Ignore a login shell's banner before the JSON emitted by the CLI.
    nonisolated static func jsonObject(_ output: String) -> [String: Any]? {
        guard let end = output.lastIndex(of: "}") else { return nil }
        for start in output.indices where output[start] == "{" && start <= end {
            if let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any] { return object }
        }
        return nil
    }

    /// Written by one pipe reader and read only after its DispatchGroup has completed.
    private final class PipeCapture: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a command in a login shell and returns stdout+stderr.
    nonisolated static func shell(_ command: String, stdin: String? = nil) async -> String {
        let result = await shellResult(command, stdin: stdin)
        return result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
    }

    /// Keeps diagnostics separate from JSON output. Both pipes are drained concurrently, including after the child exits.
    nonisolated static func shellResult(_ command: String, stdin: String? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Prepend the install folders after the login profile runs, so a profile can't hide them.
            p.arguments = ["-lc", "export PATH=\"$PB_PATH:$PATH\"; " + command]
            var env = ProcessInfo.processInfo.environment
            env["PB_PATH"] = searchPath
            p.environment = env
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = inp
            do {
                try p.run()
                // Concurrent readers prevent a full stderr or stdout pipe from stalling a long browser run.
                let readers = DispatchGroup()
                let stdout = PipeCapture(), stderr = PipeCapture()
                readers.enter()
                DispatchQueue.global().async {
                    stdout.data = out.fileHandleForReading.readDataToEndOfFile()
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global().async {
                    stderr.data = err.fileHandleForReading.readDataToEndOfFile()
                    readers.leave()
                }
                DispatchQueue.global().async {
                    if let stdin { try? inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
                    try? inp.fileHandleForWriting.close()
                    p.waitUntilExit()
                    readers.wait()
                    cont.resume(returning: ShellResult(stdout: String(decoding: stdout.data, as: UTF8.self),
                                                       stderr: String(decoding: stderr.data, as: UTF8.self), exitCode: p.terminationStatus))
                }
            } catch {
                cont.resume(returning: ShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
            }
        }
    }

    var messages: [Message] = []
    var isRunning = false
    var status: String?
    var error: String?
    private(set) var sessionId: String?
    private var process: Process?
    private var buffer = Data()

    var workingDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "claudeWorkdir") { return URL(fileURLWithPath: path) }
            let prep = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Apple INterview")
            return FileManager.default.fileExists(atPath: prep.path) ? prep : FileManager.default.homeDirectoryForCurrentUser
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "claudeWorkdir") }
    }

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = workingDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url }
    }

    func reset() {
        stop()
        messages = []
        sessionId = nil
        error = nil
        status = nil
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
        status = nil
    }

    /// Sends a question. `context` is included only on the first turn; follow-ups resume the same session.
    func send(_ question: String, context: String?) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isRunning else { return }
        error = nil
        messages.append(Message(role: .user, text: q))
        messages.append(Message(role: .assistant, text: ""))

        var prompt = q
        if sessionId == nil {
            prompt = """
            I'm using PrepBoard, my interview-prep app. Answer concisely in Markdown (short sections, bullets, \
            code blocks in Swift when useful). My prep guides are Markdown files in the current folder; read them \
            when relevant.
            """
            if let context, !context.isEmpty { prompt += "\n\n<context>\n\(context)\n</context>" }
            prompt += "\n\n\(q)"
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", #"""
        export PATH="$PB_PATH:$PATH"; cd "$PB_DIR" && exec claude -p --output-format stream-json --verbose --include-partial-messages \
          --allowedTools $=PB_TOOLS ${PB_RESUME:+--resume} ${PB_RESUME:+"$PB_RESUME"}
        """#]
        var env = ProcessInfo.processInfo.environment
        env["PB_DIR"] = workingDirectory.path
        env["PB_PATH"] = Self.searchPath
        env["PB_TOOLS"] = Self.allowedTools
        if let sessionId { env["PB_RESUME"] = sessionId }
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        buffer = Data()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            let errText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            stdout.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            Task { @MainActor in self?.finished(code: code, stderr: errText) }
        }

        do {
            try p.run()
            process = p
            isRunning = true
            status = "Thinking…"
            stdin.fileHandleForWriting.write(Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
        } catch {
            self.error = "Couldn't start Claude Code: \(error.localizedDescription)"
            messages.removeLast()
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                appendToReply(text)
                status = "Writing…"
            } else if event["type"] as? String == "content_block_start",
                      let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "a tool"
                status = "Using \(name)…"
                if let last = messages.last, last.role == .assistant, !last.text.isEmpty, !last.text.hasSuffix("\n\n") {
                    appendToReply("\n\n")
                }
            }
        case "result":
            sessionId = obj["session_id"] as? String ?? sessionId
            if obj["is_error"] as? Bool == true {
                error = (obj["result"] as? String) ?? "Claude Code returned an error."
            } else if let result = obj["result"] as? String, messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                appendToReply(result)
            }
        default:
            break
        }
    }

    private func appendToReply(_ text: String) {
        guard let i = messages.indices.last, messages[i].role == .assistant else { return }
        messages[i].text += text
    }

    private func finished(code: Int32, stderr: String) {
        isRunning = false
        status = nil
        process = nil
        if code != 0 && code != 15 && error == nil {
            let hint = stderr.contains("command not found") ? "The `claude` command wasn't found. Install Claude Code and make sure it works in Terminal." : stderr
            error = hint.isEmpty ? "Claude Code exited with code \(code)." : String(hint.suffix(400))
        }
        if let i = messages.indices.last, messages[i].role == .assistant { messages[i].text = messages[i].text.withoutEmoji }
        if let last = messages.last, last.role == .assistant, last.text.isEmpty { messages.removeLast() }
    }
}
#endif
