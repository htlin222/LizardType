# VoiceType (working title) — Design Doc

**Date:** 2026-05-26
**Goal:** A native macOS dictation app (ZeroType-parity) that uses the user's
ChatGPT web session (`cookies.json`) — no paid API key — to transcribe speech
and clean it up with an LLM, then auto-type the result at the cursor.

Reference design: [ZeroType](https://github.com/nick1ee/ZeroType) (Flutter; we
reimplement natively in Swift and swap its API layer for a cookie-based WKWebView
bridge to ChatGPT).

---

## 1. Validated findings (spike: `spike/transcribe_spike.swift`)

All confirmed empirically against the live account on 2026-05-26:

| # | Hypothesis | Result |
|---|-----------|--------|
| 1 | A hidden `WKWebView` with `cookies.json` injected passes Cloudflare (no challenge) | ✅ loads as logged-in ChatGPT |
| 2 | `/backend-api/*` needs a bearer token, not just cookies | ✅ token from `GET /api/auth/session` (`.accessToken`) |
| 3 | `POST /backend-api/transcribe` accepts native **m4a** (AAC) | ✅ returns `{text, asset_pointer, asset_format:"m4a"}` |
| 4 | `POST /backend-api/conversation` (LLM cleanup) works from the warmed WebView with **only** the bearer token — sentinel proof-of-work / Turnstile / conduit tokens NOT required | ✅ `200 text/event-stream`, real reply |
| 5 | Cleanup produces ZeroType-style output (Traditional Chinese + 晶晶體 spacing) | ✅ |

**Auth model:** cookies authenticate the NextAuth session → `/api/auth/session`
mints a short-lived `accessToken` → sent as `Authorization: Bearer` to
`/backend-api/*`. The WebView must call `/api/auth/session` (re-fetch when stale).

---

## 2. Architecture

Native **Swift / SwiftUI** menu-bar (LSUIElement) app. Five subsystems:

```
┌─────────────────────────────────────────────────────────────┐
│  HotkeyManager (CGEventTap)                                   │
│    hold key down → start;  release → stop                     │
│        │                                                       │
│        ▼                                                       │
│  AudioRecorder (AVAudioEngine/AVAudioRecorder → m4a 16kHz)    │
│    + amplitude metering → RecordingOverlay (floating NSPanel) │
│        │ (file URL)                                            │
│        ▼                                                       │
│  ChatGPTBridge  ── owns a hidden WKWebView ──────────────┐    │
│    1. inject cookies, load chatgpt.com (once, at launch) │    │
│    2. getAccessToken() via /api/auth/session             │    │
│    3. transcribe(m4a) → raw text                         │    │
│    4. cleanup(raw, prompt) → formatted text (SSE parse)  │    │
│        │ (final text)                                     │    │
│        ▼                                                  │    │
│  TextInserter (NSPasteboard + synthesized ⌘V via CGEvent)│    │
└──────────────────────────────────────────────────────────────┘
  SettingsStore: cookies.json path, hotkey, language, model,
                 cleanup on/off, prompt, launch-at-login
```

### ChatGPTBridge (the core, JS-in-WebView)
- Single long-lived offscreen `WKWebView`, created at launch, cookies injected
  into `httpCookieStore`, then `load(chatgpt.com)`. Stays warm.
- All network calls run as `callAsyncJavaScript` inside the page origin (so they
  inherit the cleared-Cloudflare browser context + cookies).
- `transcribe`: build `FormData{file, language, duration_ms}` → `POST
  /backend-api/transcribe` with `Authorization: Bearer`. Return `.text`.
- `cleanup`: `POST /backend-api/conversation` with
  `{action:next, messages:[{role:user, parts:[prompt+rawText]}],
    parent_message_id:"client-created-root", model, conversation_mode:primary_assistant,
    history_and_training_disabled:true}`, `accept:text/event-stream`. Parse SSE
  for the last assistant `message.content.parts` snapshot.
- Audio bytes crossing Swift→JS: base64 string argument (fine for ≤ a few MB / 1-min clips).

### Cleanup prompt
Adapt ZeroType's `SpeechToText.prompt` (MIT) — filler removal, 後者為準
self-correction, smart punctuation, English casing, half-width spacing,
auto-bullets, blank-audio guard. Editable in Settings.

---

## 3. Permissions (Info.plist + TCC)
- **Microphone** (`NSMicrophoneUsageDescription`) — recording.
- **Accessibility** — synthesize ⌘V and capture the global hotkey via CGEventTap.
- Settings page shows live status of both + deep-link buttons to System Settings.

## 4. Error handling
- `cookies.json` missing/invalid → banner + open Settings.
- `/api/auth/session` returns no user/token (expired cookies) → "Session expired,
  re-export cookies.json" notification; cache token, re-fetch on 401.
- Cloudflare challenge resurfaces (rare; risk-based) → reload WebView once, retry.
- **Sentinel enforcement turns on** for `conversation` (currently off) → detect
  4xx with sentinel error → fall back to *raw transcription only* for that turn +
  notify. (Stretch: UI-driving fallback.)
- Empty/very short audio (< ~400ms) → skip; guard against Whisper hallucination.
- Cleanup failure/timeout → paste raw transcription instead (never lose the text).

## 5. Risks & caveats
- **Sentinel could start requiring PoW/Turnstile** on `conversation`. Today it
  doesn't from the warmed session, but it's risk-based. Mitigation: graceful
  fallback to raw transcription (transcribe has no sentinel).
- **Token/cookie expiry**: session token ~3 months; access token short-lived
  (auto-refetched). Manual cookies.json re-export when the session dies.
- **ToS**: automating the consumer endpoints with session cookies is a personal,
  single-account use; not for distribution/resale.
- `history_and_training_disabled:true` keeps cleanup turns ephemeral (not saved
  to chat history) — to verify during build.

## 6. Phased implementation
- **P0 — Bridge package** (de-risked ✅): `ChatGPTBridge` as a reusable class
  (cookie inject, token, transcribe, cleanup). Port spike → real class + tests.
- **P1 — Dictation core**: hotkey (hold) → record m4a → transcribe → paste. Menu
  bar + permission prompts. *Usable raw dictation.*
- **P2 — Cleanup pass**: wire `conversation` cleanup with the adapted prompt;
  toggle + prompt editor in Settings. *Full ZeroType parity.*
- **P3 — Polish**: recording overlay (waveform), settings (hotkey picker, model,
  language, launch-at-login), sounds, history (optional).

## 7. Out of scope (YAGNI for v1)
Multi-account, Gemini/other providers, cost tracking (it's free), custom
dictionary (the prompt covers most), Windows/Linux.
