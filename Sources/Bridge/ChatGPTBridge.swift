import Foundation
import WebKit

/// Drives ChatGPT's web endpoints from inside a warmed, logged-in WKWebView so
/// requests inherit the real browser context (cleared Cloudflare + cookies).
///
/// Validated flow (see docs/plans/...-design.md):
///   cookies.json → load chatgpt.com → /api/auth/session (bearer)
///   → /backend-api/transcribe  → /backend-api/conversation (cleanup)
@MainActor
final class ChatGPTBridge: NSObject, WKNavigationDelegate {

    enum BridgeError: LocalizedError {
        case notReady
        case noAccount                 // session expired / cookies invalid
        case http(Int, String)
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .notReady:        return "Bridge not ready (page still loading)"
            case .noAccount:       return "Not logged in — re-export cookies.json"
            case .http(let c, let b): return "HTTP \(c): \(b)"
            case .badResponse(let s): return "Unexpected response: \(s)"
            }
        }
    }

    let webView: WKWebView
    private(set) var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private var cachedToken: String?
    private var tokenFetchedAt: Date = .distantPast
    private let tokenTTL: TimeInterval = 240

    /// Last time the bridge did real work, and last time we recycled the page.
    /// Used to reclaim WebContent memory when the app has been idle (see `recycleIfIdle`).
    private var lastActivity = Date()
    private var lastReload = Date()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Lifecycle

    /// Inject cookies and load chatgpt.com. Safe to call again to re-warm.
    func start(cookiesPath: String) async throws {
        isReady = false
        let cookies = try CookieLoader.load(from: cookiesPath)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in cookies { await store.setCookie(c) }
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyWaiters.append(cont)
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        Task { @MainActor in
            // small settle for any CF/app bootstrapping
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.isReady = true
            self.resumeWaiters()
        }
    }

    // If a navigation fails we must still resume anyone parked in `waitUntilReady()`,
    // otherwise those continuations (and their captured state) leak and `warmBridge` hangs.
    nonisolated func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeWaiters() }
    }

    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeWaiters() }
    }

    private func resumeWaiters() {
        let waiters = readyWaiters; readyWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// Reclaim WebContent-process memory by reloading the warmed page after a long
    /// idle stretch. ChatGPT's SPA never frees what it accumulates across dictations,
    /// so a fresh load bounds the growth. No-op while busy / recently used so it never
    /// interrupts an in-flight request. Cookies persist in the data store, so the
    /// reloaded page stays logged in.
    func recycleIfIdle(idleThreshold: TimeInterval = 600) {
        guard isReady else { return }   // mid-load: leave it alone
        let now = Date()
        guard now.timeIntervalSince(lastActivity) > idleThreshold,
              now.timeIntervalSince(lastReload) > idleThreshold else { return }
        lastReload = now
        isReady = false
        cachedToken = nil
        webView.reload()
    }

    // MARK: - Auth

    @discardableResult
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = cachedToken, Date().timeIntervalSince(tokenFetchedAt) < tokenTTL {
            return t
        }
        let js = """
        const r = await fetch('/api/auth/session', { credentials: 'include' });
        const s = await r.json().catch(() => ({}));
        return JSON.stringify({
          status: r.status,
          token: (s && s.accessToken) || null,
          user: (s && s.user && (s.user.email || s.user.id)) || null
        });
        """
        let json = try await runJSON(js, args: [:])
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw BridgeError.noAccount
        }
        cachedToken = token
        tokenFetchedAt = Date()
        return token
    }

    // MARK: - Transcribe

    /// POST audio to /backend-api/transcribe. Returns the raw transcript text.
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard isReady else { throw BridgeError.notReady }
        lastActivity = Date()
        let data = try Data(contentsOf: audioURL)
        let b64 = data.base64EncodedString()
        let name = audioURL.lastPathComponent
        let mime = audioURL.pathExtension == "wav" ? "audio/wav" : "audio/mp4"

        func attempt(_ token: String) async throws -> [String: Any] {
            let js = """
            const bin = atob(audioB64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const blob = new Blob([bytes], { type: mime });
            const fd = new FormData();
            fd.append('file', blob, filename);
            fd.append('language', language);
            fd.append('duration_ms', String(durationMs));
            const res = await fetch('/backend-api/transcribe', {
              method: 'POST', body: fd, credentials: 'include',
              headers: { 'Authorization': 'Bearer ' + token, 'oai-language': language }
            });
            return JSON.stringify({ status: res.status, body: (await res.text()).slice(0, 4000) });
            """
            return try await runJSON(js, args: [
                "audioB64": b64, "filename": name, "mime": mime,
                "language": language, "durationMs": 5000, "token": token,
            ])
        }

        var token = try await accessToken()
        var res = try await attempt(token)
        var status = (res["status"] as? Int) ?? 0
        // 401/429-no-account → token stale; refresh once and retry.
        if status == 401 || status == 429 {
            token = try await accessToken(forceRefresh: true)
            res = try await attempt(token)
            status = (res["status"] as? Int) ?? 0
        }
        guard status == 200, let body = res["body"] as? String else {
            throw BridgeError.http(status, (res["body"] as? String) ?? "")
        }
        guard let bdata = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bdata) as? [String: Any],
              let text = obj["text"] as? String else {
            throw BridgeError.badResponse(body)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup (LLM pass)

    /// Send `prompt + raw` to /backend-api/conversation; return the cleaned text.
    func cleanup(raw: String, prompt: String, model: String, language: String) async throws -> String {
        guard isReady else { throw BridgeError.notReady }
        lastActivity = Date()
        let message = Prompts.cleanupMessage(prompt: prompt, raw: raw)
        let token = try await accessToken()
        let js = """
        const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
          : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
              const r = Math.random()*16|0; return (c==='x'?r:(r&3|8)).toString(16); }));
        const body = {
          action: 'next',
          messages: [{ id: uuid(), author: { role: 'user' },
            content: { content_type: 'text', parts: [message] } }],
          parent_message_id: 'client-created-root',
          model: model,
          timezone_offset_min: new Date().getTimezoneOffset(),
          history_and_training_disabled: true,
          conversation_mode: { kind: 'primary_assistant' }
        };
        const res = await fetch('/backend-api/conversation', {
          method: 'POST', credentials: 'include',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token,
                     'accept': 'text/event-stream', 'oai-language': language },
          body: JSON.stringify(body)
        });
        if (!res.ok) return JSON.stringify({ status: res.status, error: (await res.text()).slice(0, 400) });
        const ctext = await res.text();
        let answer = '';
        for (const line of ctext.split('\\n')) {
          if (!line.startsWith('data: ')) continue;
          const p = line.slice(6);
          if (p === '[DONE]') break;
          try {
            const o = JSON.parse(p);
            const m = o.message || (o.v && o.v.message);
            if (m && m.author && m.author.role === 'assistant'
                && m.content && Array.isArray(m.content.parts)) {
              const s = m.content.parts.join('');
              if (s && s.length >= answer.length) answer = s;
            }
          } catch (e) {}
        }
        return JSON.stringify({ status: res.status, text: answer });
        """
        let json = try await runJSON(js, args: ["message": message, "model": model, "token": token, "language": language])
        let status = (json["status"] as? Int) ?? 0
        guard status == 200 else {
            throw BridgeError.http(status, (json["error"] as? String) ?? "")
        }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BridgeError.badResponse("empty cleanup result") }
        return text
    }

    // MARK: - JS helper

    /// Run a JS function body that returns a JSON string; decode to a dictionary.
    private func runJSON(_ body: String, args: [String: Any]) async throws -> [String: Any] {
        let result = try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        guard let s = result as? String, let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw BridgeError.badResponse(String(describing: result))
        }
        return obj
    }
}
