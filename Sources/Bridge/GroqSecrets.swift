import Foundation
import Security

/// Resolves and persists the Groq API key.
///
/// Lookup order (first hit wins):
///   1. Keychain  — written from the Settings SecureField (survives reinstalls,
///      works for shipped `.dmg` users).
///   2. `GROQ_API_KEY` process environment variable.
///   3. `.env` file (`KEY=VALUE`) in the current working directory, then `$HOME/.env`.
///      Accepts `GROQ_API_KEY` or `GROQ_API`. Convenient for `make run` in dev.
enum GroqSecrets {
    private static let service = "com.lizardtype.groq"
    private static let account = "api-key"

    /// The effective key from any source, or nil if none is available.
    static func apiKey() -> String? {
        if let k = keychainKey(), !k.isEmpty { return k }
        if let k = environmentKey(), !k.isEmpty { return k }
        return nil
    }

    /// True if a key exists outside the Keychain (env / .env) — used by the UI to
    /// tell the user a key was auto-detected even though the field is empty.
    static func hasEnvKey() -> Bool {
        (environmentKey()?.isEmpty == false)
    }

    /// The key currently stored in the Keychain (the editable Settings value).
    static func keychainKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Write (or clear, when empty) the key in the Keychain.
    static func setKeychainKey(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - Environment / .env

    private static func environmentKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let k = env["GROQ_API_KEY"], !k.isEmpty { return k }
        if let k = env["GROQ_API"], !k.isEmpty { return k }
        let fm = FileManager.default
        let candidates = [
            fm.currentDirectoryPath + "/.env",
            (fm.homeDirectoryForCurrentUser.path) + "/.env",
        ]
        for path in candidates {
            if let k = parseEnvFile(path) { return k }
        }
        return nil
    }

    /// Minimal `.env` parser: returns the value of GROQ_API_KEY / GROQ_API.
    private static func parseEnvFile(_ path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard name == "GROQ_API_KEY" || name == "GROQ_API" else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes.
            if value.count >= 2, let f = value.first, (f == "\"" || f == "'"), value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { return value }
        }
        return nil
    }
}
