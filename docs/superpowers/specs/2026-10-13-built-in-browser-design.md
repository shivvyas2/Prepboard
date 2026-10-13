# Built-in browser for the hunt (no Chrome)

## Goal
The Job Hunt (and the LinkedIn half of Gmail-&-LinkedIn sync) drive a browser inside PrepBoard instead of the user's Chrome with the Claude extension. The Mac app runs a small MCP server over local HTTP that exposes a WKWebView to `claude -p`. The user signs in to LinkedIn once in the app (Browse or the live view) and the hunt uses that session. The live view sits at the top of the Hunt tab so the user can watch, and step in when a page needs a person (login, CAPTCHA).

## Decisions (agreed with the user)
- Live view visible in the Hunt tab (a Browser card) while a run is active; the same web view is used for signing in.
- Gmail-&-LinkedIn sync keeps the Gmail/Calendar connectors and uses the built-in browser for LinkedIn. Nothing in the app depends on Chrome any more.
- Pacing is enforced by the server (minimum gap between navigations, per-run navigation cap), not only requested in prompts.

## Components (Mac only, all under `#if os(macOS)`)

### `Model/HuntBrowser.swift`
```swift
enum BrowserError: LocalizedError { case noPage, notFound(ref: String), timeout, blocked(String), message(String) }

/// A WKWebView the hunt drives. Shares WKWebsiteDataStore.default() with Browse, so one LinkedIn sign-in serves both.
@MainActor @Observable final class HuntBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView                 // created with frame 1280×900 so pages lay out even before the view is on screen
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var lastAction = ""       // one line for the live card, e.g. "Clicked Easy Apply", "Typed into Email"
    private(set) var actionLog: [String] = []   // last 50 actions, newest last
    var pendingUpload: URL?                // handed to runOpenPanel when the page asks for a file

    func navigate(_ url: URL) async throws            // loads and waits for didFinish (or 30 s → .timeout); blocks non-http(s) schemes
    func back() async throws
    func waitForLoad() async throws                    // settles after a click that navigates
    func pageText(maxChars: Int = 60_000) async throws -> String
    func readPage(interactiveOnly: Bool, maxChars: Int = 40_000) async throws -> String   // see BrowserScripts.readPage
    func click(ref: String) async throws               // scrollIntoView, real mouse down/up at the element's centre, JS click fallback
    func type(ref: String, text: String, clear: Bool, submit: Bool) async throws   // sets the value with the native setter, fires input/change (and keydown/keyup Enter when submit)
    func select(ref: String, value: String) async throws   // <select>: by value, then by visible text
    func press(key: String) async throws               // Enter, Tab, Escape, ArrowDown… on the focused element
    func scroll(direction: String?, ref: String?) async throws   // page scroll by 600 px, or scrollIntoView(ref)
    func uploadFile(ref: String, path: String) async throws   // see Uploads
    func screenshot() async throws -> Data             // PNG via takeSnapshot; throws .message if the view can't render
    func reset()                                        // clears the action log; does not clear cookies
}
```
Delegate behaviour: `createWebViewWith` loads target=_blank requests in the same view (as `BrowserModel` does); `runOpenPanelWith` completes with `[pendingUpload]` when set (then clears it) or `nil`; JavaScript alerts/confirms/prompts are auto-dismissed (alert → OK, confirm → false, prompt → nil) and logged; `decidePolicyFor` blocks downloads and non-web schemes.

**Uploads.** `uploadFile(ref:path:)`: (1) set `pendingUpload`, click the element (the file input itself, or the label/button for it: if `ref` is not a file input, the script finds the nearest `input[type=file]` by `for=`, ancestor, or sibling) and wait up to 2 s for the open panel to be requested; (2) if no panel came, inject the file: read the file, pass it base64-encoded to `BrowserScripts.setFiles(ref:name:mime:base64:)` which builds a `DataTransfer`, sets `input.files` and dispatches `input`/`change`. Either way verify `input.files.length == 1` and report the file name; otherwise throw `.message("The page did not accept the file")`.

### `Model/BrowserScripts.swift`
Injected JavaScript as Swift string constants, each a function expression that returns JSON:
- `readPage(interactiveOnly)`: walks the DOM in document order, skips invisible elements (display none, zero size, aria-hidden), assigns a stable `data-pb-ref="r<N>"` to each element it lists, and returns lines like `r12 button "Easy Apply"`, `r13 link "Senior iOS Engineer" → https://…`, `r14 textbox "Email" = "shiv@…"`, `r15 combobox "Country" = "United States"`, `r16 file "Resume/CV"`, `r17 checkbox "I agree" [ ]`, `r18 heading "Qualifications"`, `r19 text "3+ years of Swift…"` (text nodes grouped per block, truncated at 200 chars). `interactiveOnly` keeps buttons, links, inputs, selects, textareas, contenteditable, [role=button|link|tab|menuitem|option], and headings. Labels come from aria-label, `<label for>`, placeholder, name, title, then inner text.
- `pageText()`: `document.body.innerText` with runs of blank lines collapsed.
- `rect(ref)`: bounding rect of the element in CSS px (viewport), after `scrollIntoView({block: "center"})`.
- `click(ref)`, `setValue(ref, text, clear)`, `selectOption(ref, value)`, `pressKey(key)`, `scrollBy(dx, dy)`, `scrollTo(ref)`, `findFileInput(ref)`, `setFiles(ref, name, mime, base64)`, `filesCount(ref)`.
All functions throw a JS Error with a short message when the ref is missing; `HuntBrowser` maps that to `BrowserError.notFound`.

### `Model/BrowserServer.swift`
```swift
struct MCPTool { let name: String; let description: String; let inputSchema: [String: Any] }
enum MCPContent { case text(String), image(Data, mime: String) }

/// Pure JSON-RPC/MCP handling (testable without a socket).
enum MCP {
    /// Handles one HTTP request body. Returns the HTTP status and JSON body (nil body for 202).
    /// Supports: initialize, notifications/initialized (→ 202), ping, tools/list, tools/call; anything else → JSON-RPC -32601.
    static func handle(_ body: Data, tools: [MCPTool], call: (String, [String: Any]) async throws -> MCPContent) async -> (status: Int, body: Data?)
}

/// Local MCP server (Streamable HTTP with JSON responses) that exposes `HuntBrowser` to `claude -p`.
@MainActor @Observable final class BrowserServer {
    static let name = "prepboard"                     // tools are mcp__prepboard__<tool>
    private(set) var port: UInt16?                    // random free port on 127.0.0.1, chosen at start()
    let token: String                                 // 32 random hex chars, new on every app launch
    var minNavigationGap: TimeInterval = 1.5
    var navigationCap = 400                           // per run (reset())
    private(set) var navigations = 0
    var isRunning: Bool { port != nil }
    func start(browser: HuntBrowser) throws
    func stop()
    func reset()                                       // navigations = 0, browser.reset()
    var mcpConfigJSON: String                          // {"mcpServers":{"prepboard":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <token>"}}}}
    static let tools: [MCPTool]                        // navigate(url), back(), wait(), page_text(), read_page(interactive_only?), click(ref), type(ref, text, clear?, submit?), select(ref, value), press(key), scroll(direction?|ref?), upload_file(ref, path), screenshot()
    var allowedTools: String { Self.tools.map { "mcp__\(Self.name)__\($0.name)" }.joined(separator: " ") }
    /// The `claude -p` flags for a run that uses the browser: --mcp-config <file> --strict-mcp-config --allowedTools <allowedTools + extra>
    func claudeFlags(extraTools: String) -> String      // writes the config to a temp file and returns the flags
}
```
HTTP: NWListener on 127.0.0.1 only (not the device bridge's listener), same request parser as `DeviceBridge`. Every request must carry `Authorization: Bearer <token>` (constant-time compare); any `Origin` header is refused (403); `GET /mcp` → 405; `POST /mcp` → `MCP.handle`. `tools/call` runs on the main actor against the browser; `navigate` enforces `minNavigationGap` (sleeps the difference) and `navigationCap` (throws `.blocked("Navigation cap reached for this run")`). `upload_file` only accepts paths inside the user's home folder with a `.pdf`, `.docx`, `.txt` or `.png` extension. Tool results: text content (one string); `screenshot` returns image content (base64 PNG, scaled to at most 1280 px wide). Errors come back as `isError: true` with the message, never as an HTTP error.

### Wiring
- `PrepboardApp` (macOS): `@State private var huntBrowser = HuntBrowser()` and `@State private var browserServer = BrowserServer()`, injected like `jobSync` in both places; `browserServer.start(browser: huntBrowser)` in the same `.task` as the other attaches; `jobHunt.attach(container:claude:cloud:github:browser: browserServer)` and `jobSync.attach(container:claude:browser: browserServer)`.
- `JobHunt`: Discover and Submit runs use `browser.claudeFlags(extraTools:)` instead of `--chrome` and the Chrome tool names; the prompts say "the PrepBoard browser (tools prefixed mcp__prepboard__)" and describe the tool loop: `read_page` → `click`/`type` → `wait`/`read_page` again; `screenshot` when a page is unclear; `upload_file` for the résumé. `reset()` before each run. Tailor and Honesty are unchanged (no browser).
- `JobSync`: the LinkedIn part of the prompt uses the built-in browser; the Gmail/Calendar connector tools stay. Flags: connector tools + `browser.claudeFlags`.
- `ClaudeCode.busy` still gates both.
- `HuntView` (macOS): a **Browser** card at the top of the Hunt tab hosting `huntBrowser.webView` (height 520, collapsible, collapsed by default when the hunt is idle), with an address field + Go (so the user can sign in to LinkedIn here), `lastAction` and `isLoading` in the header, and a "Sign in to LinkedIn" button that loads https://www.linkedin.com/login. While `hunt.isRunning` the card expands.
- Debug smoke test, following `PrepboardBridgeTest`: launch argument `-PrepboardBrowserSmoke 1` runs, after the server starts, `claude -p` with the browser flags and the prompt "Use the prepboard browser tools: navigate to https://example.com, then read_page, and reply with exactly the page's h1 text." and prints `PrepboardBrowserSmoke: <reply>` to stdout.

## Error handling
Every tool failure returns `isError` text that names the ref or URL; `claude` sees it and can recover. A navigation that doesn't finish in 30 s returns "timed out; the page may still be loading" and leaves the page as is. If the server fails to start (port in use), `JobHunt.run()` refuses with "The built-in browser couldn't start" in `error`.

## Testing (`native/PrepboardTests/BrowserServerTests.swift`)
- `MCP.handle`: initialize (echoes a supported protocolVersion, lists tools capability), notifications/initialized → 202 with no body, ping, tools/list contains every tool with a valid inputSchema, tools/call routes name + arguments and wraps text/image content, unknown method → -32601, malformed JSON → -32700.
- Bearer check and Origin refusal (pure helpers).
- `BrowserScripts.readPage` and friends against a local HTML string loaded in a WKWebView inside the test (expectations with a 10 s timeout): refs are assigned, labels resolve from `<label for>` and aria-label, `setValue` + `filesCount`-style round trips work, `click` on a button changes the DOM, `setFiles` makes `input.files.length == 1`.
- Navigation pacing: two navigations closer than `minNavigationGap` are spaced (measured), and the cap throws.
