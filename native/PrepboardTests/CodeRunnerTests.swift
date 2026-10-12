import XCTest
@testable import Prepboard

/// Runs real compilers and interpreters on this Mac.
@MainActor
final class CodeRunnerTests: XCTestCase {
    func testSwiftAcceptedShowsCompilerAndTests() async {
        let r = await CodeRunner.run("print(\"hi\")\nprint(\"✓ Test 1\")\nprint(\"Passed 1/1\")", lang: .swift)
        XCTAssertEqual(r.verdict, .accepted, r.text)
        XCTAssertNotNil(r.compiler)
        XCTAssertNotNil(r.compileSeconds)
        XCTAssertEqual(r.programOutput, "hi")
    }

    func testSwiftCompileErrorDoesNotRun() async {
        let r = await CodeRunner.run("let a = 1\nprint(b)", lang: .swift)
        XCTAssertEqual(r.verdict, .compileError, r.text)
        XCTAssertNil(r.exitCode)
        XCTAssertEqual(r.diagnostics.first?.line, 2)
        XCTAssertEqual(r.diagnostics.first?.severity, .error)
    }

    func testSwiftWarningStillRuns() async {
        let r = await CodeRunner.run("func f() { var unused = 1 }\nf()\nprint(\"ok\")", lang: .swift)
        XCTAssertEqual(r.verdict, .finished, r.text)
        XCTAssertTrue(r.diagnostics.contains { $0.severity == .warning }, r.compiler ?? "")
    }

    func testSwiftRuntimeCrash() async {
        let r = await CodeRunner.run("let a = [1]\nprint(a[5])", lang: .swift)
        XCTAssertEqual(r.verdict, .runtimeError, r.text)
    }

    func testPythonSyntaxError() async {
        let r = await CodeRunner.run("def f(:\n    pass", lang: .python)
        XCTAssertEqual(r.verdict, .compileError, r.text)
        XCTAssertEqual(r.diagnostics.first?.line, 1)
    }

    func testPythonWrongAnswer() async {
        let r = await CodeRunner.run("print('✓ Test 1')\nprint('✗ Test 2: expected 1, got 2')\nprint('Passed 1/2')", lang: .python)
        XCTAssertEqual(r.verdict, .wrongAnswer, r.text)
    }

    func testJavaScriptSyntaxErrorWhenNodeInstalled() async throws {
        let r = await CodeRunner.run("if (a {", lang: .javascript)
        if r.verdict == .couldNotRun { throw XCTSkip("Node.js isn't installed") }
        XCTAssertEqual(r.verdict, .compileError, r.text)
        XCTAssertEqual(r.diagnostics.first?.line, 1)
    }

    func testExecStopsAtTimeLimit() async {
        let r = await CodeRunner.exec("/bin/sleep", ["5"], in: FileManager.default.temporaryDirectory, limit: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(r.seconds, 3)
    }

    func testExecHandlesLargeOutput() async {
        let r = await CodeRunner.exec("/usr/bin/env", ["python3", "-c", "print('x' * 200000)"], in: FileManager.default.temporaryDirectory, limit: 10)
        XCTAssertFalse(r.timedOut)
        XCTAssertGreaterThan(r.output.count, 200_000)
    }
}
