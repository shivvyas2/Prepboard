#if os(iOS)
import Foundation
import Observation

/// iPhone / iPad: uses the Claude Code on the user's Mac through `bridge/claude-bridge.mjs --remote`
/// (home Wi-Fi or Tailscale). Optional: off until the user pairs with the Mac's address and pairing code.
/// When the Mac can't be reached, PrepBoard falls back to the user's Anthropic key.
@MainActor
@Observable
final class ClaudeCode {
    enum Connection: Equatable { case unknown, checking, unreachable(String), signedOut, connected(String) }

    var enabled: Bool = UserDefaults.standard.bool(forKey: "bridge.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "bridge.enabled") }
    }
    private(set) var address: String = UserDefaults.standard.string(forKey: "bridge.address") ?? ""
    var connection: Connection = .unknown
    var isReady: Bool { enabled && { if case .connected = connection { true } else { false } }() }
    var paired: Bool { !address.isEmpty && Keychain.read(Self.key) != nil }

    private static let key = "bridge-pairing-code"

    private var baseURL: URL? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        return URL(string: a.contains("://") ? a : "http://" + (a.contains(":") ? a : a + ":\(DeviceBridgeConfig.port)"))
    }

    /// Saves the Mac's address and pairing code, then checks the connection.
    func pair(address: String, code: String) async {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.address, forKey: "bridge.address")
        Keychain.save(code.uppercased().filter { $0.isLetter || $0.isNumber }, Self.key)
        await checkConnection()
        if case .connected = connection { enabled = true }
    }

    func unpair() {
        enabled = false
        address = ""
        UserDefaults.standard.removeObject(forKey: "bridge.address")
        Keychain.delete(Self.key)
        connection = .unknown
    }

    func checkConnection() async {
        guard paired else { connection = .unknown; return }
        connection = .checking
        do {
            let (data, _) = try await request("status", body: nil, timeout: 25)
            let s = try JSONDecoder().decode(Status.self, from: data)
            connection = s.ok ? .connected(s.version ?? "Claude Code") : .signedOut
        } catch {
            connection = .unreachable(error.localizedDescription)
        }
    }

    private struct Status: Decodable { let ok: Bool; let version: String? }
    private struct RunBody: Encodable { let prompt: String; let tools: String; let resume: String? }
    private struct RunReply: Decodable { let result: String?; let session_id: String?; let is_error: Bool?; let error: String? }

    private func request(_ path: String, body: Data?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let base = baseURL, let token = Keychain.read(Self.key) else { throw Learning.Failure.message("Pair with your Mac first (Profile → Claude Code on my Mac).") }
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw Learning.Failure.message("Your Mac rejected the pairing code. Pair again in Profile.") }
        if http.statusCode == 429 { throw Learning.Failure.message("Too many wrong pairing codes. Try again in 15 minutes.") }
        return (data, http)
    }

    /// Runs a headless Claude Code turn on the Mac and returns the reply text and session id.
    func runText(_ prompt: String, tools: String, resume: String? = nil) async throws -> (text: String, session: String?) {
        let body = try JSONEncoder().encode(RunBody(prompt: prompt, tools: tools, resume: resume))
        let reply: RunReply
        do {
            let (data, _) = try await request("run", body: body, timeout: 330)
            reply = try JSONDecoder().decode(RunReply.self, from: data)
        } catch let e as URLError {
            // Mac asleep or off the network: stop routing here so the next request uses the Anthropic key.
            connection = .unreachable(e.localizedDescription)
            throw Learning.Failure.message("Couldn't reach Claude Code on your Mac. Using your Anthropic key until it's back.")
        }
        if let e = reply.error { throw Learning.Failure.message(e) }
        if reply.is_error == true { throw Learning.Failure.message(reply.result ?? "Claude Code returned an error.") }
        return ((reply.result ?? "").withoutEmoji, reply.session_id)
    }

    /// Compiles and runs Practice code on the paired Mac (used for Swift, which can't compile on iPhone/iPad).
    func exec(_ code: String, lang: String) async throws -> String {
        struct Body: Encodable { let code: String; let lang: String }
        struct Reply: Decodable { let output: String?; let error: String? }
        do {
            let (data, _) = try await request("exec", body: try JSONEncoder().encode(Body(code: code, lang: lang)), timeout: 60)
            let r = try JSONDecoder().decode(Reply.self, from: data)
            if let e = r.error { throw Learning.Failure.message(e) }
            return r.output ?? ""
        } catch let e as URLError {
            connection = .unreachable(e.localizedDescription)
            throw Learning.Failure.message("Couldn't reach PrepBoard on your Mac. Open it there, then try again.")
        }
    }

    /// Runs a one-shot prompt on the Mac and decodes the JSON in its reply.
    func runJSON<T: Decodable>(_ prompt: String, tools: String) async throws -> T {
        let text = try await runText(prompt, tools: tools).text
        guard let open = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let close = text.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close else {
            throw Learning.Failure.message("Claude Code's reply wasn't JSON.")
        }
        do { return try JSONDecoder().decode(T.self, from: Data(text[open...close].utf8)) }
        catch { throw Learning.Failure.message("Couldn't read Claude Code's reply: \(error.localizedDescription)") }
    }
}

#endif
