#if os(macOS)
import AppKit
import Foundation
import Observation
import WebKit

enum BrowserError: LocalizedError {
    case noPage, notFound(ref: String), timeout, blocked(String), message(String)
    var errorDescription: String? {
        switch self {
        case .noPage: "No page is open. Call navigate with a URL first."
        case .notFound(let ref): "No element with ref \(ref) on the current page. Call read_page to get fresh refs."
        case .timeout: "Timed out after 30 s; the page may still be loading. Call wait or read_page to check."
        case .blocked(let m), .message(let m): m
        }
    }
}

/// A WKWebView the hunt drives. Shares WKWebsiteDataStore.default() with Browse, so one LinkedIn sign-in serves both.
@MainActor
@Observable
final class HuntBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var lastAction = ""
    private(set) var actionLog: [String] = []
    var pendingUpload: URL?

    /// Seconds a navigation may take before `.timeout`; tests shorten it.
    var loadTimeout: TimeInterval = 30
    /// Set when the page asked for the open panel during the last `uploadFile` (the trusted-click path).
    private(set) var panelRequested = false
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var loadWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var loadGeneration = 0
    /// Navigations WebKit has started and not yet reported on, and those that were in flight when the current waiter was
    /// created (their callbacks belong to an earlier request and must not resolve it).
    @ObservationIgnored private var inFlight: Set<ObjectIdentifier> = []
    @ObservationIgnored private var stale: Set<ObjectIdentifier> = []

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        // A real size so pages lay out (and getBoundingClientRect works) before the view is on screen.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            webView.observe(\.url) { [weak self] v, _ in Task { @MainActor in self?.url = v.url } },
            webView.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading } },
        ]
    }

    // MARK: Navigation

    /// Loads a page and waits for it to finish (30 s → `.timeout`). Only http and https.
    func navigate(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw BrowserError.blocked("Only http and https pages can be opened (got \(url.absoluteString))")
        }
        log("Opening \(url.host ?? url.absoluteString)")
        try await awaitLoad { webView.load(URLRequest(url: url)) }
    }

    /// Loads an HTML string (tests and the smoke test) and waits for it.
    func loadHTML(_ html: String, baseURL: URL? = nil) async throws {
        try await awaitLoad { webView.loadHTMLString(html, baseURL: baseURL) }
    }

    func back() async throws {
        guard webView.canGoBack else { throw BrowserError.message("There is no previous page to go back to") }
        log("Going back")
        try await awaitLoad { webView.goBack() }
    }

    /// Settles after a click that navigates: waits for an in-flight load, then a short pause for the page to render.
    func waitForLoad() async throws {
        try await Task.sleep(for: .milliseconds(300))
        if webView.isLoading { try await awaitLoad(ignoringInFlight: false) {} }
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Replaces any pending waiter, snapshots the navigations already in flight as stale (unless `ignoringInFlight` is false,
    /// as for `waitForLoad`, which waits for exactly those), starts the load and waits for its didFinish/didFail or the timeout.
    private func awaitLoad(ignoringInFlight: Bool = true, start: () -> Void) async throws {
        loadWaiter?.resume(throwing: BrowserError.message("Replaced by a newer navigation"))
        loadWaiter = nil
        loadGeneration += 1
        let gen = loadGeneration
        stale = ignoringInFlight ? inFlight : []
        start()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadWaiter = cont
            Task { @MainActor [weak self, loadTimeout] in
                try? await Task.sleep(for: .seconds(loadTimeout))
                guard let self, self.loadGeneration == gen else { return }
                self.finishLoad(.failure(BrowserError.timeout))
            }
        }
    }

    /// Books a navigation callback: removes it from the in-flight set and tells whether it belongs to the current waiter.
    private func current(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else { return true }
        let id = ObjectIdentifier(navigation)
        inFlight.remove(id)
        return stale.remove(id) == nil
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let w = loadWaiter else { return }
        loadWaiter = nil
        w.resume(with: result)
    }

    // MARK: Reading

    func pageText(maxChars: Int = 60_000) async throws -> String {
        try requirePage()
        let text = try await string(BrowserScripts.pageText)
        return Self.cap(text, maxChars)
    }

    /// One line per element with a stable `r<N>` ref; see `BrowserScripts.readPage`.
    func readPage(interactiveOnly: Bool, maxChars: Int = 40_000) async throws -> String {
        try requirePage()
        let text = try await string(BrowserScripts.readPage, interactiveOnly)
        return Self.cap(text, maxChars)
    }

    // MARK: Acting

    /// Scrolls the element into view and clicks it with real mouse events; falls back to a JavaScript click when the view
    /// has no window or the events did not reach the element.
    func click(ref: String) async throws {
        try requirePage()
        _ = try await run(BrowserScripts.armClick)
        let r = try await object(BrowserScripts.rect, ref)
        let label = r["label"] as? String ?? ref
        let before = webView.url
        var landed = false
        if let window = webView.window, let rect = Self.cgRect(r), webView.bounds.insetBy(dx: 1, dy: 1).contains(CGPoint(x: rect.midX, y: rect.midY)) {
            sendClick(at: CGPoint(x: rect.midX, y: rect.midY), window: window)
            try await Task.sleep(for: .milliseconds(150))
            if webView.isLoading || webView.url != before {
                landed = true
            } else {
                // A missing ref here means the click replaced the DOM, which also counts as landed.
                landed = (try? await bool(BrowserScripts.clickLanded, ref)) ?? true
            }
        }
        if !landed { _ = try await run(BrowserScripts.click, ref) }
        log("Clicked \(Self.short(label))")
    }

    private func sendClick(at cssPoint: CGPoint, window: NSWindow) {
        let viewPoint = webView.isFlipped ? cssPoint : CGPoint(x: cssPoint.x, y: webView.bounds.height - cssPoint.y)
        let location = webView.convert(viewPoint, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.02)] {
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: t + offset,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            type == .leftMouseDown ? webView.mouseDown(with: e) : webView.mouseUp(with: e)
        }
    }

    func type(ref: String, text: String, clear: Bool, submit: Bool) async throws {
        try requirePage()
        let label = try await string(BrowserScripts.setValue, ref, text, clear)
        if submit { _ = try await run(BrowserScripts.pressKey, "Enter") }
        log("Typed into \(Self.short(label))\(submit ? " and pressed Enter" : "")")
    }

    func select(ref: String, value: String) async throws {
        try requirePage()
        let chosen = try await string(BrowserScripts.selectOption, ref, value)
        log("Selected \(Self.short(chosen))")
    }

    func press(key: String) async throws {
        try requirePage()
        let label = try await string(BrowserScripts.pressKey, key)
        log("Pressed \(key)\(label.isEmpty ? "" : " in \(Self.short(label))")")
    }

    /// Page scroll by 600 px (direction: up, down, left, right; default down), or scrollIntoView(ref).
    func scroll(direction: String?, ref: String?) async throws {
        try requirePage()
        if let ref, !ref.isEmpty {
            let label = try await string(BrowserScripts.scrollTo, ref)
            log("Scrolled to \(Self.short(label))")
            return
        }
        let (dx, dy): (Int, Int) = switch (direction ?? "down").lowercased() {
        case "up": (0, -600)
        case "left": (-600, 0)
        case "right": (600, 0)
        default: (0, 600)
        }
        _ = try await run(BrowserScripts.scrollBy, dx, dy)
        log("Scrolled \((direction ?? "down").lowercased())")
    }

    /// Attaches a file: clicks the control with `pendingUpload` set (the page's open panel gets it), else injects it via DataTransfer.
    func uploadFile(ref: String, path: String) async throws {
        try requirePage()
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { throw BrowserError.message("No readable file at \(path)") }
        let inputRef = try await string(BrowserScripts.findFileInput, ref)
        pendingUpload = fileURL
        panelRequested = false
        try? await click(ref: ref)
        for _ in 0..<20 where !panelRequested { try await Task.sleep(for: .milliseconds(100)) }
        if !panelRequested {
            pendingUpload = nil
            let data = try Data(contentsOf: fileURL)
            _ = try await run(BrowserScripts.setFiles, inputRef, fileURL.lastPathComponent, Self.mime(for: fileURL), data.base64EncodedString())
        }
        try await Task.sleep(for: .milliseconds(200))
        let count = try await run(BrowserScripts.filesCount, inputRef) as? Int ?? 0
        guard count == 1 else { throw BrowserError.message("The page did not accept the file") }
        log("Uploaded \(fileURL.lastPathComponent)")
    }

    /// PNG of the current page via takeSnapshot; throws when WebKit cannot render (view hidden).
    func screenshot() async throws -> Data {
        try requirePage()
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: nil) { image, error in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: BrowserError.message("Screenshot unavailable while the Hunt tab is hidden\(error.map { " (\($0.localizedDescription))" } ?? "")")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide > 0,
              let png = rep.representation(using: .png, properties: [:]) else {
            throw BrowserError.message("Screenshot unavailable while the Hunt tab is hidden")
        }
        return png
    }

    /// Clears the action log; cookies and the current page stay.
    func reset() {
        actionLog = []
        lastAction = ""
    }

    // MARK: JavaScript

    /// Calls a `BrowserScripts` function expression with JSON-encoded arguments and decodes the JSON it returns.
    @discardableResult
    func run(_ function: String, _ args: Any...) async throws -> Any? { try await run(function, args) }

    private func string(_ function: String, _ args: Any...) async throws -> String {
        try await run(function, args) as? String ?? ""
    }

    private func bool(_ function: String, _ args: Any...) async throws -> Bool {
        try await run(function, args) as? Bool ?? false
    }

    private func object(_ function: String, _ args: Any...) async throws -> [String: Any] {
        try await run(function, args) as? [String: Any] ?? [:]
    }

    private func run(_ function: String, _ args: [Any]) async throws -> Any? {
        let encoded = try args.map { a -> String in
            let data = try JSONSerialization.data(withJSONObject: a, options: [.fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }
        let script = "(\(function))(\(encoded.joined(separator: ", ")))"
        let result: Any? = try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { value, error in
                if let error { cont.resume(throwing: Self.map(error)) } else { cont.resume(returning: value) }
            }
        }
        guard let json = result as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    private static func map(_ error: Error) -> Error {
        let ns = error as NSError
        var message = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
        if message.hasPrefix("Error: ") { message = String(message.dropFirst("Error: ".count)) }
        if message.hasPrefix("No element with ref ") {
            return BrowserError.notFound(ref: String(message.dropFirst("No element with ref ".count)))
        }
        return BrowserError.message(message)
    }

    private func requirePage() throws {
        guard webView.url != nil else { throw BrowserError.noPage }
    }

    private static func cgRect(_ r: [String: Any]) -> CGRect? {
        guard let x = r["x"] as? Double, let y = r["y"] as? Double, let w = r["width"] as? Double, let h = r["height"] as? Double, w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func cap(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "\n… (truncated at \(max) characters)"
    }

    private static func short(_ s: String) -> String { s.count > 60 ? String(s.prefix(59)) + "…" : s }

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "png": "image/png"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }

    private func log(_ line: String) {
        lastAction = line
        actionLog.append(line)
        if actionLog.count > 50 { actionLog.removeFirst(actionLog.count - 50) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let navigation { inFlight.insert(ObjectIdentifier(navigation)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if current(navigation) { finishLoad(.success(())) } }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if current(navigation) { failed(error) } }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if current(navigation) { failed(error) } }

    private func failed(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }   // replaced by another load; its own callbacks follow
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 {   // frame load interrupted by policy change (our .cancel)
            finishLoad(.failure(BrowserError.blocked("The page tried to download a file or open a non-web link; that is blocked")))
            return
        }
        finishLoad(.failure(BrowserError.message("Could not load the page: \(ns.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        if ["http", "https", "about", "blob", "data"].contains(scheme) { decisionHandler(.allow) }
        else { log("Blocked a \(scheme): link"); decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType { decisionHandler(.allow) }
        else { log("Blocked a download"); decisionHandler(.cancel) }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        panelRequested = true
        let file = pendingUpload
        pendingUpload = nil
        completionHandler(file.map { [$0] })
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        log("Dismissed alert: \(Self.short(message))")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        log("Declined confirm: \(Self.short(message))")
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        log("Dismissed prompt: \(Self.short(prompt))")
        completionHandler(nil)
    }
}
#endif
