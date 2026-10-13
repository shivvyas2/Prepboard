#if os(macOS)
import Darwin
import Foundation
import Network
import Observation

/// Lets the user's own iPhone / iPad use this Mac's Claude Code (home Wi-Fi or Tailscale).
///
/// Off by default. When turned on, PrepBoard listens on port 8788 while it's open. Every request must carry
/// the 16-character pairing code (`Authorization: Bearer …`); browsers are refused outright (they always send
/// an Origin), an address is locked out for 15 minutes after 10 wrong codes, and Claude Code runs with the
/// same read-only and web tools as everywhere else in the app. `/exec` compiles and runs Practice code
/// (Swift, Python, JavaScript) for paired devices, one run at a time, with the 30-second limit CodeRunner applies.
@MainActor
@Observable
final class DeviceBridge {
    var enabled: Bool = UserDefaults.standard.bool(forKey: "deviceBridge.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "deviceBridge.enabled") }
    }
    private(set) var running = false
    private(set) var lastError: String?
    private(set) var lastUsed: Date?
    private(set) var code: String

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private weak var claude: ClaudeCode?
    @ObservationIgnored private var failures: [String: (count: Int, at: Date)] = [:]
    @ObservationIgnored private var executing = false
    private static let codeKey = "device-bridge-code"
    private static let allowedTools: Set<String> = ["Read", "Grep", "Glob", "WebSearch", "WebFetch"]
    private static let maxBody = 300_000

    init() {
        #if DEBUG
        // `-PrepboardBridgeTestCode ABCD…` (16 chars): throwaway code for local testing; never stored.
        if let t = UserDefaults.standard.string(forKey: "PrepboardBridgeTestCode"), t.count == 16 { code = t; return }
        #endif
        if let c = Keychain.read(Self.codeKey), c.count == 16 { code = c } else { code = Self.newCode(); Keychain.save(code, Self.codeKey) }
    }

    var displayCode: String { stride(from: 0, to: 16, by: 4).map { i in String(Array(code)[i..<i + 4]) }.joined(separator: "-") }

    /// The addresses an iPhone can use: Tailscale (100.64.0.0/10) first, then local Wi-Fi / Ethernet.
    var addresses: [(ip: String, tailscale: Bool)] {
        var out: [(String, Bool)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0, (Int32(ifa.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            let tailscale = parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
            if !ip.hasPrefix("169.254."), !out.contains(where: { $0.0 == ip }) { out.append((ip, tailscale)) }
        }
        return out.sorted { $0.1 && !$1.1 }.map { (ip: $0.0, tailscale: $0.1) }
    }

    func attach(_ claude: ClaudeCode) {
        self.claude = claude
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        on ? start() : stop()
    }

    /// Replaces the pairing code; every paired device has to pair again.
    func resetCode() {
        code = Self.newCode()
        Keychain.save(code, Self.codeKey)
    }

    private static func newCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: DeviceBridgeConfig.port)!)
            l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.accept(conn) } }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.running = true; self?.lastError = nil
                    case .failed(let e): self?.running = false; self?.lastError = "Couldn't start: \(e.localizedDescription)"; self?.listener = nil
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = "Couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: HTTP

    private struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

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
                if buf.count > Self.maxBody + 16_384 { self.reply(conn, 413, ["error": "Request too large"]); return }
                if let req = Self.parse(buf) { await self.handle(req, conn: conn); return }
                if done || error != nil { conn.cancel(); return }
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// Returns a request once the headers and the full Content-Length body have arrived.
    private static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return Request(method: "", path: "", headers: [:], body: Data()) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative length would trap in prefix(_:); an absurd one would never arrive. Both become an empty request the checks refuse.
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= maxBody else {
            return Request(method: "", path: "", headers: headers, body: Data())
        }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func peer(_ conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "unknown"
    }

    private func handle(_ req: Request, conn: NWConnection) async {
        let ip = peer(conn)
        // Browsers always send Origin; only the PrepBoard app (which doesn't) may use this.
        if req.headers["origin"] != nil { return reply(conn, 403, ["error": "Not allowed"]) }
        if let f = failures[ip], f.count >= 10, Date.now.timeIntervalSince(f.at) < 15 * 60 {
            return reply(conn, 429, ["error": "Too many wrong pairing codes. Try again in 15 minutes."])
        }
        let given = (req.headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])
            .uppercased().filter { $0.isLetter || $0.isNumber }
        guard Self.constantTimeEqual(given, code) else {
            let f = failures[ip] ?? (0, .distantPast)
            failures[ip] = (f.count + 1, .now)
            return reply(conn, 401, ["error": "Wrong pairing code."])
        }
        failures[ip] = nil
        guard let claude else { return reply(conn, 503, ["error": "PrepBoard isn't ready yet."]) }

        switch (req.method, req.path) {
        case ("GET", "/status"):
            await claude.checkConnection()
            if case .connected(let v) = claude.connection {
                reply(conn, 200, ["ok": true, "version": v])
            } else {
                reply(conn, 200, ["ok": false, "error": "Claude Code isn't signed in on the Mac."])
            }
        case ("POST", "/run"):
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let prompt = obj["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return reply(conn, 400, ["error": "prompt is required"])
            }
            let tools = ((obj["tools"] as? String) ?? "Read").split(whereSeparator: { $0 == " " || $0 == "," })
                .map(String.init).filter { Self.allowedTools.contains($0) }
            let resume = (obj["resume"] as? String).flatMap { r in
                r.count <= 64 && r.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) ? r : nil
            }
            lastUsed = .now
            do {
                let (text, session) = try await claude.runText(prompt, tools: (tools.isEmpty ? ["Read"] : tools).joined(separator: " "), resume: resume)
                reply(conn, 200, ["result": text, "session_id": session ?? NSNull(), "is_error": false])
            } catch {
                reply(conn, 200, ["result": error.localizedDescription, "is_error": true])
            }
        case ("POST", "/exec"):
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let code = obj["code"] as? String, code.utf8.count <= 200_000,
                  let lang = CodeLang(rawValue: (obj["lang"] as? String) ?? "") else {
                return reply(conn, 400, ["error": "code and lang (swift, python, javascript) are required"])
            }
            guard !executing else { return reply(conn, 429, ["error": "Your Mac is already running code. Try again in a moment."]) }
            executing = true
            lastUsed = .now
            let result = await CodeRunner.run(code, lang: lang)
            executing = false
            // `output` is the whole run as text for older iPhone/iPad builds; newer ones read the structured `result`.
            let structured = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(result))) ?? NSNull()
            reply(conn, 200, ["output": result.text, "result": structured])
        default:
            reply(conn, 404, ["error": "Not found"])
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"][status] ?? "OK"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(json)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
#endif
