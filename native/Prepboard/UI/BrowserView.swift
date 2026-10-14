import SwiftData
import SwiftUI
import WebKit

/// Observable state for the in-app browser (one shared web view, so pages survive switching sections).
@MainActor
@Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var title = ""
    var url: URL?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    override init() {
        let cfg = WKWebViewConfiguration()
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        #endif
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            webView.observe(\.url) { [weak self] v, _ in Task { @MainActor in self?.url = v.url } },
            webView.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            webView.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
        ]
    }

    /// Loads a URL, or searches the web when the text isn't a URL.
    func go(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let u = URL(string: t), let scheme = u.scheme, ["http", "https"].contains(scheme) { load(u); return }
        if t.contains("."), !t.contains(" "), let u = URL(string: "https://" + t) { load(u); return }
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        load(URL(string: "https://www.google.com/search?q=\(q)")!)
    }

    func load(_ u: URL) { webView.load(URLRequest(url: u)) }

    // Open target=_blank links in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

#if os(macOS)
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

struct BrowserView: View {
    @Environment(AppState.self) private var app
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private let quickLinks: [(String, String, String)] = [
        ("Apple Developer", "https://developer.apple.com/documentation/", "applelogo"),
        ("AVKit docs", "https://developer.apple.com/documentation/avkit", "play.rectangle"),
        ("WWDC videos", "https://developer.apple.com/videos/", "video"),
        ("Swift docs", "https://www.swift.org/documentation/", "swift"),
        ("LeetCode", "https://leetcode.com/problemset/", "chevron.left.forwardslash.chevron.right"),
        ("YouTube", "https://www.youtube.com", "play.circle"),
        ("Glassdoor", "https://www.glassdoor.com/Interview/index.htm", "person.2"),
        ("Google", "https://www.google.com", "magnifyingglass"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            ZStack {
                WebViewHost(webView: browser.webView)
                    .opacity(browser.url == nil ? 0 : 1)
                if browser.url == nil { startPage }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous).strokeBorder(PB.line))
            .padding(.bottom, 24)
        }
        .onAppear {
            if let u = app.browserURL { browser.load(u); app.browserURL = nil }
            address = browser.url?.absoluteString ?? ""
        }
        .onChange(of: app.browserURL) { if let u = app.browserURL { browser.load(u); app.browserURL = nil } }
        .onChange(of: browser.url) { if !addressFocused { address = browser.url?.absoluteString ?? "" } }
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    navigationButtons
                    addressField.frame(minWidth: 220)
                    Button { openInBrowser() } label: {
                        Label("Open in browser", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true)).fixedSize()
                    .disabled(browser.url == nil).help("Open this page in your default browser")
                    Button { saveToNotes() } label: { Label("Save to notes", systemImage: "doc.badge.plus") }
                        .buttonStyle(PillButtonStyle(compact: true)).fixedSize().disabled(browser.url == nil)
                }
                VStack(spacing: 8) {
                    addressField
                    HStack(spacing: 8) {
                        navigationButtons
                        Spacer(minLength: 0)
                        CircleIconButton(systemImage: "arrow.up.right.square", size: controlSize, label: "Open this page in your default browser") { openInBrowser() }
                            .disabled(browser.url == nil)
                        CircleIconButton(systemImage: "doc.badge.plus", size: controlSize, active: true, label: "Save page to notes") { saveToNotes() }
                            .disabled(browser.url == nil)
                    }
                }
            }
            if browser.isLoading {
                ProgressView(value: browser.progress).tint(PB.cobalt).padding(.top, 8)
            }
        }
    }

    private var controlSize: CGFloat { max(40, PB.minTap) }

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            CircleIconButton(systemImage: "chevron.left", size: controlSize, label: "Back") { browser.webView.goBack() }
                .disabled(!browser.canGoBack)
            CircleIconButton(systemImage: "chevron.right", size: controlSize, label: "Forward") { browser.webView.goForward() }
                .disabled(!browser.canGoForward)
            CircleIconButton(systemImage: browser.isLoading ? "xmark" : "arrow.clockwise", size: controlSize, label: browser.isLoading ? "Stop loading" : "Reload page") {
                if browser.isLoading { browser.webView.stopLoading() } else { _ = browser.webView.reload() }
            }
        }
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: browser.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 12)).foregroundStyle(PB.muted)
                .accessibilityHidden(true)
            TextField("Search or enter website", text: $address)
                .textFieldStyle(.plain)
                .focused($addressFocused)
                .accessibilityLabel("Search or enter website")
                .onSubmit { browser.go(address); addressFocused = false }
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                .submitLabel(.go)
                #endif
        }
        .padding(.horizontal, 16).frame(height: controlSize)
        .background(RoundedRectangle(cornerRadius: PB.rMD).fill(PB.card))
        .overlay(RoundedRectangle(cornerRadius: PB.rMD).strokeBorder(addressFocused ? PB.cobalt : PB.line))
    }

    private func openInBrowser() {
        if let u = browser.url { openURL(u) }
    }

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browse").pbLabelStyle()
                    Text("Research without leaving PrepBoard").font(.system(size: 28, weight: .bold)).kerning(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Search above, or start from a favorite. Tap “Save to notes” to keep a page with your prep documents.")
                        .foregroundStyle(PB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(quickLinks, id: \.0) { name, url, icon in
                        Button { browser.load(URL(string: url)!) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(PB.cobalt)
                                    .frame(width: 36, height: 36).background(Circle().fill(PB.cobaltSoft))
                                Text(name).font(.system(size: 14, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(PB.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
        .background(PB.surface)
    }

    private func saveToNotes() {
        guard let u = browser.url else { return }
        let role = app.timelineRoleID ?? roles.first?.id ?? ""
        let title = browser.title.isEmpty ? (u.host ?? "Saved page") : browser.title
        app.newDoc(context, roleId: role, title: "Research: \(title)",
                   body: "## Source\n[\(title)](\(u.absoluteString))\n\nSaved \(Date.now.pbFull)\n\n## Notes\n- \n",
                   tags: ["research"])
    }
}
