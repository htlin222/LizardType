// transcribe_spike.swift
// Proves the core hypothesis: a WKWebView with cookies.json injected can pass
// Cloudflare and successfully POST to /backend-api/transcribe from the page's
// own JS context (real browser TLS + cookies attached).
//
// Build:  swiftc -O transcribe_spike.swift -o /tmp/transcribe_spike -framework WebKit -framework AppKit
// Run:    /tmp/transcribe_spike <cookies.json> <audio.m4a> [language]

import AppKit
import WebKit
import Foundation

struct CookieEntry: Decodable {
    let domain: String
    let name: String
    let value: String
    let path: String?
    let secure: Bool?
    let httpOnly: Bool?
    let expirationDate: Double?
    let session: Bool?
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: transcribe_spike <cookies.json> <audio.m4a> [language]") }
let cookiesPath = args[1]
let audioPath = args[2]
let language = args.count >= 4 ? args[3] : "zh"

guard let cookieData = FileManager.default.contents(atPath: cookiesPath) else { die("cannot read cookies file") }
guard let entries = try? JSONDecoder().decode([CookieEntry].self, from: cookieData) else { die("cannot parse cookies.json") }

guard let audioData = FileManager.default.contents(atPath: audioPath) else { die("cannot read audio file") }
let audioB64 = audioData.base64EncodedString()
let audioName = (audioPath as NSString).lastPathComponent
let mime = audioPath.hasSuffix(".wav") ? "audio/wav" : (audioPath.hasSuffix(".webm") ? "audio/webm" : "audio/mp4")

func makeCookie(_ e: CookieEntry) -> HTTPCookie? {
    var props: [HTTPCookiePropertyKey: Any] = [
        .name: e.name,
        .value: e.value,
        .domain: e.domain,
        .path: e.path ?? "/",
    ]
    if e.secure == true { props[.secure] = "TRUE" }
    if let exp = e.expirationDate, e.session != true {
        props[.expires] = Date(timeIntervalSince1970: exp)
    }
    return HTTPCookie(properties: props)
}

class Runner: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var didRunFetch = false
    let entries: [CookieEntry]
    let audioB64: String
    let audioName: String
    let mime: String
    let language: String

    init(entries: [CookieEntry], audioB64: String, audioName: String, mime: String, language: String) {
        self.entries = entries
        self.audioB64 = audioB64
        self.audioName = audioName
        self.mime = mime
        self.language = language
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = entries.compactMap { makeCookie($0) }
        var remaining = cookies.count
        print("[spike] injecting \(cookies.count) cookies…")
        if remaining == 0 { load() ; return }
        for c in cookies {
            store.setCookie(c) {
                remaining -= 1
                if remaining == 0 { self.load() }
            }
        }
    }

    func load() {
        print("[spike] loading https://chatgpt.com/ …")
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        print("[spike] didFinish navigation. url=\(wv.url?.absoluteString ?? "?") title=\(wv.title ?? "?")")
        guard !didRunFetch else { return }
        didRunFetch = true
        // Give the page a moment to settle / clear any CF interstitial.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.runFetch() }
    }

    func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
        print("[spike] didFail: \(error.localizedDescription)")
    }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        print("[spike] didFailProvisional: \(error.localizedDescription)")
    }

    func runFetch() {
        print("[spike] running transcribe fetch from page context…")
        let js = """
        const out = {};
        try {
          // 1) Who are we? Get the access token the web app uses for backend-api.
          const sres = await fetch("/api/auth/session", { credentials: "include" });
          const sess = await sres.json().catch(() => ({}));
          out.session_status = sres.status;
          out.user = sess && sess.user ? (sess.user.email || sess.user.id || "?") : null;
          out.hasAccessToken = !!(sess && sess.accessToken);
          const token = sess && sess.accessToken;

          // 2) Build audio + call transcribe WITH bearer token.
          const b64 = "\(audioB64)";
          const bin = atob(b64);
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          const blob = new Blob([bytes], { type: "\(mime)" });
          const fd = new FormData();
          fd.append("file", blob, "\(audioName)");
          fd.append("language", "\(language)");
          fd.append("duration_ms", "3000");
          const headers = { "oai-language": "\(language)" };
          if (token) headers["Authorization"] = "Bearer " + token;
          const res = await fetch("/backend-api/transcribe", {
            method: "POST", body: fd, credentials: "include", headers
          });
          out.transcribe_status = res.status;
          const tjson = await res.json().catch(() => ({}));
          out.transcribe_text = tjson.text || "";

          // 3) LLM cleanup pass via the conversation endpoint (ephemeral).
          const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
              : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => {
                  const r = Math.random()*16|0; return (c==='x'?r:(r&0x3|0x8)).toString(16); }));
          const prompt = "你是逐字稿整理助手。將以下語音轉錄文字加上標點、移除口頭禪，直接輸出整理後的文字，不要解釋：\\n\\n" + (tjson.text || "");
          const body = {
            action: "next",
            messages: [{ id: uuid(), author: { role: "user" },
              content: { content_type: "text", parts: [prompt] } }],
            parent_message_id: "client-created-root",
            model: "gpt-5-5",
            timezone_offset_min: -480,
            history_and_training_disabled: true,
            conversation_mode: { kind: "primary_assistant" }
          };
          const cres = await fetch("/backend-api/conversation", {
            method: "POST", credentials: "include",
            headers: { "Content-Type": "application/json", "Authorization": "Bearer " + token,
                       "accept": "text/event-stream", "oai-language": "\(language)" },
            body: JSON.stringify(body)
          });
          out.chat_status = cres.status;
          out.chat_ct = cres.headers.get("content-type");
          const ctext = await cres.text();
          out.chat_len = ctext.length;
          // Parse SSE: find the last assistant message text snapshot.
          let answer = "";
          for (const line of ctext.split("\\n")) {
            if (!line.startsWith("data: ")) continue;
            const payload = line.slice(6);
            if (payload === "[DONE]") break;
            try {
              const obj = JSON.parse(payload);
              const msg = obj.message || (obj.v && obj.v.message);
              if (msg && msg.author && msg.author.role === "assistant"
                  && msg.content && Array.isArray(msg.content.parts)) {
                const p = msg.content.parts.join("");
                if (p && p.length >= answer.length) answer = p;
              }
            } catch (e) {}
          }
          out.cleaned_text = answer;
          if (!answer) out.chat_tail = ctext.slice(-500);
          return JSON.stringify(out);
        } catch (e) {
          out.error = String(e);
          return JSON.stringify(out);
        }
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("[spike] RESULT: \(String(describing: value))")
            case .failure(let err):
                print("[spike] JS error: \(err)")
            }
            print("[spike] done.")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner(entries: entries, audioB64: audioB64, audioName: audioName, mime: mime, language: language)
runner.start()

// Safety timeout
DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
    print("[spike] TIMEOUT after 75s")
    exit(2)
}
app.run()
