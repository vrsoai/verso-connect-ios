import UIKit
import WebKit

/// Full-screen WebView on the provider's login page, presented as Safari would
/// present it (user agent included), watching for the provider's session cookie.
final class VersoConnectViewController: UIViewController {

    private let token: String
    private let api: VersoAPI
    private var completion: ((Result<VersoConnection, VersoConnectError>) -> Void)?

    private var start: VersoAPI.StartResponse?
    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var pollTimer: Timer?
    private var capturing = false
    private var captureAttempts = 0
    private var finished = false

    /// The provider session shows up before the login is complete (verification
    /// steps); captures are retried until the session answers with a token.
    private let maxCaptureAttempts = 40
    private let retryInterval: TimeInterval = 3

    init(token: String, api: VersoAPI, completion: @escaping (Result<VersoConnection, VersoConnectError>) -> Void) {
        self.token = token
        self.api = api
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Connect ChatGPT"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)

        let configuration = WKWebViewConfiguration()
        // Fresh session every time: the user logs into the account they choose now.
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Present as Mobile Safari: the provider's sign-in buttons (Google in
        // particular) refuse browsers that identify as embedded web views.
        webView.customUserAgent = Self.safariUserAgent
        view.addSubview(webView)

        spinner.startAnimating()
        Task { await begin() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !finished { finish(.failure(.cancelled)) }
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Flow

    private func begin() async {
        do {
            let response = try await api.start(token: token)
            start = response
            guard let url = URL(string: response.loginUrl) else { throw VersoConnectError.invalidLink }
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
            webView.load(URLRequest(url: url))
            spinner.stopAnimating()
            pollTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.checkForSession() }
            }
        } catch let error as VersoConnectError {
            finish(.failure(error))
        } catch {
            finish(.failure(.network(error)))
        }
    }

    /// Looks for the provider session cookie; when present, reads the session
    /// from inside the page (same origin) and sends everything to Verso.
    private func checkForSession() {
        guard let start, !capturing, !finished else { return }
        guard let host = webView.url?.host, host.hasSuffix(start.cookieDomain) else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self,
                  let sessionToken = Self.sessionToken(from: cookies, name: start.cookieName, domain: start.cookieDomain) else { return }
            Task { @MainActor in self.capture(sessionToken: sessionToken) }
        }
    }

    private func capture(sessionToken: String) {
        guard let start, !capturing, !finished else { return }
        capturing = true
        captureAttempts += 1
        spinner.startAnimating()

        Task {
            // The access token and the account identity come from the page itself,
            // exactly like the hosted flow reads them; the provider refuses this
            // call from anywhere but a browser.
            let session = await readSession(url: start.sessionUrl)
            do {
                let outcome = try await api.capture(
                    nonce: start.captureNonce,
                    secret: start.clientSecret,
                    sessionToken: sessionToken,
                    accessToken: session.accessToken,
                    providerAccountId: session.accountId,
                    providerAccountEmail: session.email
                )
                switch outcome {
                case .connected(let connectionId):
                    finish(.success(VersoConnection(connectionId: connectionId)))
                case .waiting:
                    capturing = false
                    spinner.stopAnimating()
                    if captureAttempts >= maxCaptureAttempts { finish(.failure(.timedOut)) }
                }
            } catch let error as VersoConnectError {
                finish(.failure(error))
            } catch {
                finish(.failure(.network(error)))
            }
        }
    }

    private struct ProviderSession {
        var accessToken: String?
        var accountId: String?
        var email: String?
    }

    private func readSession(url: String) async -> ProviderSession {
        let script = """
        const r = await fetch(url, { credentials: 'include' });
        return await r.text();
        """
        // Completion-handler form: the async projection is ambiguous with the
        // defaulted completion parameter on some SDKs.
        let result: Any? = await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(script, arguments: ["url": url], in: nil, in: .page) { outcome in
                switch outcome {
                case .success(let value): continuation.resume(returning: value)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderSession()
        }
        let user = json["user"] as? [String: Any]
        return ProviderSession(
            accessToken: json["accessToken"] as? String,
            accountId: user?["id"] as? String,
            email: user?["email"] as? String
        )
    }

    private func finish(_ result: Result<VersoConnection, VersoConnectError>) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil
        webView?.stopLoading()
        let completion = self.completion
        self.completion = nil
        if presentingViewController != nil {
            dismiss(animated: true) { completion?(result) }
        } else {
            completion?(result)
        }
    }

    @objc private func cancelTapped() {
        finish(.failure(.cancelled))
    }

    // MARK: - Helpers

    /// The provider stores the session as one cookie, or chunked as `.0`, `.1`, …
    static func sessionToken(from cookies: [HTTPCookie], name: String, domain: String) -> String? {
        let relevant = cookies.filter { $0.domain.hasSuffix(domain) && $0.name.hasPrefix(name) }
        if let single = relevant.first(where: { $0.name == name }), !single.value.isEmpty {
            return single.value
        }
        let chunks = relevant
            .filter { $0.name.hasPrefix(name + ".") }
            .compactMap { cookie -> (Int, String)? in
                guard let index = Int(cookie.name.dropFirst(name.count + 1)) else { return nil }
                return (index, cookie.value)
            }
            .sorted { $0.0 < $1.0 }
        return chunks.isEmpty ? nil : chunks.map(\.1).joined()
    }

    /// Mobile Safari's user agent for the running iOS version.
    static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion.split(separator: ".")
        let major = version.first.map(String.init) ?? "17"
        let minor = version.dropFirst().first.map(String.init) ?? "0"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(major)_\(minor) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }
}

// MARK: - WebKit delegates

extension VersoConnectViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSession()
    }
}

extension VersoConnectViewController: WKUIDelegate {
    /// Sign-in buttons that open a popup are loaded in place instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

extension VersoConnectViewController: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.checkForSession() }
    }
}
