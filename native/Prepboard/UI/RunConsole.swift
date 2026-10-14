import SwiftUI

/// LeetCode-style result panel under the editor: a verdict, then Tests / Output / Compiler tabs.
struct RunConsole: View {
    let result: RunResult?
    let running: Bool
    let langLabel: String

    enum Tab: Hashable { case tests, output, compiler }
    @State private var tab: Tab = .tests

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PB.s2) {
                verdictPill
                if result != nil {
                    Picker("Console content", selection: $tab) {
                        Text(testsLabel).tag(Tab.tests)
                        Text("Output").tag(Tab.output)
                        Text(compilerLabel).tag(Tab.compiler)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PB.s4).padding(.vertical, PB.s2)
            Divider()
            ScrollView {
                content
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PB.s4)
            }
        }
        .background(PB.surface)
        .onChange(of: result) { _, r in if let r { tab = Self.bestTab(for: r) } }
    }

    /// Open on whatever explains the verdict: compiler errors, the crash output, or the tests.
    static func bestTab(for r: RunResult) -> Tab {
        switch r.verdict {
        case .compileError: .compiler
        case .runtimeError, .timeLimit, .couldNotRun: .output
        case .finished: r.tests.isEmpty ? .output : .tests
        case .accepted, .wrongAnswer: .tests
        }
    }

    private var testsLabel: String {
        guard let p = result?.passed else { return "Tests" }
        return "Tests \(p.0)/\(p.1)"
    }

    private var compilerLabel: String {
        let d = result?.diagnostics ?? []
        let errors = d.filter { $0.severity == .error }.count, warnings = d.filter { $0.severity == .warning }.count
        if errors > 0 { return "Compiler (\(errors))" }
        if warnings > 0 { return "Compiler (\(warnings))" }
        return "Compiler"
    }

    // MARK: verdict

    @ViewBuilder private var verdictPill: some View {
        if running {
            HStack(spacing: PB.s2) {
                ProgressView().controlSize(.small)
                Text("Compiling and running \(langLabel)…").foregroundStyle(PB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .font(.system(size: 13, weight: .medium))
        } else if let r = result {
            VStack(alignment: .leading, spacing: PB.s1) {
                Text(title(r)).font(.system(size: 14, weight: .semibold)).foregroundStyle(color(r))
                    .fixedSize(horizontal: false, vertical: true)
                if !timing(r).isEmpty {
                    Text(timing(r)).font(.system(size: 12)).foregroundStyle(PB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("Console").font(.system(size: 13, weight: .semibold)).foregroundStyle(PB.ink2)
        }
    }

    private func title(_ r: RunResult) -> String {
        switch r.verdict {
        case .accepted: "Accepted"
        case .wrongAnswer: "Wrong Answer"
        case .compileError: "Compile Error"
        case .runtimeError: "Runtime Error" + (r.exitCode.map { " (exit \($0))" } ?? "")
        case .timeLimit: "Time Limit Exceeded"
        case .finished: "Finished"
        case .couldNotRun: "Couldn't Run"
        }
    }

    private func color(_ r: RunResult) -> Color {
        switch r.verdict {
        case .accepted: PB.green
        case .finished: PB.ink
        default: PB.red
        }
    }

    private func timing(_ r: RunResult) -> String {
        var parts: [String] = []
        if let c = r.compileSeconds { parts.append(String(format: "compiled in %.1fs", c)) }
        if let s = r.runSeconds, !r.compileFailed { parts.append(String(format: "ran in %.2fs", s)) }
        return parts.joined(separator: " · ")
    }

    // MARK: tabs

    @ViewBuilder private var content: some View {
        if let r = result {
            switch tab {
            case .tests: tests(r)
            case .output: output(r)
            case .compiler: compiler(r)
            }
        } else {
            Text(running ? "" : "Run your code (⌘↩) to see test results, your program's output and the compiler log here.")
                .foregroundStyle(PB.muted)
        }
    }

    @ViewBuilder private func tests(_ r: RunResult) -> some View {
        if r.compileFailed {
            Text("The code didn't compile, so no tests ran. See the Compiler tab.").foregroundStyle(PB.muted)
        } else if r.tests.isEmpty {
            Text("No test results. The file's test harness prints \"✓ Test N\" lines; see the Output tab.").foregroundStyle(PB.muted)
        } else {
            VStack(alignment: .leading, spacing: PB.s2) {
                ForEach(r.tests, id: \.number) { t in
                    HStack(alignment: .firstTextBaseline, spacing: PB.s2) {
                        Image(systemName: t.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(t.passed ? PB.green : PB.red)
                        VStack(alignment: .leading, spacing: PB.s1) {
                            Text("Test \(t.number)").fontWeight(.semibold)
                            if !t.detail.isEmpty {
                                Text(t.detail).foregroundStyle(PB.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func output(_ r: RunResult) -> some View {
        VStack(alignment: .leading, spacing: PB.s2) {
            if let note = r.note { Text(note).foregroundStyle(PB.muted) }
            if r.timedOut { Text("Stopped after 30s. Is there an infinite loop?").foregroundStyle(PB.red) }
            if r.compileFailed {
                Text("Nothing ran because the code didn't compile.").foregroundStyle(PB.muted)
            } else if !r.couldNotRun {
                let out = r.programOutput
                Text(out.isEmpty ? "(no output besides the tests)" : out).foregroundStyle(out.isEmpty ? PB.muted : PB.ink)
                if let code = r.exitCode { Text("Exit code \(code)").foregroundStyle(PB.muted) }
            }
        }
    }

    @ViewBuilder private func compiler(_ r: RunResult) -> some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            if let log = r.compiler {
                if !r.diagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: PB.s1) {
                        ForEach(Array(r.diagnostics.enumerated()), id: \.offset) { _, d in
                            VStack(alignment: .leading, spacing: PB.s1) {
                                HStack(spacing: PB.s2) {
                                    Text(d.severity.rawValue).fontWeight(.semibold)
                                        .foregroundStyle(d.severity == .error ? PB.red : d.severity == .warning ? PB.sunInk : PB.muted)
                                    Text("line \(d.line)" + (d.column.map { ":\($0)" } ?? "")).foregroundStyle(PB.cobalt)
                                }
                                Text(d.message).foregroundStyle(PB.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider()
                }
                let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(trimmed.isEmpty ? "Compiled with no errors or warnings." : trimmed)
                    .foregroundStyle(trimmed.isEmpty ? PB.green : PB.ink2)
            } else {
                Text(r.note ?? "No compile step for this run.").foregroundStyle(PB.muted)
            }
        }
    }
}
