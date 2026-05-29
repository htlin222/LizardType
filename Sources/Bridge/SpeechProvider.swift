import Foundation

/// A backend that can transcribe recorded audio and (optionally) clean it up
/// with an LLM. Implemented by `ChatGPTBridge` (WebView) and `GroqClient` (REST).
@MainActor
protocol SpeechProvider: AnyObject {
    /// Transcribe the audio file. Returns the raw transcript text.
    func transcribe(audioURL: URL, language: String) async throws -> String

    /// Run the cleanup LLM pass over `raw` using `prompt`. Returns cleaned text.
    func cleanup(raw: String, prompt: String, model: String, language: String) async throws -> String
}

extension ChatGPTBridge: SpeechProvider {}
