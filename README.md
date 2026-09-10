<h1 align="center">Record</h1>

<p align="center">
  <b>A local-first macOS meeting assistant.</b><br/>
  Mic + system audio + screen OCR, transcribed locally with whisper.cpp, chat over your meetings with Kiro.
</p>

<p align="center">
  <a href="https://github.com/charsree/record/releases"><img src="https://img.shields.io/github/v/release/charsree/record?label=version" alt="version"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/charsree/record" alt="license"></a>
  <a href="https://github.com/charsree/record/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/charsree/record/ci.yml?label=build" alt="build"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000?logo=apple&logoColor=white" alt="macOS 26+">
</p>

---

## Why Record

Every meeting-assistant tool ships your audio and transcripts to somebody else's servers. Record doesn't. Everything — audio capture, transcription, semantic chat, storage — happens on your Mac. The only outbound network calls are the whisper model downloads you initiate yourself, and the Kiro CLI subprocess when you use the chat features.

## Install

```sh
brew tap charsree/tools
brew install record
open -a Record
```

That's it. Record ends up at `/Applications/Record.app`. You can also type `record` in Terminal to launch it.

<sub>Works on Intel and Apple Silicon Macs running macOS 26 or later. Homebrew builds it from source (~30 seconds) and depends on `whisper-cpp`.</sub>

## Features

### Capture

- 🎙️ **Microphone + system audio** — record your voice and everyone else's on the call at the same time, in separate tracks that stay time-aligned during playback.
- 📞 **Auto-detect calls** — a Zoom / Teams / Chime / Meet / Slack / Webex / Discord front-of-app triggers a "Start recording?" notification (opt-in in Preferences).
- 🖼️ **Snap & OCR** — press a shortcut, drag a region, and the extracted text lands in the transcript *and* becomes a chat attachment. Handy for reading slides that the other side is sharing.
- ⏸️ **Pause / resume** without losing the transcript. Auto-pauses on silence and resumes when audio returns.
- 🗓️ **Scheduled recordings** — recurring times, weekdays, and duration. Great for daily stand-ups.
- 📥 **Import audio** — drop any `.m4a` / `.wav` / `.mp3` / `.aac` / `.aiff` file, get a full transcribed meeting back.

### Transcribe

- 🧠 **Local whisper.cpp** — models from `tiny` (75 MB) to `large-v3-turbo` (1.5 GB, best quality). Auto-download from Hugging Face inside the app.
- 🌍 **97 languages** with the multilingual models, or English-only with the `.en` variants. Optional **translate-to-English** toggle.
- ✂️ **Sentence-aware segmentation** — pauses split utterances; long back-and-forth speech gets split by sentence on write, so one row per idea.
- ✏️ **Edit transcripts** inline, mark segments as chapters (⌘M) or notes (⌘N), star the important ones.

### Chat

- 💬 **Ask your meetings.** Long-lived Kiro chat pane. Ask about the current meeting, any past meeting, everything you've recorded, or just have a general conversation.
- 🔗 **Multi-context** — meeting index (title / date / summary / tags) plus keyword-matched transcript snippets, so cross-meeting queries actually work.
- 📎 **Attachments** — paste text, drop files, or use the snap-and-OCR grabs. Everything gets bundled into the prompt.
- ✨ **Prompt library** with editable saved prompts and quick actions (Summarize, Action items, Draft email, Explain jargon).
- 🏷️ **Auto-title and auto-summary** after every recording, via a Kiro prompt template you can customize.

### Playback

- 🌊 **Waveform + audio player** for every meeting. Click the waveform to seek; double-click a transcript row to play from there.
- 🎚️ **Per-track mute** during playback — silence your own voice or silence the call, whichever you want to hear.

### Everything else

- 🔒 **AES-GCM encrypted** transcripts and chat archive. Key lives in a 0600 file, not the keychain.
- 🔐 **Passphrase lock** with configurable auto-lock timer.
- 🔎 **Cross-meeting search**, tag chips, date-range filters, related-meeting suggestions.
- 📄 **Export** as `.txt` / `.md` / `.srt` / `.vtt` / `.json`.
- 🪟 **Mini HUD** — always-on-top floating window with level meters and the last transcript line. ⌘⌥M.
- ⌨️ **Global hotkey** ⌘⌥R starts / pauses / resumes recording from anywhere.
- 🐚 **Post-meeting hook** — configure a shell script to run when a meeting ends; it gets the transcript path as `$1`.

## Requirements

- **macOS 26 (Tahoe)** or later
- Apple Silicon recommended (whisper.cpp uses Metal for acceleration)
- **~1 GB free disk** for a mid-sized whisper model
- Optional: **[Kiro CLI](https://kiro.dev)** on your `PATH` for the chat / auto-summary / auto-title features. Recording + transcription work without it.

## First-run checklist

1. `brew install record` and launch it.
2. macOS asks for **Microphone** and **Screen Recording** permission on the first recording. Grant both. System audio needs Screen Recording.
3. Preferences → Transcription → **Download** a whisper model. If you're on English calls, `base.en` is fast; if you speak Indian English or your calls are multilingual, `large-v3-turbo` is the best all-around choice.
4. Hit ● **Record** (or ⌘⌥R).

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
├── meeting-key.bin        # AES-GCM key (mode 0600, generated once)
├── meetings.db            # SQLite index + encrypted transcript segments
├── chats.enc              # Chat archive (AES-GCM)
├── audio/
│   ├── <meeting>.mic.m4a  # Your voice (AAC 128 kbps mono, 48 kHz)
│   └── <meeting>.sys.m4a  # System audio — call participants
├── kiro-home/             # Sandboxed HOME for the Kiro subprocess
├── kiro-workspace/        # Scratch space Kiro uses per request
├── kiro-stderr.log        # Rolling stderr log for troubleshooting
└── Models/                # Downloaded whisper models
```

Delete anything at any time — Record regenerates what it needs.

## Privacy

- **No network calls** except when you explicitly download a whisper model (Hugging Face) or use Kiro chat (subprocess).
- **Kiro sandbox** — the Kiro subprocess runs with `HOME` redirected to `~/Library/Application Support/Record/kiro-home` and an empty `mcp.json`, so it can't touch your real config or reach any MCP servers you have installed.
- **Passphrase lock** protects the UI when you step away. It does *not* re-encrypt files — the AES key on disk already does that.

## Troubleshooting

<details>
<summary><b>"Screen Recording permission is off — recording microphone only"</b></summary>

macOS revokes TCC permission whenever a rebuild changes the app's code signature. For the tap-installed build this only happens the first time. Grant it in **System Settings → Privacy & Security → Screen Recording**, then quit and reopen Record.
</details>

<details>
<summary><b>"Local whisper: model missing"</b></summary>

Open **Preferences → Transcription**, pick a model, click **Download**. `base.en` (~150 MB) is a good starting point.
</details>

<details>
<summary><b>Kiro chat says timeout or process exited</b></summary>

Check `~/Library/Application Support/Record/kiro-stderr.log` for the actual error. The most common cause is that `kiro-cli` isn't on the `PATH` that Record inherits from launchd. Confirm by running `kiro --version` in Terminal — if that works but Record doesn't find it, restart the app (it will pick up your login PATH).
</details>

<details>
<summary><b>Live transcript freezes for a couple seconds mid-utterance</b></summary>

That's intentional. When whisper's re-transcription of the same audio window drifts, Record locks the on-screen text so previously-shown words don't disappear. The final segment is filled in accurately as soon as the utterance ends.
</details>

## Build from source

```sh
git clone https://github.com/charsree/record.git
cd record
brew install whisper-cpp sqlite
swift test                   # optional
zsh scripts/build-app.sh
open Build/Record.app
```

Development commands:

```sh
swift build                  # dev build
swift test                   # unit tests
zsh scripts/build-app.sh     # package Record.app into Build/
zsh scripts/tag-release.sh 0.4.0  # bump version + tag + push (CI ships the tap update)
```

## Releasing

Maintainer flow:

```sh
zsh scripts/tag-release.sh 0.4.0
```

That bumps `Info.plist`, commits, tags `v0.4.0`, pushes. GitHub Actions then computes the source tarball's SHA256 and pushes an updated `Formula/record.rb` to [`charsree/homebrew-tools`](https://github.com/charsree/homebrew-tools). Users pick it up with `brew upgrade record`.

## Contributing

PRs welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) for setup and ground rules. The most important one: **stay local-first.** Any feature that phones home needs an explicit opt-in preference and a README note.

## License

[MIT](./LICENSE)
