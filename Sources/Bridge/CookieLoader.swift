import Foundation

/// Parses a Cookie-Editor style `cookies.json` export into `HTTPCookie`s.
enum CookieLoader {
    struct Entry: Decodable {
        let domain: String
        let name: String
        let value: String
        let path: String?
        let secure: Bool?
        let httpOnly: Bool?
        let expirationDate: Double?
        let session: Bool?
    }

    enum LoadError: LocalizedError {
        case unreadable(String)
        case unparseable
        var errorDescription: String? {
            switch self {
            case .unreadable(let p): return "Can't read cookies file at \(p)"
            case .unparseable: return "cookies.json is not in the expected format"
            }
        }
    }

    /// Returns cookies scoped to chatgpt.com (skips ws./other subdomains we don't load).
    static func load(from path: String) throws -> [HTTPCookie] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError.unreadable(path)
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw LoadError.unparseable
        }
        return entries.compactMap { e in
            // Only chatgpt.com-scoped cookies; skip ws.chatgpt.com (not navigated).
            guard e.domain.hasSuffix("chatgpt.com"), !e.domain.hasPrefix("ws") else { return nil }
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
    }

    /// Best-effort device id from the `oai-did` cookie (used as oai-device-id header).
    static func deviceId(from path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return entries.first(where: { $0.name == "oai-did" })?.value
    }
}
