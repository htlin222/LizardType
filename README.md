# LizardType 🦎⌨️

[![CI](https://github.com/htlin222/LizardType/actions/workflows/ci.yml/badge.svg)](https://github.com/htlin222/LizardType/actions/workflows/ci.yml)
[![Release](https://github.com/htlin222/LizardType/actions/workflows/release.yml/badge.svg)](https://github.com/htlin222/LizardType/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/htlin222/LizardType?sort=semver)](https://github.com/htlin222/LizardType/releases/latest)
![Platform](https://img.shields.io/badge/macOS-Apple%20Silicon-blue)

A native macOS push-to-talk dictation app. Hold a key, speak, release — your
speech is transcribed and (optionally) cleaned up by ChatGPT, then pasted at your
cursor in any app.

LizardType supports two interchangeable **API providers** (pick one in Settings):

- **ChatGPT Web** (default) — uses **your existing ChatGPT web session**
  (`cookies.json`) via a hidden, logged-in `WKWebView`, so transcription and
  cleanup run on your ChatGPT subscription. No API key, no extra cost. Unlike
  [ZeroType](https://github.com/nick1ee/ZeroType), which needs a paid API key.
- **Groq API** — uses [Groq](https://console.groq.com/docs/quickstart)'s
  OpenAI-compatible endpoints (Whisper for transcription, Llama/etc. for
  cleanup). Fast and key-driven; no ChatGPT session needed. Just paste your
  `GROQ_API_KEY`.

## How it works

```
                                  ┌─ ChatGPT Web (cookies.json) ─ WKWebView
hold trigger key ─▶ record m4a ─▶─┤    ├─ POST /backend-api/transcribe   → raw text
                                  │    └─ POST /backend-api/conversation → cleaned text
                                  │
                                  └─ Groq API (GROQ_API_KEY) ─ URLSession
                                       ├─ POST /openai/v1/audio/transcriptions → raw text
                                       └─ POST /openai/v1/chat/completions     → cleaned text
                                                                          │
                                            paste at cursor (⌘V) ◀────────┘
```

In **ChatGPT Web** mode the WebView runs real WebKit on your Mac, so it passes
Cloudflare like Safari and inherits your session; `/api/auth/session` provides
the bearer token the `/backend-api/*` calls need.

### Using the Groq provider

1. Get an API key at [console.groq.com](https://console.groq.com).
2. **Settings → General → Provider → Groq API**, then paste the key (stored in
   your macOS Keychain). Alternatively, leave it blank and set `GROQ_API_KEY` in
   a `.env` file (current directory or `$HOME/.env`) — handy during `make run`.
3. Optionally tweak the transcribe model (`whisper-large-v3-turbo`) and cleanup
   model (`llama-3.3-70b-versatile`).

Verify the whole pipeline from the terminal:

```bash
GROQ_API_KEY=gsk_… build/LizardType.app/Contents/MacOS/LizardType \
  --selftest --groq /path/to/clip.m4a
```

## Download

Grab the latest **`.dmg`** from the
[Releases page](https://github.com/htlin222/LizardType/releases/latest), open it, and
drag **LizardType** to Applications.

The app is **ad-hoc signed** (no Apple Developer account), so Gatekeeper blocks the
first launch. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/LizardType.app
```

…or right-click **LizardType** → **Open** → **Open**. Then grant Accessibility +
Microphone (see [First-run setup](#first-run-setup)).

## Build

Requires only the Xcode **Command Line Tools** (no full Xcode); builds for
**Apple Silicon**, targeting **macOS 14+** (Sonoma and later). It compiles
against whatever SDK is installed, but the deployment target is pinned to
macOS 14 so the app runs on older Macs — override with `MACOS_TARGET=…`.

```bash
make build      # compile + sign  → build/LizardType.app
make run        # build, then launch
make dmg        # build + package → build/LizardType-<version>.dmg
make clean
```

`make help` lists every target; the low-level script is still `bash build.sh`.
To target an older macOS, override the deployment target:
`MACOS_TARGET=arm64-apple-macosx14.0 make build`.

Releases are built and published automatically by GitHub Actions: push a tag like
`v0.1.0` and the **Release** workflow attaches the `.dmg` to a GitHub Release.

## First-run setup

1. **cookies.json** — export your chatgpt.com cookies (e.g. the Cookie-Editor
   extension → Export → JSON). In LizardType **Settings → General**, set the
   path (or pre-set it: `defaults write com.lizardtype.app cookiesPath /path/to/cookies.json`).
   Click **Reconnect**; status should read **Ready**.
2. **Accessibility** — Settings → Permissions → grant Accessibility (needed to
   capture the global hotkey and to paste). **macOS quits LizardType the moment
   you flip the switch** — that's normal; it relaunches itself within a couple of
   seconds (launch-at-login is on by default) and the menu-bar icon comes back.
3. **Microphone** — granted on your first recording.

## Use

Hold the trigger (default **Right Option ⌥**), speak, release. The text appears
at your cursor. Change the trigger, language, model, and the cleanup prompt in
Settings. Flip **Clean up with ChatGPT** off — from the menu bar or
Settings → Cleanup — to paste the raw transcript instead (it's on by default).

## Notes & limits

- **Session lifetime**: the ChatGPT session token lasts ~3 months. When it
  expires, re-export `cookies.json` and click Reconnect. (Status shows
  "Session expired" on failure.)
- **Cleanup fallback**: if the chat endpoint ever rejects the cleanup (OpenAI's
  "sentinel" anti-bot, currently not enforced from the warmed session), the app
  pastes the **raw transcription** instead — you never lose text.
- **Code signing**: official release `.dmg`s are signed with a stable self-signed
  certificate, so your Accessibility grant **persists across updates** — grant
  once. They're not Apple-notarized, so you still clear the quarantine flag once
  on first install (see Download). Local `make build` uses your own self-signed
  cert (`bash setup-cert.sh`) for the same persistence.
- This automates ChatGPT's consumer endpoints with your own session — intended
  for **personal, single-account** use, not distribution.

## Troubleshooting

- **Menu-bar icon vanished after granting Accessibility / it won't come back:**
  macOS SIGKILLs the app on a permission change. With launch-at-login on (default)
  it relaunches within ~2s. If it doesn't, reopen LizardType from Applications, or
  check **Settings → General → "Launch at login & auto-restart"** is on. You can
  also hit **Relaunch LizardType** there.
- **Hotkey stopped working after an update (rare):** if you ever ran an old ad-hoc
  build, a stale Accessibility entry can shadow the new one. Reset it:
  ```bash
  tccutil reset Accessibility com.lizardtype.app
  ```
  then reopen LizardType and re-grant. (System Settings → Privacy & Security →
  Accessibility → select LizardType → "−" also clears it.)
- **Icon hidden behind the notch:** ⌘-drag menu-bar items to reorder, or use a
  menu-bar manager (Ice/Bartender) to reveal it.

## Release signing (maintainers)

Official releases are signed with a stable self-signed cert so end users keep
their Accessibility grant across updates — **free, no Apple Developer account**.
One-time setup:

```bash
bash scripts/release-signing-setup.sh   # generates the cert + prints the secrets
```

Add the two printed secrets to the repo (Settings → Secrets and variables →
Actions): `RELEASE_CERT_P12_BASE64` and `RELEASE_CERT_PASSWORD`. The release
workflow imports them and signs every build with that identity. Without the
secrets, releases fall back to ad-hoc signing (forks still build fine).

## Layout

```
Sources/
  LizardTypeApp.swift        @main, MenuBarExtra + Settings scene, AppDelegate
  AppState.swift             orchestrator: hotkey → record → transcribe → cleanup → paste
  Bridge/ChatGPTBridge.swift WKWebView bridge (cookies, token, transcribe, cleanup)
  Bridge/CookieLoader.swift  cookies.json → HTTPCookie
  Audio/AudioRecorder.swift  AVAudioRecorder → m4a + level metering
  Input/HotkeyManager.swift  CGEventTap push-to-talk
  Input/TextInserter.swift   NSPasteboard + synthesized ⌘V
  Input/PermissionsManager.swift  mic + accessibility
  Lifecycle/LaunchManager.swift   launchd keep-alive + launch-at-login (SMAppService)
  UI/RecordingOverlay.swift  floating waveform panel
  UI/SettingsView.swift      settings window
  Model/Settings.swift       UserDefaults-backed (AppSettings)
  Model/Prompts.swift        default cleanup prompt (adapted from ZeroType, MIT)
spike/transcribe_spike.swift the standalone proof that validated the bridge
docs/plans/                  design doc
```

## License

[MIT](LICENSE) © Hsiehting Lin. The default cleanup prompt is adapted from
[ZeroType](https://github.com/nick1ee/ZeroType) (MIT).
