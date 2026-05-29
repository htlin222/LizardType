# Groq API as an alternative provider — Design

Date: 2026-05-29
Status: accepted

## Problem

LizardType transcribes + cleans up speech through a logged-in ChatGPT
`WKWebView` (no API key, runs on the user's subscription). That is the only
backend. Some users have a Groq API key (`GROQ_API_KEY` in `.env`) and want a
fast, key-driven alternative that does not depend on a ChatGPT web session or
`cookies.json`.

[Groq](https://console.groq.com/docs/quickstart) exposes OpenAI-compatible REST
endpoints for both operations LizardType needs:

- Transcription — `POST https://api.groq.com/openai/v1/audio/transcriptions`
  (`whisper-large-v3-turbo`, `whisper-large-v3`)
- Cleanup (chat) — `POST https://api.groq.com/openai/v1/chat/completions`
  (`llama-3.3-70b-versatile`, …)

Both authenticate with `Authorization: Bearer <key>`.

## Decision

Add Groq as a **selectable provider** covering **both** transcription and
cleanup. The user picks the provider in Settings; ChatGPT Web stays the default
so existing behavior is unchanged.

### Provider abstraction

```swift
@MainActor
protocol SpeechProvider: AnyObject {
    func transcribe(audioURL: URL, language: String) async throws -> String
    func cleanup(raw: String, prompt: String, model: String, language: String) async throws -> String
}
```

- `ChatGPTBridge` already has these exact methods → conform as-is.
- `GroqClient` (new) implements them over `URLSession`. It reads its transcribe
  model from settings; the cleanup `model` is passed in by `AppState`.

`AppState` exposes a computed `activeProvider` and routes the recording pipeline
through it. Warm-up is provider-aware:

- ChatGPT → load the WebView, verify login (existing flow).
- Groq → no WebView; verify an API key is resolvable, set `.ready`.

### Key resolution (`GroqSecrets`)

Order, first hit wins:

1. **Keychain** (`service = com.lizardtype.groq`, `account = api-key`) — written
   from the Settings `SecureField`.
2. **`GROQ_API_KEY`** process environment variable.
3. **`.env` file** — `KEY=VALUE` parse of `.env` in the current working
   directory, then `$HOME/.env`. Supports `GROQ_API_KEY` and `GROQ_API`.

(1) makes it work for shipped `.dmg` users; (2)/(3) make `make run` "just work"
during development when a `.env` is present.

### Settings (UserDefaults; key is NOT stored in UserDefaults)

- `provider: APIProvider` (`chatgpt` | `groq`), default `chatgpt`
- `groqTranscribeModel: String`, default `whisper-large-v3-turbo`
- `groqCleanupModel: String`, default `llama-3.3-70b-versatile`

The API key lives in the Keychain only.

### UI

General tab gains a **Provider** picker. When `groq` is selected it reveals:

- a `SecureField` for the API key (writes Keychain), with a hint showing whether
  a key was detected from the environment / `.env`,
- transcribe-model and cleanup-model fields.

Menu and Diagnostics labels are generalized from "ChatGPT" to provider-neutral
wording.

## Non-goals (YAGNI)

- Streaming responses, model auto-discovery, per-provider prompt variants.
- Sandbox/entitlement changes — outbound HTTPS works for a non-sandboxed
  ad-hoc-signed app; Groq is HTTPS so no ATS exception is required.

## Release

Bump `CFBundleShortVersionString` `0.1.0 → 0.2.0`, update README, verify
`make build`, then push tag `v0.2.0`. The existing `release.yml` workflow builds
the `.dmg` and publishes the GitHub Release on `v*` tags.
