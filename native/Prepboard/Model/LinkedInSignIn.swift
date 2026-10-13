#if os(macOS)
import Foundation

/// A stored LinkedIn sign-in for the built-in browser. The email and password live only in this Mac's Keychain;
/// PrepBoard fills LinkedIn's form itself through `BrowserScripts`, so they never reach a prompt, a log line or Claude.
@MainActor
enum LinkedInSignIn {
    enum Outcome: Equatable { case signedIn, needsYou(String), failed(String), noCredentials }

    /// Keychain accounts (service unchanged). Tests point these at scratch entries so a saved sign-in is never touched.
    static var accounts = (email: "linkedin.email", password: "linkedin.password")

    static let needsYouMessage = "LinkedIn is asking for a verification code or a check; finish it in the Browser card, then run again"
    static let rejectedMessage = "LinkedIn did not accept the saved email or password"
    /// What a run says when LinkedIn wants a sign-in and nothing is saved.
    static let signInMessage = "Sign in to LinkedIn in the Browser card above, or save your LinkedIn sign-in in Settings, then run again"
    static let stoppedSummary = "Stopped: LinkedIn needs you to sign in"

    static var hasCredentials: Bool { Keychain.exists(accounts.email) && Keychain.exists(accounts.password) }

    static func save(email: String, password: String) {
        Keychain.save(email, accounts.email)
        Keychain.save(password, accounts.password)
    }

    static func remove() {
        Keychain.delete(accounts.email)
        Keychain.delete(accounts.password)
    }

    /// Where a LinkedIn URL leaves the user: signed in, on the sign-in page, or on a checkpoint/challenge that needs a person.
    /// `.noCredentials` here means "needs a sign-in". The public home page ("/") is where a signed-out visit ends up too.
    nonisolated static func classify(_ url: URL?) -> Outcome {
        guard let url, let host = url.host?.lowercased(), host == "linkedin.com" || host.hasSuffix(".linkedin.com") else {
            return .failed("Not on LinkedIn")
        }
        let path = url.path.lowercased()
        if ["/login", "/uas/", "/authwall", "/signup"].contains(where: path.contains) || path.isEmpty || path == "/" { return .noCredentials }
        if path.contains("/checkpoint") || path.contains("/challenge") { return .needsYou(needsYouMessage) }
        return .signedIn
    }

    /// The one-line stop reason for a run, nil when signed in.
    static func stopMessage(_ outcome: Outcome) -> String? {
        switch outcome {
        case .signedIn: nil
        case .noCredentials: signInMessage
        case .needsYou(let m), .failed(let m): m
        }
    }

    /// The page a signed-in session lands on. Tests point it at a local address.
    static var feedURL = URL(string: "https://www.linkedin.com/feed/")!

    /// Loads the feed and classifies where it lands; `.failed` when the page could not load at all (offline, timeout), which is
    /// not a sign that the session is gone.
    static func probe(_ browser: HuntBrowser) async -> Outcome {
        do { try await browser.navigate(feedURL) } catch { return .failed("Could not load LinkedIn: \(error.localizedDescription)") }
        return classify(browser.webView.url)
    }

    /// Loads https://www.linkedin.com/feed/ and classifies where it lands.
    static func isSignedIn(_ browser: HuntBrowser) async -> Bool { await probe(browser) == .signedIn }

    /// Empties the sign-in fields so no credential text stays in the page for a later `read_page`.
    private static func clearForm(_ browser: HuntBrowser) async {
        _ = try? await browser.run(BrowserScripts.fillLogin, "", "")
    }

    /// Opens the sign-in page, fills and submits it with the stored credentials, waits, and classifies the result.
    static func signIn(_ browser: HuntBrowser) async -> Outcome {
        guard let email = Keychain.read(accounts.email), let password = Keychain.read(accounts.password),
              !email.isEmpty, !password.isEmpty else { return .noCredentials }
        browser.log("Signing in to LinkedIn")
        let landed: URL?
        do { landed = try await browser.signInToLinkedIn(email: email, password: password) }
        catch { browser.log("LinkedIn needs you"); await clearForm(browser); return .failed(error.localizedDescription) }
        switch classify(landed) {
        case .signedIn:
            browser.log("Signed in to LinkedIn")
            return .signedIn
        case .noCredentials:
            // Still on the sign-in page: the saved values were refused, and the page says why when it can.
            browser.log("LinkedIn needs you")
            let text = (try? await browser.loginError()) ?? ""
            await clearForm(browser)
            return .failed(text.isEmpty ? rejectedMessage : text)
        case .needsYou(let m):
            browser.log("LinkedIn needs you")
            return .needsYou(m)
        case .failed(let m):
            browser.log("LinkedIn needs you")
            return .failed(m)
        }
    }

    /// isSignedIn, else signIn when credentials exist; the one call the runs use. A page that would not load is reported as
    /// such, never as a missing sign-in.
    static func ensure(_ browser: HuntBrowser) async -> Outcome {
        let probe = await probe(browser)
        if probe == .signedIn { return .signedIn }
        if case .failed = probe { return probe }
        guard hasCredentials else { return .noCredentials }
        return await signIn(browser)
    }
}
#endif
