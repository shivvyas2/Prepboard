import Foundation
import Security

/// Job-site accounts PrepBoard signs in to on my behalf (Workday, iCIMS, Taleo, a company's own portal). Each site gets its own
/// password in PrepBoard's Keychain; the list of sites and the email used for each sits in UserDefaults (nothing secret).
/// Claude never sees a password: the browser tool `fill_password` puts it straight into the page's password field.
enum SiteLogins {
    struct Login: Codable, Equatable, Identifiable {
        var host: String
        var email: String
        var created: Date
        /// True when PrepBoard made the account itself (versus a login I typed in).
        var madeByPrepBoard: Bool
        var id: String { host }
    }

    private static let indexKey = "hunt.siteLogins"
    private static func account(_ host: String) -> String { "site:" + host }

    /// The key a login is filed under: the page's host, lowercased, without "www.". Workday and iCIMS give every company its own
    /// subdomain (acme.wd5.myworkdayjobs.com), and each of those is a separate account, so the whole host is kept.
    static func key(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static var all: [Login] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([Login].self, from: data) else { return [] }
        return list.sorted { $0.host < $1.host }
    }

    private static func store(_ list: [Login]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: indexKey)
    }

    static func login(for host: String) -> Login? {
        all.first { $0.host == host }.flatMap { Keychain.exists(account($0.host)) ? $0 : nil }
    }

    /// The password, for filling a page or for "Copy password" in settings. Never returned to Claude.
    static func password(for host: String) -> String? { Keychain.read(account(host)) }

    static func save(host: String, email: String, password: String, madeByPrepBoard: Bool) {
        let host = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !password.isEmpty else { return }
        Keychain.save(password, account(host))
        var list = all.filter { $0.host != host }
        list.append(Login(host: host, email: email, created: .now, madeByPrepBoard: madeByPrepBoard))
        store(list)
    }

    static func remove(_ host: String) {
        Keychain.delete(account(host))
        store(all.filter { $0.host != host })
    }

    /// A strong password most job sites accept: 20 characters with upper and lower case, digits and the symbols Workday and Taleo
    /// require ("!" and "#"), no look-alike characters. Unique per site, so one leaked site never opens another.
    static func newPassword() -> String {
        let lower = Array("abcdefghjkmnpqrstuvwxyz"), upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ"), digits = Array("23456789")
        let all = lower + upper + digits
        func pick(_ set: [Character]) -> Character {
            var byte: UInt8 = 0
            repeat { _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte) } while Int(byte) >= 256 - 256 % set.count
            return set[Int(byte) % set.count]
        }
        var groups = (0..<4).map { _ in String((0..<4).map { _ in pick(all) }) }
        // Guarantee every class regardless of what the random draw gave.
        groups[0] = String(pick(upper)) + groups[0].dropFirst()
        groups[1] = String(pick(lower)) + groups[1].dropFirst()
        groups[2] = String(pick(digits)) + groups[2].dropFirst()
        return groups.joined(separator: "-") + "!#"
    }
}
