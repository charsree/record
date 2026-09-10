# Record — a local-first macOS meeting assistant

Record captures your meetings entirely on your Mac — microphone, system audio, screen-share OCR — transcribes them with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) locally, and lets you chat with your transcripts via [Kiro](https://kiro.dev). Nothing leaves your machine.

- **Local-first.** Audio, transcripts, and chats stay on your disk, encrypted with an AES-GCM key generated on first launch.
- **Multi-source capture.** Microphone + Zoom / Teams / Chime / Meet call audio + snap-and-OCR of any screen region.
- **Real-time transcription.** Whisper models from `tiny` up to `large-v3-turbo` (multilingual). Optional English-only, translation to English, or automatic language detection.
- **Ask your meetings.** A long-lived chat pane that can talk to one meeting, everything in your history, or just have a general conversation.
- **Everything else you'd expect.** Chapters, notes, star / edit / play from here, waveform playback, sentence-split transcripts, custom hot-keys, mini HUD, scheduled recordings, auto-detect calls, passphrase lock, export as TXT / MD / SRT / VTT / JSON.

## Screenshots

_(Coming soon — record a screenshot & drop it in `docs/screenshots/`.)_

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon Mac recommended (whisper.cpp uses Metal)
- ~1 GB free disk space for models
- [Kiro CLI](https://kiro.dev/download) installed and on your `PATH` — required for the chat / auto-summary / auto-title features. Recording and transcription work without it.

## Install

### Homebrew (recommended)

```sh
brew tap charsree/tools
brew install record
```

That's it. Record is now at `/Applications/Record.app` — launch it from Spotlight, Launchpad, or type `record` in Terminal.

### Direct download

Grab the latest `Record-<version>.zip` from [Releases](https://github.com/charsree/record/releases), unzip, and drag `Record.app` to `/Applications`.

### Build from source

```sh
git clone https://github.com/charsree/record.git
cd record
brew install whisper-cpp sqlite
zsh scripts/build-app.sh
open Build/Record.app
```

## First-run setup

1. Launch Record. macOS will ask for **Microphone** and **Screen Recording** permission — grant both. System audio capture requires Screen Recording.
2. Open **Preferences → Transcription** and download a whisper model. `large-v3-turbo` (~1.5 GB) is the best all-around choice; `base.en` (~150 MB) is fast and English-only.
3. If you want chat features, verify `kiro-cli` runs from your terminal (`kiro --version`). Record will pick it up automatically.
4. Hit ● **Record** or ⌘⌥R.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘⌥R | Start / pause / resume recording (global) |
| ⌘⇧P | Pause / resume recording (in-app) |
| ⌘⌥. | Mute / unmute microphone |
| ⌘⌥M | Open the mini HUD window |
| ⌘M | Insert a chapter at the current time |
| ⌘N | Insert a note at the current time |
| ⌘⇧O | Import an audio file for transcription |
| ⌘⇧V | Paste clipboard content as a chat attachment |
| Esc  | Cancel a Kiro request in flight |

## Where your data lives

Everything is under `~/Library/Application Support/Record/`:

```
Record/
├── meeting-key.bin        # AES-GCM key (0600, generated once)
├── meetings.db            # SQLite index + encrypted transcripts
├── chats.enc              # Chat archive (AES-GCM)
├── audio/
│   ├── <meeting>.mic.m4a  # Your voice
│   └── <meeting>.sys.m4a  # System audio (Zoom/etc.)
├── kiro-home/             # Sandboxed HOME for the Kiro subprocess
├── kiro-workspace/        # Scratch space Kiro uses per request
├── kiro-stderr.log        # Rolling stderr log for troubleshooting
└── Models/                # Downloaded whisper models
```

You can delete any of these at any time. Record will regenerate what it needs.

## Privacy

- No network calls except when you explicitly download a whisper model (Hugging Face) or use Kiro chat (Kiro CLI subprocess).
- The Kiro subprocess runs with `HOME` redirected to a sandboxed directory with an empty `mcp.json`, so it can't reach your real config or MCP servers.
- Passphrase lock (Preferences → Security) protects the UI when you step away. It does not re-encrypt your files — the AES key on disk does that.

## Troubleshooting

**"Screen Recording permission is off"** — grant it in System Settings → Privacy & Security → Screen Recording, then relaunch Record.

**"Local whisper: model missing"** — open Preferences → Transcription and click Download.

**Kiro chat says timeout / process exited** — check `~/Library/Application Support/Record/kiro-stderr.log`. Common cause: `kiro-cli` isn't on the `PATH` Record inherits from launchd. Run `kiro --version` in Terminal to confirm your install works.

**Live transcription freezes for a couple seconds during rapid back-and-forth** — that's intentional. Record locks the on-screen text when whisper's partial transcription drifts, so earlier words don't get wiped out. The final segment is filled in once the utterance ends.

## Development

```sh
swift build              # dev build
swift test               # run the test suite
zsh scripts/build-app.sh # package Record.app
```

The build script prefers a stable code-signing identity from your keychain (`Record Local Signer` or a Developer ID Application) and falls back to ad-hoc signing.

## Contributing

Pull requests welcome. Please:
- Run `swift test` before submitting.
- Keep the "local-first, no network" guarantee — anything that phones home needs an explicit opt-in preference.
- Match the existing coding style (Swift 6.2, `@MainActor` on `MeetingSession`).

## License

[MIT](./LICENSE)
