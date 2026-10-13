import Network
import WebKit
import XCTest
@testable import Prepboard

/// MCP.handle, the HTTP gate, and the WKWebView scripts on a local page. The web view tests run on the main actor
/// (async XCTest methods on a @MainActor class) and await the browser's own load/JS continuations.
@MainActor
final class BrowserServerTests: XCTestCase {
    // MARK: MCP.handle

    private func send(_ obj: Any, call: @escaping (String, [String: Any]) async throws -> MCPContent = { _, _ in .text("ok") }) async -> (status: Int, json: [String: Any]?) {
        let body = (obj as? Data) ?? (try! JSONSerialization.data(withJSONObject: obj))
        let (status, data) = await MCP.handle(body, tools: BrowserServer.tools, call: call)
        return (status, data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:], id: Any = 1) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    func testInitializeNegotiatesVersion() async {
        var r = await send(rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.0"]]))
        XCTAssertEqual(r.status, 200)
        var result = r.json?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "prepboard")
        XCTAssertEqual(r.json?["id"] as? Int, 1)
        XCTAssertEqual(r.json?["jsonrpc"] as? String, "2.0")

        r = await send(rpc("initialize", ["protocolVersion": "1999-01-01"], id: "abc"))
        result = r.json?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual(r.json?["id"] as? String, "abc")
    }

    func testNotificationIs202WithoutBody() async {
        let (status, data) = await MCP.handle(try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]),
                                              tools: BrowserServer.tools) { _, _ in .text("") }
        XCTAssertEqual(status, 202)
        XCTAssertNil(data)
    }

    func testPing() async {
        let r = await send(rpc("ping"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json?["result"] as? [String: Any])?.isEmpty, true)
    }

    func testToolsListHasEveryToolWithValidSchema() async {
        let r = await send(rpc("tools/list"))
        let tools = (r.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.map { $0["name"] as? String }, BrowserServer.tools.map { $0.name })
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["navigate", "back", "wait", "page_text", "read_page", "click", "type", "select", "press", "scroll", "upload_file", "screenshot"])
        for t in tools {
            let schema = t["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(t["name"] ?? "")")
            XCTAssertNotNil(schema?["properties"] as? [String: Any], "\(t["name"] ?? "")")
            XCTAssertNotNil(schema?["required"] as? [String], "\(t["name"] ?? "")")
            XCTAssertFalse((t["description"] as? String ?? "").isEmpty)
            for req in schema?["required"] as? [String] ?? [] {
                XCTAssertNotNil((schema?["properties"] as? [String: Any])?[req], "required \(req) is a property of \(t["name"] ?? "")")
            }
        }
        XCTAssertEqual(BrowserServer().allowedTools.split(separator: " ").first, "mcp__prepboard__navigate")
    }

    func testToolsCallRoutesAndWrapsContent() async {
        var seen: (String, [String: Any])?
        var r = await send(rpc("tools/call", ["name": "click", "arguments": ["ref": "r3"]])) { name, args in
            seen = (name, args)
            return .text("Clicked Easy Apply")
        }
        XCTAssertEqual(seen?.0, "click")
        XCTAssertEqual(seen?.1["ref"] as? String, "r3")
        var result = r.json?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        var content = (result?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text")
        XCTAssertEqual(content?["text"] as? String, "Clicked Easy Apply")

        r = await send(rpc("tools/call", ["name": "screenshot"])) { _, _ in .image(Data([1, 2, 3]), mime: "image/png") }
        content = ((r.json?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "image")
        XCTAssertEqual(content?["mimeType"] as? String, "image/png")
        XCTAssertEqual(content?["data"] as? String, Data([1, 2, 3]).base64EncodedString())

        r = await send(rpc("tools/call", ["name": "click", "arguments": ["ref": "r9"]])) { _, _ in throw BrowserError.notFound(ref: "r9") }
        XCTAssertEqual(r.status, 200)
        result = r.json?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertTrue(((result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").contains("r9"))

        r = await send(rpc("tools/call", ["arguments": [:]]))
        XCTAssertEqual((r.json?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testUnknownMethodAndMalformedJSON() async {
        var r = await send(rpc("resources/list", id: 7))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(r.json?["id"] as? Int, 7)

        r = await send(Data("{not json".utf8))
        XCTAssertEqual((r.json?["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(r.json?["id"] is NSNull)

        r = await send([rpc("ping"), rpc("ping")])
        XCTAssertEqual((r.json?["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    /// -1e999 parses to an NSNumber holding -inf; echoing it raised an Objective-C exception that took the app down.
    func testNonFiniteIdIsEchoedAsNull() async {
        let r = await send(Data(#"{"jsonrpc":"2.0","id":-1e999,"method":"ping"}"#.utf8))
        XCTAssertEqual(r.status, 200)
        XCTAssertNotNil(r.json?["result"])
        XCTAssertTrue(r.json?["id"] is NSNull, "\(String(describing: r.json))")
        XCTAssertTrue(MCP.requestID(-Double.infinity) is NSNull)
        XCTAssertTrue(MCP.requestID(Double.nan) is NSNull)
        XCTAssertTrue(MCP.requestID([1]) is NSNull)
        XCTAssertTrue(MCP.requestID(nil) is NSNull)
        XCTAssertEqual(MCP.requestID(7) as? Int, 7)
        XCTAssertEqual(MCP.requestID("abc") as? String, "abc")
    }

    // MARK: HTTP gate

    func testBearerAndOriginGate() {
        let token = "0123456789abcdef0123456789abcdef"
        let ok = ["authorization": "Bearer \(token)", "accept": "application/json, text/event-stream", "mcp-session-id": "x", "mcp-protocol-version": "2025-06-18"]
        XCTAssertNil(BrowserServer.gate(method: "POST", path: "/mcp", headers: ok, token: token))
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: ["authorization": "bearer \(token)"], token: token), nil)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: [:], token: token), 401)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: ["authorization": "Bearer " + String(token.dropLast()) + "0"], token: token), 401)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: ["authorization": "Bearer short"], token: token), 401)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: ok.merging(["origin": "http://127.0.0.1"]) { $1 }, token: token), 403)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: ["origin": "null"], token: token), 403)   // Origin wins even without a token
        XCTAssertEqual(BrowserServer.gate(method: "GET", path: "/mcp", headers: ok, token: token), 405)
        XCTAssertEqual(BrowserServer.gate(method: "DELETE", path: "/mcp", headers: ok, token: token), 405)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/", headers: ok, token: token), 404)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/run", headers: ok, token: token), 404)
        XCTAssertTrue(BrowserServer.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(BrowserServer.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(BrowserServer.constantTimeEqual("abc", "ab"))
    }

    func testRequestParsing() {
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 7\r\nAuthorization: Bearer t\r\n\r\n{\"a\":".utf8)
        XCTAssertNil(BrowserServer.parse(raw))   // body incomplete
        let req = BrowserServer.parse(raw + Data("1}".utf8))
        XCTAssertEqual(req?.method, "POST"); XCTAssertEqual(req?.path, "/mcp")
        XCTAssertEqual(req?.headers["authorization"], "Bearer t")
        XCTAssertEqual(req.map { String(decoding: $0.body, as: UTF8.self) }, "{\"a\":1}")
        // A bad Content-Length is a complete, empty request (the gate refuses it), never a trap or an endless wait.
        for bad in ["-1", "99999999999999999999", "2000001", "abc"] {
            let r = BrowserServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: \(bad)\r\n\r\n{}".utf8))
            XCTAssertEqual(r?.method, "", bad)
            XCTAssertEqual(r?.body.count, 0, bad)
            XCTAssertEqual(BrowserServer.gate(method: r!.method, path: r!.path, headers: r!.headers, token: "t"), 401, bad)
        }
    }

    func testUploadPathGate() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(BrowserServer.uploadAllowed("\(home)/Documents/Resume.pdf"))
        XCTAssertTrue(BrowserServer.uploadAllowed("~/Documents/Resume.DOCX"))
        XCTAssertTrue(BrowserServer.uploadAllowed("\(home)/x.txt") && BrowserServer.uploadAllowed("\(home)/x.png"))
        XCTAssertFalse(BrowserServer.uploadAllowed("\(home)/Documents/notes.md"))
        XCTAssertFalse(BrowserServer.uploadAllowed("/etc/passwd"))
        XCTAssertFalse(BrowserServer.uploadAllowed("\(home)/../../etc/x.txt"))
        XCTAssertFalse(BrowserServer.uploadAllowed("Resume.pdf"))
    }

    func testServerConfigAndFlags() {
        let s = BrowserServer()
        XCTAssertEqual(s.token.count, 32)
        XCTAssertTrue(s.token.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(s.token, BrowserServer().token)
        let cfg = try? JSONSerialization.jsonObject(with: Data(s.mcpConfigJSON.utf8)) as? [String: Any]
        let server = (cfg?["mcpServers"] as? [String: Any])?["prepboard"] as? [String: Any]
        XCTAssertEqual(server?["type"] as? String, "http")
        XCTAssertEqual((server?["headers"] as? [String: String])?["Authorization"], "Bearer \(s.token)")
        let flags = s.claudeFlags(extraTools: "Read")
        XCTAssertTrue(flags.hasPrefix("--mcp-config '"))
        XCTAssertTrue(flags.contains("--strict-mcp-config --allowedTools mcp__prepboard__navigate"))
        XCTAssertTrue(flags.hasSuffix("mcp__prepboard__screenshot Read"))
        for t in ["upload_file", "type", "select", "press"] { XCTAssertTrue(flags.contains("mcp__prepboard__\(t)"), t) }
        let path = flags.split(separator: "'")[1]
        XCTAssertEqual(try? String(contentsOfFile: String(path), encoding: .utf8), s.mcpConfigJSON)
        // The token file is 0600 from the moment it exists; a second call rewrites it in place with the same mode.
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: String(path)))?[.posixPermissions] as? Int, 0o600)
        _ = s.claudeFlags(extraTools: "")
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: String(path)))?[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try? String(contentsOfFile: String(path), encoding: .utf8), s.mcpConfigJSON)

        // Read-only runs (Discover, the sync) get no form or upload tools; the sync also keeps the connectors (no strict mode).
        let readOnly = s.claudeFlags(extraTools: "", readOnly: true)
        for t in ["upload_file", "type", "select", "press"] { XCTAssertFalse(readOnly.contains("mcp__prepboard__\(t)"), t) }
        for t in ["navigate", "back", "wait", "page_text", "read_page", "click", "scroll", "screenshot"] { XCTAssertTrue(readOnly.contains("mcp__prepboard__\(t)"), t) }
        XCTAssertTrue(readOnly.contains("--strict-mcp-config"))
        let sync = s.claudeFlags(extraTools: JobSync.connectorTools, readOnly: true, strict: false)
        XCTAssertFalse(sync.contains("--strict-mcp-config"), sync)
        XCTAssertTrue(sync.hasSuffix("mcp__prepboard__screenshot mcp__claude_ai_Gmail mcp__claude_ai_Google_Calendar"), sync)
        XCTAssertFalse(sync.contains("upload_file") || sync.contains("mcp__prepboard__type"), sync)
        XCTAssertTrue(sync.hasPrefix("--mcp-config '\(path)' --allowedTools "), sync)
        s.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(path)))
    }

    func testHTTPRoundTrip() async throws {
        let browser = HuntBrowser()
        let server = BrowserServer()
        try server.start(browser: browser)
        defer { server.stop() }
        let up = await server.ready(timeout: 5)
        XCTAssertTrue(up && server.isRunning)
        guard let port = server.port else { return XCTFail("no port") }

        func post(_ body: String, token: String? = nil, method: String = "POST") async throws -> (Int, [String: Any]?) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            req.httpMethod = method
            req.httpBody = Data(body.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as! HTTPURLResponse).statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        var (status, json) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, token: server.token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((json?["result"] as? [String: Any])?.isEmpty, true)
        (status, json) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, token: server.token)
        XCTAssertEqual(((json?["result"] as? [String: Any])?["tools"] as? [Any])?.count, BrowserServer.tools.count)
        (status, _) = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, token: server.token)
        XCTAssertEqual(status, 202)
        (status, _) = try await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: "wrong")
        XCTAssertEqual(status, 401)
        (status, _) = try await post("", token: server.token, method: "GET")
        XCTAssertEqual(status, 405)
        // A tool call reaches the browser: no page is open yet, so the error comes back as isError, not an HTTP error.
        (status, json) = try await post(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_page","arguments":{}}}"#, token: server.token)
        XCTAssertEqual(status, 200)
        let result = json?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertTrue(((result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").contains("navigate"))
    }

    // MARK: Pacing

    func testNavigationPacingAndCap() async throws {
        let s = BrowserServer()
        s.minNavigationGap = 0.3
        s.navigationCap = 3
        let t0 = Date.now
        try await s.pace()
        try await s.pace()
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(t0), 0.3)
        XCTAssertEqual(s.navigations, 2)
        try await s.pace()
        do { try await s.pace(); XCTFail("cap should throw") } catch let e as BrowserError {
            if case .blocked(let m) = e { XCTAssertEqual(m, "Navigation cap reached for this run") } else { XCTFail("\(e)") }
        }
        XCTAssertEqual(s.navigations, 3)
        s.reset()
        XCTAssertEqual(s.navigations, 0)
        try await s.pace()
        XCTAssertEqual(s.navigations, 1)
    }

    /// Two pace() calls in flight at once take separate slots: the second finishes a full gap after the first.
    func testConcurrentPaceCallsTakeSeparateSlots() async throws {
        let s = BrowserServer()
        s.minNavigationGap = 0.3
        s.navigationCap = 2
        async let a: Date = { try await s.pace(); return .now }()
        async let b: Date = { try await s.pace(); return .now }()
        let (ta, tb) = try await (a, b)
        XCTAssertGreaterThanOrEqual(abs(tb.timeIntervalSince(ta)), 0.25, "\(ta) \(tb)")
        XCTAssertEqual(s.navigations, 2)
        // The cap counts reservations, so a third concurrent call is refused even while the others sleep.
        do { try await s.pace(); XCTFail("cap should throw") } catch let e as BrowserError {
            if case .blocked = e {} else { XCTFail("\(e)") }
        }
    }

    // MARK: WKWebView scripts (off-window)

    static let page = """
    <!doctype html><html><head><title>Form test</title><style>.hidden{display:none}</style></head><body>
    <h1>Apply here</h1>
    <p>Some intro text about the <b>role</b>.</p>
    <div class="hidden">invisible text <button>Hidden button</button></div>
    <form id="f" onsubmit="event.preventDefault(); document.getElementById('out').textContent='submitted:' + document.getElementById('email').value">
      <label for="email">Email</label><input id="email" type="text" value="">
      <input type="text" aria-label="Phone" placeholder="555">
      <label for="country">Country</label>
      <select id="country"><option value="us">United States</option><option value="ca">Canada</option></select>
      <label for="resume">Resume/CV</label><input id="resume" type="file" onchange="document.getElementById('out').textContent='file:' + (this.files[0] ? this.files[0].name : 'none')">
      <label for="cv2">Cover letter</label><input id="cv2" type="file" style="display:none">
      <input type="checkbox" id="agree"><label for="agree">I agree</label>
      <button type="button" id="btn" onclick="document.getElementById('out').textContent='clicked'">Easy Apply</button>
      <div role="button" aria-label="Icon only"><svg width="10" height="10"></svg></div>
    </form>
    <a href="https://example.com/job/1">Senior iOS Engineer</a>
    <span id="out">idle</span>
    </body></html>
    """

    /// XCTAssert takes sync autoclosures, so awaited values go through these.
    private func expectEqual<T: Equatable>(_ actual: @autoclosure () async throws -> T?, _ expected: T?, _ message: String = "",
                                           file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let a = try await actual()
        XCTAssertEqual(a, expected, message, file: file, line: line)
    }

    private func expectTrue(_ actual: @autoclosure () async throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let a = try await actual()
        XCTAssertTrue(a, message, file: file, line: line)
    }

    private func eval(_ browser: HuntBrowser, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            browser.webView.evaluateJavaScript(js) { v, e in e.map { cont.resume(throwing: $0) } ?? cont.resume(returning: v) }
        }
    }

    /// The ref on the first line whose text (after the ref) starts with `prefix`.
    private func ref(_ lines: String, _ prefix: String) -> String? {
        for line in lines.split(separator: "\n") {
            guard let sp = line.firstIndex(of: " ") else { continue }
            if line[line.index(after: sp)...].hasPrefix(prefix) { return String(line[..<sp]) }
        }
        return nil
    }

    private func loaded() async throws -> HuntBrowser {
        let b = HuntBrowser()
        try await b.loadHTML(Self.page)
        return b
    }

    func testReadPageAssignsRefsAndLabels() async throws {
        let b = try await loaded()
        let all = try await b.readPage(interactiveOnly: false)
        XCTAssertNotNil(ref(all, "heading \"Apply here\""), all)
        XCTAssertNotNil(ref(all, "text \"Some intro text about the role.\""), all)
        XCTAssertNotNil(ref(all, "textbox \"Email\" = \"\""), all)
        XCTAssertNotNil(ref(all, "textbox \"Phone\" = \"\""), all)
        XCTAssertNotNil(ref(all, "combobox \"Country\" = \"United States\""), all)
        XCTAssertNotNil(ref(all, "file \"Resume/CV\""), all)
        XCTAssertNotNil(ref(all, "file \"Cover letter\""), "a hidden file input is listed through its label: \(all)")
        XCTAssertFalse(all.contains("text \"Cover letter\""), all)
        try await expectEqual(try await eval(b, "document.getElementById('cv2').getAttribute('data-pb-ref')") as? String, ref(all, "file \"Cover letter\""))
        XCTAssertNotNil(ref(all, "checkbox \"I agree\" [ ]"), all)
        XCTAssertNotNil(ref(all, "button \"Easy Apply\""), all)
        XCTAssertNotNil(ref(all, "button \"Icon only\""), all)
        XCTAssertNotNil(ref(all, "link \"Senior iOS Engineer\" → https://example.com/job/1"), all)
        XCTAssertNotNil(ref(all, "text \"idle\""), all)
        XCTAssertFalse(all.contains("Hidden button") || all.contains("invisible text"), all)
        XCTAssertFalse(all.contains("text \"Email\""), "label text is not repeated as a text line")
        XCTAssertTrue(all.split(separator: "\n").allSatisfy { $0.hasPrefix("r") }, all)

        let interactive = try await b.readPage(interactiveOnly: true)
        XCTAssertFalse(interactive.contains(" text "), interactive)
        XCTAssertNotNil(ref(interactive, "heading"), interactive)
        // Refs are stable across calls.
        XCTAssertEqual(ref(all, "button \"Easy Apply\""), ref(interactive, "button \"Easy Apply\""))
        try await expectEqual(try await eval(b, "document.getElementById('btn').getAttribute('data-pb-ref')") as? String, ref(all, "button \"Easy Apply\""))

        let text = try await b.pageText()
        XCTAssertTrue(text.contains("Apply here") && text.contains("Easy Apply") && !text.contains("invisible"), text)
        try await expectTrue(try await b.readPage(interactiveOnly: false, maxChars: 40).hasSuffix("(truncated at 40 characters)"))
    }

    func testTypeSelectClickAndPressRoundTrips() async throws {
        let b = try await loaded()
        let lines = try await b.readPage(interactiveOnly: true)
        let email = try XCTUnwrap(ref(lines, "textbox \"Email\""))
        try await b.type(ref: email, text: "shiv@example.com", clear: true, submit: false)
        try await expectEqual(try await eval(b, "document.getElementById('email').value") as? String, "shiv@example.com")
        XCTAssertEqual(b.lastAction, "Typed into Email")
        try await b.type(ref: email, text: "x", clear: false, submit: false)
        try await expectEqual(try await eval(b, "document.getElementById('email').value") as? String, "shiv@example.comx")
        try await expectTrue(try await b.readPage(interactiveOnly: true).contains("textbox \"Email\" = \"shiv@example.comx\""))

        let country = try XCTUnwrap(ref(lines, "combobox \"Country\""))
        try await b.select(ref: country, value: "Canada")
        try await expectEqual(try await eval(b, "document.getElementById('country').value") as? String, "ca")
        try await b.select(ref: country, value: "us")
        try await expectTrue(try await b.readPage(interactiveOnly: true).contains("combobox \"Country\" = \"United States\""))
        do { try await b.select(ref: country, value: "Mars"); XCTFail("should throw") } catch let e as BrowserError {
            XCTAssertTrue(e.localizedDescription.contains("Mars"), e.localizedDescription)
        }

        let button = try XCTUnwrap(ref(lines, "button \"Easy Apply\""))
        try await b.click(ref: button)   // off-window: JavaScript click path
        try await expectEqual(try await eval(b, "document.getElementById('out').textContent") as? String, "clicked")
        XCTAssertEqual(b.lastAction, "Clicked Easy Apply")
        let agree = try XCTUnwrap(ref(lines, "checkbox \"I agree\""))
        try await b.click(ref: agree)
        try await expectTrue(try await b.readPage(interactiveOnly: true).contains("checkbox \"I agree\" [x]"))

        // Enter in a form field submits the form (synthetic keydown + requestSubmit).
        try await b.type(ref: email, text: "a@b.c", clear: true, submit: true)
        try await expectEqual(try await eval(b, "document.getElementById('out').textContent") as? String, "submitted:a@b.c")
        try await b.press(key: "Tab")
        try await expectEqual(try await eval(b, "document.activeElement.getAttribute('aria-label')") as? String, "Phone")

        try await b.scroll(direction: "down", ref: nil)
        XCTAssertEqual(b.lastAction, "Scrolled down")
        try await b.scroll(direction: nil, ref: button)
        XCTAssertEqual(b.lastAction, "Scrolled to Easy Apply")
        XCTAssertEqual(b.actionLog.count, 10)
    }

    func testMissingRefAndNoPage() async throws {
        let b = try await loaded()
        do { try await b.click(ref: "r999"); XCTFail("should throw") } catch let e as BrowserError {
            if case .notFound(let r) = e { XCTAssertEqual(r, "r999") } else { XCTFail("\(e)") }
        }
        let fresh = HuntBrowser()
        do { try await fresh.readPage(interactiveOnly: true); XCTFail("should throw") } catch let e as BrowserError {
            if case .noPage = e {} else { XCTFail("\(e)") }
        }
        do { try await fresh.navigate(URL(string: "file:///etc/hosts")!); XCTFail("should throw") } catch let e as BrowserError {
            if case .blocked = e {} else { XCTFail("\(e)") }
        }
    }

    /// uploadFile off-window (WebKit still answers a scripted click on a file input with the open panel), plus the DataTransfer
    /// injection on its own, which is the fallback for pages that never open a panel.
    func testUploadFileViaDataTransfer() async throws {
        let b = try await loaded()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pb-upload-\(UUID().uuidString.prefix(6)).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = try await b.readPage(interactiveOnly: true)
        // Through the label, which is not the input itself.
        let label = try XCTUnwrap(ref(lines, "file \"Resume/CV\""))
        try await b.uploadFile(ref: label, path: file.path)
        try await expectEqual(try await eval(b, "document.getElementById('resume').files.length") as? Int, 1)
        try await expectEqual(try await eval(b, "document.getElementById('out').textContent") as? String, "file:\(file.lastPathComponent)")
        XCTAssertEqual(b.lastAction, "Uploaded \(file.lastPathComponent)")
        XCTAssertNil(b.pendingUpload)
        // Through a sibling element: the button in the same form finds the first file input in the form.
        let button = try XCTUnwrap(ref(lines, "button \"Easy Apply\""))
        try await b.uploadFile(ref: button, path: file.path)
        try await expectEqual(try await eval(b, "document.getElementById('resume').files[0].name") as? String, file.lastPathComponent)
        // A hidden file input (styled through its label) takes the file by its own ref.
        let hidden = try XCTUnwrap(ref(lines, "file \"Cover letter\""))
        try await b.uploadFile(ref: hidden, path: file.path)
        try await expectEqual(try await eval(b, "document.getElementById('cv2').files.length") as? Int, 1)
        // The injection alone: a DataTransfer-built FileList lands on the input and fires change.
        _ = try await eval(b, "document.getElementById('cv2').value = ''; document.getElementById('cv2').onchange = () => { window.__cvChanged = true }; 0")
        _ = try await b.run(BrowserScripts.setFiles, hidden, "letter.txt", "text/plain", Data("hi".utf8).base64EncodedString())
        try await expectEqual(try await b.run(BrowserScripts.filesCount, hidden) as? Int, 1)
        try await expectEqual(try await eval(b, "document.getElementById('cv2').files[0].name + ':' + window.__cvChanged") as? String, "letter.txt:true")
        do { try await b.uploadFile(ref: label, path: "/nonexistent/x.pdf"); XCTFail("should throw") } catch let e as BrowserError {
            XCTAssertTrue(e.localizedDescription.contains("No readable file"))
        }
    }

    /// In a window the trusted click opens the page's file panel, which `runOpenPanelWith` answers with `pendingUpload`.
    func testUploadFileViaOpenPanelInWindow() async throws {
        let b = try await loaded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = b.webView
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pb-panel-\(UUID().uuidString.prefix(6)).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = try await b.readPage(interactiveOnly: true)
        let resume = try XCTUnwrap(ref(lines, "file \"Resume/CV\""))
        try await b.uploadFile(ref: resume, path: file.path)
        try await expectEqual(try await eval(b, "document.getElementById('resume').files.length") as? Int, 1)
        try await expectEqual(try await eval(b, "document.getElementById('out').textContent") as? String, "file:\(file.lastPathComponent)")
        XCTAssertTrue(b.panelRequested, "the real click should go through the open panel, not the DataTransfer fallback")
        XCTAssertNil(b.pendingUpload)
        XCTAssertEqual(b.lastAction, "Uploaded \(file.lastPathComponent)")
    }

    /// takeSnapshot for a web view that is in no window: a PNG, or the documented error.
    func testScreenshotOffWindow() async throws {
        let b = try await loaded()
        do {
            let png = try await b.screenshot()
            XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
            XCTAssertNotNil(NSBitmapImageRep(data: png), "decodable PNG")
            let scaled = BrowserServer.scaledPNG(png, maxWidth: 640)
            XCTAssertLessThanOrEqual(NSBitmapImageRep(data: scaled)?.pixelsWide ?? .max, 640)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Screenshot unavailable"))
        }
    }

    /// With the view in a window, a click is delivered as real (isTrusted) mouse events, not the JS fallback.
    func testRealClickInWindow() async throws {
        let b = try await loaded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = b.webView
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        let lines = try await b.readPage(interactiveOnly: true)
        let button = try XCTUnwrap(ref(lines, "button \"Easy Apply\""))
        try await b.click(ref: button)
        try await expectEqual(try await eval(b, "document.getElementById('out').textContent") as? String, "clicked")
        let trusted = try await eval(b, "window.__pbTrusted") as? Bool
        XCTAssertEqual(trusted, true, "the real NSEvent click should reach the element; a JS fallback click is untrusted")
    }

    // MARK: LinkedIn sign-in

    func testLinkedInClassify() {
        let u = { URL(string: $0)! }
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/feed/")), .signedIn)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://linkedin.com/feed/?trk=x")), .signedIn)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/jobs/collections/recommended/")), .signedIn)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/login")), .noCredentials)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/uas/login?session_redirect=%2Ffeed%2F")), .noCredentials)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/authwall?trk=qf")), .noCredentials)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/signup/cold-join")), .noCredentials)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/")), .noCredentials)   // the public home page
        // A refused password re-renders the form at login-submit: that is "needs a sign-in", not a checkpoint.
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/checkpoint/lg/login-submit")), .noCredentials)
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/checkpoint/challenge/AgF1")), .needsYou(LinkedInSignIn.needsYouMessage))
        XCTAssertEqual(LinkedInSignIn.classify(u("https://www.linkedin.com/checkpoint/rm/sign-in-another-account")), .needsYou(LinkedInSignIn.needsYouMessage))
        if case .needsYou(let m) = LinkedInSignIn.classify(u("https://www.linkedin.com/challenge/verify")) {
            XCTAssertTrue(m.contains("verification code") && m.contains("Browser card"), m)
        } else { XCTFail("challenge should need the user") }
        XCTAssertEqual(LinkedInSignIn.classify(u("https://example.com/feed/")), .failed("Not on LinkedIn"))
        XCTAssertEqual(LinkedInSignIn.classify(u("https://notlinkedin.com/feed/")), .failed("Not on LinkedIn"))
        XCTAssertEqual(LinkedInSignIn.classify(nil), .failed("Not on LinkedIn"))
        XCTAssertNil(LinkedInSignIn.stopMessage(.signedIn))
        XCTAssertEqual(LinkedInSignIn.stopMessage(.noCredentials), LinkedInSignIn.signInMessage)
        XCTAssertEqual(LinkedInSignIn.stopMessage(.failed("x")), "x")
    }

    static let loginPage = """
    <!doctype html><html><head><title>Sign in</title><style>.hidden{display:none}</style></head><body>
    <form class="login__form" action="/checkpoint/lg/login-submit" method="post"
          onsubmit="event.preventDefault(); window.__submitted = true; document.getElementById('error-for-password').classList.remove('hidden')">
      <label for="username">Email or phone</label><input id="username" name="session_key" type="text">
      <label for="password">Password</label><input id="password" name="session_password" type="password">
      <div id="error-for-username" class="hidden"></div>
      <div id="error-for-password" class="hidden">That's not the right password. Try again or create an account.</div>
      <button type="submit" aria-label="Sign in">Sign in</button>
    </form>
    </body></html>
    """

    func testFillLoginSubmitLoginAndLoginError() async throws {
        let b = HuntBrowser()
        try await b.loadHTML(Self.loginPage)
        _ = try await eval(b, "window.__events = []; for (const id of ['username', 'password']) for (const t of ['input', 'change']) document.getElementById(id).addEventListener(t, () => window.__events.push(id + ':' + t)); 0")
        try await expectEqual(try await b.loginError(), "")   // hidden until the form answers
        try await expectEqual(try await b.run(BrowserScripts.fillLogin, "someone@example.com", "not-a-real-password") as? Bool, true)
        try await expectEqual(try await eval(b, "document.getElementById('username').value") as? String, "someone@example.com")
        try await expectEqual(try await eval(b, "document.getElementById('password').value === 'not-a-real-password'") as? Bool, true)
        try await expectEqual(try await eval(b, "window.__events.join(',')") as? String, "username:input,username:change,password:input,password:change")
        try await expectEqual(try await b.run(BrowserScripts.submitLogin) as? Bool, true)
        try await expectEqual(try await eval(b, "window.__submitted") as? Bool, true)
        try await expectEqual(try await b.loginError(), "That's not the right password. Try again or create an account.")
        // The password never shows up in what the hunt sees of the page, or in the action log.
        let lines = try await b.readPage(interactiveOnly: true)
        XCTAssertTrue(lines.contains("textbox \"Password\" = \"••••\""), lines)
        XCTAssertFalse(lines.contains("not-a-real") || b.actionLog.joined().contains("not-a-real"))

        // No form on the page: nothing is filled or submitted.
        try await b.loadHTML("<html><body><h1>Feed</h1></body></html>")
        try await expectEqual(try await b.run(BrowserScripts.fillLogin, "x@example.com", "y") as? Bool, false)
        try await expectEqual(try await b.run(BrowserScripts.submitLogin) as? Bool, false)
        try await expectEqual(try await b.loginError(), "")
    }

    /// A LinkedIn page that will not load is a load failure, not a missing sign-in: `ensure` must not tell the user to sign in
    /// (and must not try the stored credentials) when the Mac is offline or LinkedIn times out.
    func testLinkedInProbeReportsALoadFailure() async throws {
        let real = LinkedInSignIn.feedURL
        LinkedInSignIn.feedURL = URL(string: "http://127.0.0.1:1/feed/")!
        defer { LinkedInSignIn.feedURL = real }
        let b = try await loaded()
        let probe = await LinkedInSignIn.probe(b)
        guard case .failed(let m) = probe else { return XCTFail("\(probe)") }
        XCTAssertTrue(m.hasPrefix("Could not load LinkedIn: "), m)
        let isSignedIn = await LinkedInSignIn.isSignedIn(b)
        XCTAssertFalse(isSignedIn)
        let ensured = await LinkedInSignIn.ensure(b)
        XCTAssertEqual(ensured, probe)
        XCTAssertEqual(LinkedInSignIn.stopMessage(ensured), m)
        XCTAssertNotEqual(ensured, .noCredentials)
    }

    func testNavigationTimeoutLeavesPage() async throws {
        let b = try await loaded()
        // A real navigation to a non-routable address fails fast with a load error, not a hang.
        do { try await b.navigate(URL(string: "http://127.0.0.1:1/")!); XCTFail("should throw") } catch let e as BrowserError {
            XCTAssertTrue(e.localizedDescription.contains("Could not load") || e.localizedDescription.contains("Timed out"), e.localizedDescription)
        }
    }

    /// A server that accepts and never answers: the load times out (`.timeout`) and leaves the page as it was; a second
    /// navigate while one is pending fails the first with "Replaced by a newer navigation".
    func testNavigationTimeoutAndReplacement() async throws {
        let stall = try NWListener(using: .tcp)
        var held: [NWConnection] = []
        stall.newConnectionHandler = { c in c.start(queue: .main); held.append(c) }
        // The assigned port is only known once the listener is ready (before that `port` reads as 0).
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            stall.stateUpdateHandler = { state in
                switch state {
                case .ready: stall.stateUpdateHandler = nil; cont.resume(returning: stall.port?.rawValue ?? 0)
                case .failed(let e): stall.stateUpdateHandler = nil; cont.resume(throwing: e)
                default: break
                }
            }
            stall.start(queue: .main)
        }
        defer { stall.cancel(); held.forEach { $0.cancel() } }
        XCTAssertGreaterThan(port, 1024)
        let url = URL(string: "http://127.0.0.1:\(port)/slow")!

        let b = try await loaded()
        b.loadTimeout = 1
        let t0 = Date.now
        do { try await b.navigate(url); XCTFail("should time out") } catch let e as BrowserError {
            if case .timeout = e {} else { XCTFail("\(e)") }
        }
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(t0), 1)
        try await expectEqual(try await eval(b, "document.querySelector('h1').textContent") as? String, "Apply here")

        let first = Task { @MainActor in
            do { try await b.navigate(url); return "finished" } catch { return error.localizedDescription }
        }
        try await Task.sleep(for: .milliseconds(100))
        do { try await b.navigate(url); XCTFail("should time out") } catch let e as BrowserError {
            if case .timeout = e {} else { XCTFail("\(e)") }
        }
        let outcome = await first.value
        XCTAssertEqual(outcome, "Replaced by a newer navigation")
        b.webView.stopLoading()
    }
}
