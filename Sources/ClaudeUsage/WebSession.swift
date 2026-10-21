import AppKit
import WebKit

enum WebError: Error, CustomStringConvertible {
    case notSignedIn
    case busy
    case blocked
    case http(Int)
    case badResponse

    var description: String {
        switch self {
        case .notSignedIn: return "Signed out"
        case .busy: return "Sign-in in progress"
        case .blocked: return "claude.ai blocked the request"
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "Unexpected response"
        }
    }
}

/// One isolated claude.ai browser session per account.
///
/// Each account owns a persistent `WKWebsiteDataStore` keyed by its UUID, so cookies for different
/// Claude accounts never mix. API calls are made with `fetch()` *inside* the claude.ai page, so they
/// carry the logged-in cookies and look exactly like the website's own traffic.
@MainActor
final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let accountID: UUID
    let webView: WKWebView
    private(set) var loginWindow: NSWindow?
    private var popups: [NSWindow] = []
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var loadGeneration = 0

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init(accountID: UUID) {
        self.accountID = accountID
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: accountID)
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: cfg)
        webView.customUserAgent = Self.userAgent
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    var isLoginVisible: Bool { loginWindow?.isVisible == true }

    // MARK: Requests

    func get(_ path: String) async throws -> String {
        try await ensureOrigin()
        let js = """
        const r = await fetch(path, { credentials: 'include', headers: { 'accept': 'application/json' } });
        const body = await r.text();
        return JSON.stringify({ status: r.status, body: body });
        """
        let result = try await webView.callAsyncJavaScript(
            js, arguments: ["path": path], in: nil, contentWorld: .page)
        guard let str = result as? String,
              let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? Int,
              let body = obj["body"] as? String else { throw WebError.badResponse }
        NSLog("ClaudeUsage: GET %@ -> %d", path.replacingOccurrences(of: #"[0-9a-f-]{36}"#, with: "{id}", options: .regularExpression), status)
        if body.hasPrefix("<") { throw WebError.blocked }
        if status == 401 || status == 403 { throw WebError.notSignedIn }
        guard status == 200 else { throw WebError.http(status) }
        return body
    }

    private func ensureOrigin() async throws {
        if webView.url?.host?.hasSuffix("claude.ai") == true { return }
        // Never yank the page out from under someone who is mid-login (e.g. on a Google SSO page).
        if isLoginVisible { throw WebError.busy }
        await park()
        if webView.url?.host?.hasSuffix("claude.ai") != true { throw WebError.busy }
    }

    /// Rests the web view on a tiny same-origin page, so the full claude.ai web app isn't kept
    /// running in the background just to make API calls.
    func park() async {
        await load(URL(string: "https://claude.ai/robots.txt")!)
    }

    private func load(_ url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loadContinuation?.resume()
            loadContinuation = c
            loadGeneration += 1
            let generation = loadGeneration
            webView.load(URLRequest(url: url))
            // Give up after 20s, but only on this load: a stale timer must not end a newer one early.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.finishLoad()
            }
        }
    }

    private func finishLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    // MARK: Login window

    func showLogin() {
        if loginWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "Sign in to Claude"
            w.contentView = webView
            w.isReleasedWhenClosed = false
            w.center()
            loginWindow = w
        }
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        NSApp.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
    }

    func closeLogin() {
        loginWindow?.orderOut(nil)
        popups.forEach { $0.close() }
        popups.removeAll()
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { finishLoad() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { finishLoad() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { finishLoad() }
    }

    /// "Continue with Google" opens a popup that talks back to the opener, so it must be a real child web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let pop = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        pop.customUserAgent = Self.userAgent
        pop.uiDelegate = self
        pop.navigationDelegate = self
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in"
        w.contentView = pop
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return pop
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = popups.first(where: { $0.contentView === webView }) {
            w.close()
            popups.removeAll { $0 === w }
        }
    }
}
