#if os(macOS)
import AppKit
import Foundation
import Network
import Observation

struct MCPTool { let name: String; let description: String; let inputSchema: [String: Any] }
enum MCPContent { case text(String), image(Data, mime: String) }

/// Pure JSON-RPC/MCP handling (testable without a socket).
enum MCP {
    static let versions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    static let defaultVersion = "2025-03-26"

    /// Handles one HTTP request body. Returns the HTTP status and JSON body (nil body for 202).
    /// Supports: initialize, notifications/* (→ 202), ping, tools/list, tools/call; anything else → JSON-RPC -32601.
    static func handle(_ body: Data, tools: [MCPTool], call: (String, [String: Any]) async throws -> MCPContent) async -> (status: Int, body: Data?) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else { return (200, error(-32700, "Parse error", id: NSNull())) }
        guard let req = obj as? [String: Any] else { return (200, error(-32600, "Invalid Request: a single JSON-RPC object is required", id: NSNull())) }
        let id = requestID(req["id"])
        let method = req["method"] as? String ?? ""
        let params = req["params"] as? [String: Any] ?? [:]
        if method.hasPrefix("notifications/") { return (202, nil) }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let result: [String: Any] = [
                "protocolVersion": versions.contains(asked) ? asked : defaultVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": BrowserServer.name, "version": "1.0"],
                "instructions": "Browser tools for the PrepBoard hunt. Loop: read_page, then click/type/select, then wait or read_page again. Use screenshot when the page is unclear.",
            ]
            return (200, reply(id, result))
        case "ping":
            return (200, reply(id, [String: Any]()))
        case "tools/list":
            let list = tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] as [String: Any] }
            return (200, reply(id, ["tools": list]))
        case "tools/call":
            guard let name = params["name"] as? String else { return (200, error(-32602, "Invalid params: name is required", id: id)) }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await call(name, args)
                return (200, reply(id, ["content": [encode(content)], "isError": false]))
            } catch {
                return (200, reply(id, ["content": [encode(.text(error.localizedDescription))], "isError": true]))
            }
        default:
            return (200, error(-32601, "Method not found: \(method)", id: id))
        }
    }

    static func encode(_ content: MCPContent) -> [String: Any] {
        switch content {
        case .text(let t): ["type": "text", "text": t]
        case .image(let data, let mime): ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
        }
    }

    private static func reply(_ id: Any, _ result: [String: Any]) -> Data {
        json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(_ code: Int, _ message: String, id: Any) -> Data {
        json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// A JSON-RPC id is a string, a finite number or null; anything else (e.g. -1e999, which parses to -inf) is echoed as null.
    static func requestID(_ raw: Any?) -> Any {
        switch raw {
        case let s as String: s
        case let n as NSNumber where n.doubleValue.isFinite: n
        default: NSNull()
        }
    }

    private static func json(_ obj: [String: Any]) -> Data {
        let fallback = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        // isValidJSONObject first: data(withJSONObject:) raises an Objective-C exception (not a Swift error) on a non-finite number.
        guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj) else { return fallback }
        return data
    }
}

/// Local MCP server (Streamable HTTP with JSON responses) that exposes `HuntBrowser` to `claude -p`.
@MainActor
@Observable
final class BrowserServer {
    static let name = "prepboard"
    private(set) var port: UInt16?
    let token: String
    var minNavigationGap: TimeInterval = 1.5
    var navigationCap = 400
    private(set) var navigations = 0
    private(set) var lastError: String?
    var isRunning: Bool { port != nil }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: HuntBrowser?
    @ObservationIgnored private var lastNavigation: Date = .distantPast
    @ObservationIgnored private var configFile: URL?
    @ObservationIgnored private var queue: Task<Void, Never>?
    private static let maxBody = 2_000_000
    private static let uploadExtensions: Set<String> = ["pdf", "docx", "txt", "png"]

    init() {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Listens on a random free port on 127.0.0.1; `port` is set once the listener is ready (see `ready(timeout:)`).
    func start(browser: HuntBrowser) throws {
        self.browser = browser
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.accept(conn) } }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.port = l.port?.rawValue; self.lastError = nil
                case .failed(let e): self.port = nil; self.lastError = "The built-in browser couldn't start: \(e.localizedDescription)"; self.listener = nil
                case .cancelled: self.port = nil
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// Waits for the listener to come up (the port is assigned asynchronously after `start`).
    func ready(timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while port == nil, listener != nil, Date.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return port != nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        if let configFile { try? FileManager.default.removeItem(at: configFile) }
        configFile = nil
    }

    /// New run: navigation counter back to zero and a fresh action log.
    func reset() {
        navigations = 0
        browser?.reset()
    }

    // MARK: Claude flags

    var mcpConfigJSON: String {
        let cfg: [String: Any] = ["mcpServers": [Self.name: [
            "type": "http",
            "url": "http://127.0.0.1:\(port ?? 0)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    static let tools: [MCPTool] = [
        tool("navigate", "Open a page in the PrepBoard browser and wait for it to load (http or https only). Returns the final URL and title; call read_page next. Navigations are paced and capped per run, so read a page fully before moving on.",
             ["url": ["type": "string", "description": "Absolute URL, e.g. https://www.linkedin.com/jobs/"]], required: ["url"]),
        tool("back", "Go back one page and wait for it to load. Call read_page afterwards; refs change with the page.", [:]),
        tool("wait", "Wait for the page to finish loading and settle. Call it after a click, type with submit, or press Enter that navigates or opens something, then read_page again.", [:]),
        tool("page_text", "The visible text of the page (body.innerText, up to 60,000 characters). Use it to read a job description or confirmation; use read_page when you need refs to act on.", [:]),
        tool("read_page", "List the page's elements with refs, one per line: `r12 button \"Easy Apply\"`, `r13 link \"Title\" → url`, `r14 textbox \"Email\" = \"\"`, `r15 combobox \"Country\" = \"United States\"`, `r16 file \"Resume/CV\"`, `r17 checkbox \"I agree\" [ ]`, `r18 heading \"…\"`, `r19 text \"…\"`. Pass a ref to click, type, select, scroll or upload_file. Refs belong to the current page: call read_page again after a navigation, a click that changes the page, or when a ref is reported missing.",
             ["interactive_only": ["type": "boolean", "description": "true lists only buttons, links, fields and headings (shorter); default false includes text"]]),
        tool("click", "Click an element by ref: it is scrolled into view and clicked with a real mouse click at its centre. If the click navigates or opens a dialog, call wait or read_page before the next action. Take a screenshot if the page does not react as expected.",
             ["ref": ["type": "string", "description": "A ref from read_page, e.g. r12"]], required: ["ref"]),
        tool("type", "Type text into a textbox or textarea by ref (the value is set and input/change events fire). clear (default true) replaces the current value; submit (default false) presses Enter afterwards.",
             ["ref": ["type": "string"], "text": ["type": "string"], "clear": ["type": "boolean", "description": "Replace the current value (default true)"],
              "submit": ["type": "boolean", "description": "Press Enter after typing (default false)"]], required: ["ref", "text"]),
        tool("select", "Choose an option in a <select> (combobox) by its value or visible text. For custom dropdowns that are not a <select>, click the control and then click the option instead.",
             ["ref": ["type": "string"], "value": ["type": "string", "description": "Option value or visible text"]], required: ["ref", "value"]),
        tool("press", "Press a key on the focused element: Enter, Tab, Escape, ArrowDown, ArrowUp, Backspace, Space, or a single character. Enter in a form field submits the form.",
             ["key": ["type": "string"]], required: ["key"]),
        tool("scroll", "Scroll the page by 600 px in a direction (default down), or scroll the element with ref into view. Call read_page afterwards to see what is now visible.",
             ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "ref": ["type": "string", "description": "A ref to scroll into view instead of scrolling by direction"]]),
        tool("upload_file", "Attach a file to a file input. ref is the file input itself or the label/button that opens the file picker; path is an absolute path inside the home folder to a .pdf, .docx, .txt or .png file. Returns the attached file name; call read_page or screenshot to confirm the page shows it.",
             ["ref": ["type": "string"], "path": ["type": "string", "description": "Absolute path, e.g. /Users/me/Resumes/Resume.pdf"]], required: ["ref", "path"]),
        tool("screenshot", "A PNG screenshot of the page as it looks now. Use it when read_page is unclear: layout, modals, CAPTCHAs, whether a click took effect.", [:]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> MCPTool {
        MCPTool(name: name, description: description, inputSchema: ["type": "object", "properties": properties, "required": required])
    }

    /// The tools a run that only reads (Discover, the LinkedIn sync) gets; click stays for pagination and tabs.
    static let readOnlyTools: Set<String> = ["navigate", "back", "wait", "page_text", "read_page", "click", "scroll", "screenshot"]

    var allowedTools: String { Self.allowedTools(readOnly: false) }

    static func allowedTools(readOnly: Bool) -> String {
        tools.filter { !readOnly || readOnlyTools.contains($0.name) }.map { "mcp__\(name)__\($0.name)" }.joined(separator: " ")
    }

    /// The `claude -p` flags for a run that uses the browser: --mcp-config <file> [--strict-mcp-config] --allowedTools <tools + extra>.
    /// `readOnly` leaves out type, select, press and upload_file; `strict: false` keeps the user's other MCP servers (the Gmail and Calendar connectors).
    func claudeFlags(extraTools: String, readOnly: Bool = false, strict: Bool = true) -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("prepboard-hunt", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("mcp-\(ProcessInfo.processInfo.processIdentifier).json")
        // Configs left by earlier launches (the app rarely gets to `stop()`) hold dead tokens; sweep them.
        for stale in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where stale.hasPrefix("mcp-") && stale != file.lastPathComponent {
            try? fm.removeItem(at: dir.appendingPathComponent(stale))
        }
        // Created 0600 in one step: the token must never sit in a world-readable file, however briefly.
        try? fm.removeItem(at: file)
        fm.createFile(atPath: file.path, contents: Data(mcpConfigJSON.utf8), attributes: [.posixPermissions: 0o600])
        configFile = file
        let extra = extraTools.trimmingCharacters(in: .whitespaces)
        return "--mcp-config '\(file.path)'\(strict ? " --strict-mcp-config" : "") --allowedTools \(Self.allowedTools(readOnly: readOnly))\(extra.isEmpty ? "" : " " + extra)"
    }

    // MARK: Tools

    /// Enforces the minimum gap between navigations and the per-run cap. The slot is reserved before sleeping, so
    /// concurrent callers queue up one gap apart instead of sharing a slot.
    func pace() async throws {
        guard navigations < navigationCap else { throw BrowserError.blocked("Navigation cap reached for this run") }
        navigations += 1
        let slot = max(Date.now, lastNavigation.addingTimeInterval(minNavigationGap))
        lastNavigation = slot
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }

    /// Only files in the user's home folder with an allowed extension may be uploaded.
    nonisolated static func uploadAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        return url.path.hasPrefix(home + "/") && uploadExtensions.contains(url.pathExtension.lowercased())
    }

    /// Tool calls run one at a time, in arrival order: parallel requests must not interleave on the single web view.
    func call(_ name: String, _ args: [String: Any]) async throws -> MCPContent {
        let prev = queue
        let task = Task { @MainActor in
            _ = await prev?.value
            return try await self.perform(name, args)
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func perform(_ name: String, _ args: [String: Any]) async throws -> MCPContent {
        guard let browser else { throw BrowserError.message("The PrepBoard browser is not attached") }
        func str(_ key: String) throws -> String {
            guard let v = args[key] as? String, !v.isEmpty else { throw BrowserError.message("\(key) is required for \(name)") }
            return v
        }
        func where_() -> String { "\(browser.url?.absoluteString ?? "about:blank")\(browser.title.isEmpty ? "" : " — \(browser.title)")" }
        switch name {
        case "navigate":
            let s = try str("url")
            guard let u = URL(string: s), u.host != nil else { throw BrowserError.message("Not a valid URL: \(s)") }
            try await pace()
            try await browser.navigate(u)
            return .text("Loaded \(where_()). Call read_page to see it.")
        case "back":
            try await pace()
            try await browser.back()
            return .text("Back at \(where_()). Call read_page to see it.")
        case "wait":
            try await browser.waitForLoad()
            return .text("Settled at \(where_()).")
        case "page_text":
            return .text("\(where_())\n\n\(try await browser.pageText())")
        case "read_page":
            let lines = try await browser.readPage(interactiveOnly: args["interactive_only"] as? Bool ?? false)
            return .text("\(where_())\n\(lines)")
        case "click":
            try await browser.click(ref: try str("ref"))
            return .text("\(browser.lastAction). Call wait or read_page if the page changed.")
        case "type":
            try await browser.type(ref: try str("ref"), text: args["text"] as? String ?? "", clear: args["clear"] as? Bool ?? true, submit: args["submit"] as? Bool ?? false)
            return .text(browser.lastAction)
        case "select":
            try await browser.select(ref: try str("ref"), value: try str("value"))
            return .text(browser.lastAction)
        case "press":
            try await browser.press(key: try str("key"))
            return .text(browser.lastAction)
        case "scroll":
            try await browser.scroll(direction: args["direction"] as? String, ref: args["ref"] as? String)
            return .text("\(browser.lastAction). Call read_page to see what is visible now.")
        case "upload_file":
            let path = try str("path")
            guard Self.uploadAllowed(path) else {
                throw BrowserError.blocked("upload_file only accepts .pdf, .docx, .txt or .png files inside your home folder (got \(path))")
            }
            try await browser.uploadFile(ref: try str("ref"), path: (path as NSString).expandingTildeInPath)
            return .text(browser.lastAction)
        case "screenshot":
            return .image(Self.scaledPNG(try await browser.screenshot(), maxWidth: 1280), mime: "image/png")
        default:
            throw BrowserError.message("Unknown tool \(name)")
        }
    }

    /// Downscales a PNG so it is at most `maxWidth` pixels wide (retina snapshots come back at 2x).
    nonisolated static func scaledPNG(_ png: Data, maxWidth: Int) -> Data {
        guard let rep = NSBitmapImageRep(data: png), rep.pixelsWide > maxWidth else { return png }
        let h = Int(Double(rep.pixelsHigh) * Double(maxWidth) / Double(rep.pixelsWide))
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: maxWidth, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return png }
        out.size = NSSize(width: maxWidth, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: maxWidth, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:]) ?? png
    }

    // MARK: HTTP

    struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    /// The HTTP status that refuses a request, or nil when it may reach the MCP handler.
    nonisolated static func gate(method: String, path: String, headers: [String: String], token: String) -> Int? {
        if headers["origin"] != nil { return 403 }   // browsers always send Origin; only claude (which doesn't) may use this
        let given = (headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespaces)
        guard constantTimeEqual(given, token) else { return 401 }
        guard path == "/mcp" || path.hasPrefix("/mcp?") else { return 404 }
        guard method == "POST" else { return 405 }
        return nil
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if buf.count > Self.maxBody + 16_384 { self.reply(conn, 413, Data(#"{"error":"Request too large"}"#.utf8)); return }
                if let req = Self.parse(buf) { await self.handle(req, conn: conn); return }
                if done || error != nil { conn.cancel(); return }
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// Returns a request once the headers and the full Content-Length body have arrived.
    nonisolated static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return Request(method: "", path: "", headers: [:], body: Data()) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative length would trap in prefix(_:); an absurd one would never arrive. Both become an empty request the gate refuses.
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= maxBody else {
            return Request(method: "", path: "", headers: headers, body: Data())
        }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ req: Request, conn: NWConnection) async {
        if let status = Self.gate(method: req.method, path: req.path, headers: req.headers, token: token) {
            let text = [401: "Unauthorized", 403: "Not allowed", 404: "Not found", 405: "Use POST /mcp"][status] ?? "Refused"
            return reply(conn, status, Data(#"{"error":"\#(text)"}"#.utf8))
        }
        let (status, body) = await MCP.handle(req.body, tools: Self.tools) { name, args in try await self.call(name, args) }
        reply(conn, status, body)
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ body: Data?) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "OK"
        let json = body ?? Data()
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(json)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
#endif
