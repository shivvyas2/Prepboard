import XCTest
@testable import Prepboard

final class RunResultTests: XCTestCase {
    func testAcceptedWhenAllTestsPass() {
        let r = RunResult(output: "✓ Test 1\n✓ Test 2\nPassed 2/2\n", exitCode: 0)
        XCTAssertEqual(r.verdict, .accepted)
        XCTAssertEqual(r.tests.count, 2)
        XCTAssertTrue(r.tests.allSatisfy(\.passed))
        XCTAssertEqual(r.passed?.0, 2)
        XCTAssertEqual(r.passed?.1, 2)
    }

    func testWrongAnswerParsesExpectedAndGot() {
        let r = RunResult(output: "✓ Test 1\n✗ Test 2: expected [1, 2], got []\nPassed 1/2\n", exitCode: 0)
        XCTAssertEqual(r.verdict, .wrongAnswer)
        XCTAssertEqual(r.tests[1], TestCase(number: 2, passed: false, detail: "expected [1, 2], got []"))
    }

    func testProgramOutputExcludesTestLines() {
        let r = RunResult(output: "debug 42\n✓ Test 1\nPassed 1/1\n", exitCode: 0)
        XCTAssertEqual(r.programOutput, "debug 42")
    }

    func testCompileErrorWins() {
        let log = "main.swift:3:12: error: cannot find 'x' in scope\n    return x\n           ^\nmain.swift:1:5: warning: variable 'y' was never used\n"
        let r = RunResult(compiler: log, compileStatus: 1)
        XCTAssertEqual(r.verdict, .compileError)
        XCTAssertEqual(r.diagnostics, [
            Diagnostic(line: 3, column: 12, severity: .error, message: "cannot find 'x' in scope"),
            Diagnostic(line: 1, column: 5, severity: .warning, message: "variable 'y' was never used"),
        ])
    }

    func testPythonSyntaxErrorDiagnostic() {
        let log = "  File \"/tmp/x/main.py\", line 4\n    return [\n           ^\nSyntaxError: '[' was never closed\n"
        let r = RunResult(compiler: log, compileStatus: 1)
        XCTAssertEqual(r.diagnostics, [Diagnostic(line: 4, column: nil, severity: .error, message: "SyntaxError: '[' was never closed")])
    }

    func testNodeSyntaxErrorDiagnostic() {
        let log = "/tmp/x/main.js:7\n  if (a {\n        ^\n\nSyntaxError: Unexpected token '{'\n    at wrapSafe (node:internal)\n"
        let r = RunResult(compiler: log, compileStatus: 1)
        XCTAssertEqual(r.diagnostics, [Diagnostic(line: 7, column: nil, severity: .error, message: "SyntaxError: Unexpected token '{'")])
    }

    func testRuntimeErrorAndTimeLimit() {
        XCTAssertEqual(RunResult(output: "Fatal error: Index out of range", exitCode: 132).verdict, .runtimeError)
        XCTAssertEqual(RunResult(output: "", exitCode: 15, timedOut: true).verdict, .timeLimit)
        XCTAssertEqual(RunResult(output: "hi", exitCode: 0).verdict, .finished)
        XCTAssertEqual(RunResult(output: "Traceback (most recent call last):\nValueError: x").verdict, .runtimeError)
    }

    func testLegacyTextKeepsEverything() {
        let r = RunResult(compiler: "main.swift:1:5: warning: unused\n", compileStatus: 0, compileSeconds: 1.2,
                          output: "Passed 1/1\n", exitCode: 0, runSeconds: 0.1)
        XCTAssertTrue(r.text.contains("warning: unused"))
        XCTAssertTrue(r.text.contains("Passed 1/1"))
        XCTAssertTrue(r.text.contains("Exit 0"))
    }

    func testCodableRoundTrip() throws {
        let r = RunResult(compiler: "c", compileStatus: 0, compileSeconds: 1, output: "o", exitCode: 0, runSeconds: 2, note: "n")
        let back = try JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }
}
