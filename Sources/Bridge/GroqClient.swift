import Foundation

/// Groq backend (OpenAI-compatible REST). Key-driven, no WebView.
///   transcribe → POST /openai/v1/audio/transcriptions  (whisper-large-v3-turbo)
///   cleanup    → POST /openai/v1/chat/completions       (llama-3.3-70b-versatile)
/// Auth: `Authorization: Bearer <GROQ_API_KEY>` (see GroqSecrets).
@MainActor
final class GroqClient: SpeechProvider {

    enum GroqError: LocalizedError {
        case noKey
        case http(Int, String)
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noKey:              return "No Groq API key — paste one in Settings or set GROQ_API_KEY in .env"
            case .http(let c, let b): return "Groq HTTP \(c): \(b)"
            case .badResponse(let s): return "Unexpected Groq response: \(s)"
            }
        }
    }

    private let base = URL(string: "https://api.groq.com/openai/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    private func key() throws -> String {
        guard let k = GroqSecrets.apiKey() else { throw GroqError.noKey }
        return k
    }

    /// Cheap auth/connectivity check used at warm-up. Throws on a missing key or
    /// an auth failure; tolerates other transient errors (returns without throwing).
    func validate() async throws {
        _ = try key()   // surface missing-key immediately
    }

    // MARK: - Transcribe

    func transcribe(audioURL: URL, language: String) async throws -> String {
        let apiKey = try key()
        let model = AppSettings.shared.groqTranscribeModel
        let fileData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent
        let mime = audioURL.pathExtension == "wav" ? "audio/wav" : "audio/mp4"

        let boundary = "LizardType-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        field("model", model)
        if !language.isEmpty { field("language", language) }
        field("response_format", "json")
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: base.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let obj = try await sendJSON(req)
        guard let text = obj["text"] as? String else {
            throw GroqError.badResponse(String(describing: obj))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup

    func cleanup(raw: String, prompt: String, model: String, language: String) async throws -> String {
        let apiKey = try key()
        let message = Prompts.cleanupMessage(prompt: prompt, raw: raw)
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "user", "content": message]],
        ]
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let obj = try await sendJSON(req)
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw GroqError.badResponse(String(describing: obj))
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GroqError.badResponse("empty cleanup result") }
        return text
    }

    // MARK: - HTTP helper

    private func sendJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let snippet = String(data: data.prefix(800), encoding: .utf8) ?? ""
            throw GroqError.http(status, snippet)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GroqError.badResponse(String(data: data.prefix(800), encoding: .utf8) ?? "")
        }
        return obj
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
