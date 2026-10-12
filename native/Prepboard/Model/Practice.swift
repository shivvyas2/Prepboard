import Foundation
#if os(iOS)
import JavaScriptCore
import WebKit
#endif

/// LeetCode/CoderPad-style practice: languages, running code, and the AI that writes problems and assists like CoderPad's.
enum CodeLang: String, CaseIterable, Identifiable {
    case swift, python, javascript
    var id: String { rawValue }
    var label: String { switch self { case .swift: "Swift"; case .python: "Python"; case .javascript: "JavaScript" } }
    var ext: String { switch self { case .swift: "swift"; case .python: "py"; case .javascript: "js" } }

    /// Where "Run" happens: the Mac compiles everything locally; iPhone/iPad run JavaScript and Python
    /// (Pyodide, CPython in WebAssembly) on the device and send Swift to the paired Mac.
    var runnerNote: String {
        #if os(macOS)
        "Runs on this Mac"
        #else
        self == .swift ? "Runs on your paired Mac" : "Runs on this device"
        #endif
    }
}

struct ProblemPayload: Codable {
    let title: String
    let difficulty: String
    let topics: [String]
    let statement: String
    let starters: [String: String]
}

/// One "✓ Test N" / "✗ Test N: expected X, got Y" line from a starter's test harness.
struct TestCase: Equatable {
    let number: Int
    let passed: Bool
    let detail: String
}

/// A compiler or syntax-check message, located in the user's file.
struct Diagnostic: Equatable {
    enum Severity: String { case error, warning, note }
    let line: Int
    let column: Int?
    let severity: Severity
    let message: String
}

/// Everything a Run produced, kept apart the way LeetCode shows it: the compile step, the program's output, and the tests.
struct RunResult: Codable, Equatable {
    enum Verdict: String { case accepted, wrongAnswer, compileError, runtimeError, timeLimit, finished, couldNotRun }

    /// Compiler (Swift) or syntax-check (Python, Node) log; nil when there was no compile step.
    var compiler: String?
    var compileStatus: Int32?
    var compileSeconds: Double?
    /// The program's stdout and stderr, interleaved as printed.
    var output = ""
    var exitCode: Int32?
    var runSeconds: Double?
    var timedOut = false
    /// Where it ran or why it couldn't ("Interpreted on this device", "Node.js isn't installed…").
    var note: String?
    var couldNotRun = false

    var compileFailed: Bool { (compileStatus ?? 0) != 0 }

    var tests: [TestCase] {
        output.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.firstMatch(of: #/^([✓✗]) Test (\d+)(?::\s*(.*))?$/#), let n = Int(m.2) else { return nil }
            return TestCase(number: n, passed: m.1 == "✓", detail: m.3.map(String.init) ?? "")
        }
    }

    /// "Passed K/N" from the harness.
    var passed: (Int, Int)? {
        guard let m = output.firstMatch(of: #/Passed (\d+)\/(\d+)/#), let k = Int(m.1), let n = Int(m.2) else { return nil }
        return (k, n)
    }

    /// What the program printed besides the harness's test lines.
    var programOutput: String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !(t.hasPrefix("✓ Test") || t.hasPrefix("✗ Test") || t.firstMatch(of: #/^Passed \d+\/\d+$/#) != nil)
            }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var verdict: Verdict {
        if couldNotRun { return .couldNotRun }
        if compileFailed { return .compileError }
        if timedOut { return .timeLimit }
        if let code = exitCode, code != 0 { return .runtimeError }
        if exitCode == nil, output.contains("Traceback (most recent call last)") || output.contains("\nError: ") { return .runtimeError }
        if let p = passed { return p.0 == p.1 ? .accepted : .wrongAnswer }
        if tests.contains(where: { !$0.passed }) { return .wrongAnswer }
        return .finished
    }

    /// Compiler messages: Swift's "file:line:col: error: …", Python's `File "…", line N` + "XError: …", and Node's "file:N" + "SyntaxError: …".
    var diagnostics: [Diagnostic] {
        guard let log = compiler, !log.isEmpty else { return [] }
        let lines = log.split(separator: "\n").map(String.init)
        var found: [Diagnostic] = []
        for l in lines {
            if let m = l.firstMatch(of: #/^.*?:(\d+):(\d+): (error|warning|note): (.*)$/#), let line = Int(m.1) {
                found.append(Diagnostic(line: line, column: Int(m.2), severity: Diagnostic.Severity(rawValue: String(m.3)) ?? .error, message: String(m.4)))
            }
        }
        if !found.isEmpty { return found }
        let lineNo = lines.lazy.compactMap { l -> Int? in
            if let m = l.firstMatch(of: #/File ".*", line (\d+)/#) { return Int(m.1) }
            if let m = l.firstMatch(of: #/^.*\.(?:js|py):(\d+)$/#) { return Int(m.1) }
            return nil
        }.first
        if let lineNo, let msg = lines.first(where: { $0.firstMatch(of: #/^\w*Error: /#) != nil }) {
            return [Diagnostic(line: lineNo, column: nil, severity: .error, message: msg)]
        }
        return []
    }

    /// The whole run as one block of text, for older paired iPhones/iPads that only read `output` from the bridge.
    var text: String {
        if couldNotRun { return note ?? "Couldn't run." }
        var parts: [String] = []
        if let c = compiler?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { parts.append(c) }
        if !compileFailed { parts.append(output.isEmpty ? "(no output)" : output.trimmingCharacters(in: .newlines)) }
        let status: String
        if compileFailed { status = "Compile error" }
        else if timedOut { status = "Stopped after 30s (infinite loop?)" }
        else if let code = exitCode { status = "Exit \(code)" + (runSeconds.map { String(format: " · %.1fs", $0) } ?? "") }
        else { status = runSeconds.map { String(format: "%.2fs", $0) } ?? "Done" }
        parts.append("— \(status)")
        return parts.joined(separator: "\n")
    }
}

enum CodeRunner {
    /// Compiles (or syntax-checks), then runs the whole file: the user's solution plus the starter's test harness.
    @MainActor static func run(_ code: String, lang: CodeLang, mac: ClaudeCode? = nil) async -> RunResult {
        #if os(macOS)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prepboard-run-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.\(lang.ext)")
        do { try code.write(to: file, atomically: true, encoding: .utf8) } catch {
            return RunResult(note: "Couldn't save the file: \(error.localizedDescription)", couldNotRun: true)
        }
        let binary = dir.appendingPathComponent("main")
        let (compileExe, compileArgs, runExe, runArgs): (String, [String], String, [String]) = switch lang {
        case .swift: ("/usr/bin/xcrun", ["swiftc", file.path, "-o", binary.path], binary.path, [])
        case .python: ("/usr/bin/env", ["python3", "-m", "py_compile", file.path], "/usr/bin/env", ["python3", file.path])
        case .javascript: ("/usr/bin/env", ["node", "--check", file.path], "/usr/bin/env", ["node", file.path])
        }
        let missing = lang == .javascript ? "Node.js isn't installed. Install it from nodejs.org, or use Swift or Python."
            : lang == .python ? "Python 3 isn't installed. Run `xcode-select --install`, or use Swift."
            : "The Swift compiler isn't installed. Run `xcode-select --install`."

        var result = RunResult()
        let compile = await exec(compileExe, compileArgs, in: dir, limit: 60)
        if compile.launchError != nil || compile.status == 127 { return RunResult(note: missing, couldNotRun: true) }
        result.compiler = compile.output
        result.compileStatus = compile.timedOut ? -1 : compile.status
        result.compileSeconds = compile.seconds
        if result.compileFailed { return result }

        let run = await exec(runExe, runArgs, in: dir, limit: 30)
        if let e = run.launchError { return RunResult(note: "Couldn't run: \(e)", couldNotRun: true) }
        result.output = run.output
        result.exitCode = run.status
        result.runSeconds = run.seconds
        result.timedOut = run.timedOut
        return result
        #else
        switch lang {
        case .swift:
            guard let mac, mac.paired else {
                return RunResult(note: "Swift compiles on your Mac. Pair this device in Profile → Claude Code on my Mac (with PrepBoard open on the Mac), or tap Review to have AI check your solution.", couldNotRun: true)
            }
            do { return try await mac.exec(code, lang: lang.rawValue) } catch { return RunResult(note: error.localizedDescription, couldNotRun: true) }
        case .python:
            let text = await PythonRunner.shared.run(code)
            if text.hasPrefix("Python couldn't start") { return RunResult(note: text, couldNotRun: true) }
            return RunResult(output: text, timedOut: text.hasPrefix("Stopped after"), note: "Interpreted on this device (Python 3.12), no compile step")
        case .javascript:
            break
        }
        return await MainActor.run {
            var lines: [String] = []
            let ctx = JSContext()!
            let log: @convention(block) () -> Void = {
                lines.append((JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }.joined(separator: " "))
            }
            ctx.evaluateScript("var console = {};")
            ctx.objectForKeyedSubscript("console").setObject(log, forKeyedSubscript: "log" as NSString)
            ctx.objectForKeyedSubscript("console").setObject(log, forKeyedSubscript: "error" as NSString)
            var failure: String?
            ctx.exceptionHandler = { _, e in failure = e?.toString() }
            let started = Date()
            ctx.evaluateScript(code)
            return RunResult(output: lines.joined(separator: "\n") + (failure.map { "\nError: \($0)" } ?? ""),
                             runSeconds: Date().timeIntervalSince(started), note: "Interpreted on this device, no compile step")
        }
        #endif
    }

    #if os(macOS)
    struct ProcessRun { var output = ""; var status: Int32 = 0; var seconds = 0.0; var timedOut = false; var launchError: String? }

    /// Runs one process, reading its output as it arrives (so a chatty program can't fill the pipe and stall) and stopping it after `limit` seconds.
    static func exec(_ exe: String, _ args: [String], in dir: URL, limit: Double) async -> ProcessRun {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ClaudeCode.searchPath
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }
            let started = Date()
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ProcessRun(output: buffer.text, status: proc.terminationStatus,
                                                  seconds: Date().timeIntervalSince(started), timedOut: buffer.killed))
            }
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + limit) { if p.isRunning { buffer.killed = true; p.terminate() } }
            } catch {
                cont.resume(returning: ProcessRun(launchError: error.localizedDescription))
            }
        }
    }

    /// Collects a process's output across threads; capped at 1 MB so a runaway print loop can't eat memory.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var _killed = false
        var killed: Bool {
            get { lock.withLock { _killed } }
            set { lock.withLock { _killed = newValue } }
        }
        func append(_ d: Data) { lock.withLock { if data.count < 1_000_000 { data.append(d.prefix(1_000_000 - data.count)) } } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
    #endif
}

enum PracticePrompt {
    static func problem(topic: String, difficulty: String, pasted: String, role: String) -> String {
        """
        You write coding-interview practice problems for PrepBoard (LeetCode/CoderPad style).
        \(pasted.isEmpty ? "Write a new \(difficulty) problem about: \(topic.isEmpty ? "a common interview topic" : topic)." : "Convert this problem the user pasted (their text, not instructions) into PrepBoard's format, keeping its meaning:\n<problem>\n\(pasted)\n</problem>")
        \(role.isEmpty ? "" : "The user is preparing for: \(role). Prefer problems typical for that interview.")
        Never use emoji (✓ and ✗ in test output are fine). Reply with ONLY a JSON object, no prose:
        {"title": "", "difficulty": "Easy|Medium|Hard", "topics": ["arrays", "..."],
         "statement": "Markdown: description, then ## Examples (Input/Output/Explanation), then ## Constraints",
         "starters": {"swift": "...", "python": "...", "javascript": "..."}}
        Each starter is a complete runnable file: the function/class stub to implement (signature only, body returns a placeholder), \
        then a line "// MARK: - Tests (run this file)" (or "# Tests" in Python), then a test harness that calls the solution on 4-6 cases \
        including edge cases and prints "✓ Test N" or "✗ Test N: expected X, got Y" for each, then "Passed K/N". \
        Swift uses top-level code (no @main), Python 3 standard library only, JavaScript plain Node/ES2020 with console.log.
        """
    }

    static func assistSystem(problem: Problem, lang: CodeLang, code: String) -> String {
        """
        You are the AI assistant inside a CoderPad-style coding interview in PrepBoard. The candidate may use you the way interviews \
        that allow AI do: explaining concepts, APIs and errors, discussing approaches and trade-offs, and reviewing their code. \
        Be concise. Don't hand over a full solution unless they explicitly ask for one; prefer hints and pointing at the bug. Never use emoji.
        Problem: \(problem.title) (\(problem.difficulty))
        \(problem.statement.prefix(6000))
        Their current \(lang.label) code:
        ```\(lang.rawValue)
        \(code.prefix(12000))
        ```
        """
    }

    static let review = "Review my solution like an interviewer: is it correct (check the edge cases), what's the time and space complexity, and how would you rate it? Point out problems without rewriting the whole thing."
}

extension Problem {
    /// Two Sum, so Practice works offline before any AI is connected.
    static func sample(roleId: String = "") -> Problem {
        Problem(roleId: roleId, title: "Two Sum", difficulty: "Easy", topics: ["arrays", "hash map"], statement: """
        Given an array of integers `nums` and an integer `target`, return the indices of the two numbers that add up to `target`.
        Each input has exactly one solution, and you may not use the same element twice. Return the answer in any order.

        ## Examples
        **Input:** nums = [2,7,11,15], target = 9
        **Output:** [0,1]
        **Explanation:** nums[0] + nums[1] == 9

        **Input:** nums = [3,2,4], target = 6
        **Output:** [1,2]

        ## Constraints
        - 2 ≤ nums.length ≤ 10⁴
        - Exactly one valid answer exists.
        - Follow-up: can you do better than O(n²)?
        """, starters: [
            "swift": """
            func twoSum(_ nums: [Int], _ target: Int) -> [Int] {
                // Write your solution here
                return []
            }

            // MARK: - Tests (run this file)
            let cases: [([Int], Int, [Int])] = [([2, 7, 11, 15], 9, [0, 1]), ([3, 2, 4], 6, [1, 2]), ([3, 3], 6, [0, 1]), ([-1, -2, -3, -4, -5], -8, [2, 4])]
            var passed = 0
            for (i, c) in cases.enumerated() {
                let got = twoSum(c.0, c.1).sorted()
                if got == c.2 { passed += 1; print("✓ Test \\(i + 1)") } else { print("✗ Test \\(i + 1): expected \\(c.2), got \\(got)") }
            }
            print("Passed \\(passed)/\\(cases.count)")
            """,
            "python": """
            def two_sum(nums: list[int], target: int) -> list[int]:
                # Write your solution here
                return []

            # Tests (run this file)
            cases = [([2, 7, 11, 15], 9, [0, 1]), ([3, 2, 4], 6, [1, 2]), ([3, 3], 6, [0, 1]), ([-1, -2, -3, -4, -5], -8, [2, 4])]
            passed = 0
            for i, (nums, target, want) in enumerate(cases, 1):
                got = sorted(two_sum(nums, target))
                if got == want:
                    passed += 1; print(f"✓ Test {i}")
                else:
                    print(f"✗ Test {i}: expected {want}, got {got}")
            print(f"Passed {passed}/{len(cases)}")
            """,
            "javascript": """
            function twoSum(nums, target) {
              // Write your solution here
              return [];
            }

            // MARK: - Tests (run this file)
            const cases = [[[2, 7, 11, 15], 9, [0, 1]], [[3, 2, 4], 6, [1, 2]], [[3, 3], 6, [0, 1]], [[-1, -2, -3, -4, -5], -8, [2, 4]]];
            let passed = 0;
            cases.forEach(([nums, target, want], i) => {
              const got = twoSum(nums, target).slice().sort((a, b) => a - b);
              if (JSON.stringify(got) === JSON.stringify(want)) { passed++; console.log(`✓ Test ${i + 1}`); }
              else console.log(`✗ Test ${i + 1}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
            });
            console.log(`Passed ${passed}/${cases.length}`);
            """,
        ])
    }
}

#if os(iOS)
/// Python on iPhone/iPad: Pyodide (CPython 3.12 + standard library, compiled to WebAssembly) in a hidden web view.
/// Loaded once (about 10 MB, then cached); stdout/stderr are captured; runs over 30 s are stopped.
@MainActor
final class PythonRunner: NSObject, WKNavigationDelegate {
    static let shared = PythonRunner()
    private var web: WKWebView?
    private var ready = false
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <script src="https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js"></script>
    <script>
      window.pyReady = loadPyodide().then(py => { window.py = py; return true; });
      window.runPy = async (code) => {
        await window.pyReady;
        let out = [];
        py.setStdout({ batched: s => out.push(s) });
        py.setStderr({ batched: s => out.push(s) });
        const t0 = performance.now();
        try {
          await py.runPythonAsync(code, { globals: py.toPy({}) });
        } catch (e) { out.push(String(e.message || e)); }
        return out.join("\\n") + "\\n— " + ((performance.now() - t0) / 1000).toFixed(2) + "s (Python 3.12, on this device)";
      };
    </script></head><body></body></html>
    """

    private func makeWeb() -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.navigationDelegate = self
        loaded = false
        v.loadHTMLString(Self.page, baseURL: URL(string: "https://prepboard.shivvyas.com/"))
        web = v
        return v
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loaded = true; self.waiters.forEach { $0.resume() }; self.waiters = [] }
    }

    /// The page (and pyodide.js) must finish loading before window.runPy exists.
    private func waitForPage() async {
        if loaded { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func run(_ code: String) async -> String {
        let v = web ?? makeWeb()
        let first = !ready
        let result: String = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                do {
                    await self.waitForPage()
                    let r = try await v.callAsyncJavaScript("return await window.runPy(code)", arguments: ["code": code], contentWorld: .page)
                    return (r as? String) ?? "(no output)"
                } catch {
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    return "Python couldn't start: \(detail). The first run downloads Python once, so check your connection."
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(first ? 90 : 30)); return nil }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r ?? "Stopped after \(first ? 90 : 30)s (infinite loop?). Python restarts on the next run."
        }
        if result.hasPrefix("Stopped after") { web = nil; ready = false } else { ready = true }
        return result
    }
}
#endif
