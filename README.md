# LikhoLive

**Live dictation for macOS powered by Sarvam saaras:v3.**

LikhoLive is a lightweight menu bar app that transcribes your speech in real time and types it directly into whatever app is focused — exactly like macOS Dictation, but using Sarvam's multilingual model that handles mixed English + Hindi (and 20+ Indian languages) with high accuracy.

---

## Features

- **Real-time streaming** via Sarvam WebSocket API (`saaras:v3`)
- **Types into any app** using macOS Accessibility (with paste fallback for full Unicode/Devanagari support)
- **5 output modes**: `transcribe`, `translate`, `verbatim`, `translit`, `codemix`
- **24 languages** including English, Hindi, Bengali, Tamil, Telugu, and more
- **Auto-stop after 5 seconds of silence**
- **Global hotkey**: `Control + Option + Space` to start/stop
- **Menu bar + floating settings panel**
- **Local session history** (last 20 sessions)
- **Clipboard restore** after paste fallback (configurable)
- **Launch at Login** (configurable)
- **Secure field protection**: will not dictate into password fields

---

## Requirements

- macOS 13 Ventura or later (Apple Silicon or Intel)
- A [Sarvam AI](https://sarvam.ai) API key

---

## Install

### Option A: Download DMG (recommended for most users)

1. Go to [Releases](../../releases/latest)
2. Download `LikhoLive-x.x.x.dmg`
3. Open the DMG and drag `LikhoLive.app` to your Applications folder

> **First launch:** macOS will warn that the app is from an unidentified developer (the app is unsigned).
> Right-click `LikhoLive.app` → **Open** → **Open** to bypass Gatekeeper.
> You only need to do this once.

### Option B: Build from source

```bash
git clone https://github.com/shaugupt/LikhoLive
cd LikhoLive
# Install XcodeGen if needed:
brew install xcodegen
# Generate the Xcode project:
cd LikhoLive && xcodegen generate
# Open in Xcode:
open LikhoLive.xcodeproj
# Build and run (⌘R)
```

---

## First-run setup

### 1. Grant Microphone access
When LikhoLive first launches it will request microphone access. If you missed it:
- Open **System Settings → Privacy & Security → Microphone**
- Enable **LikhoLive**

### 2. Grant Accessibility access
LikhoLive needs Accessibility to type into other apps:
- Open **System Settings → Privacy & Security → Accessibility**
- Enable **LikhoLive**
- If LikhoLive's panel shows "Not granted", click **Open Settings** next to Accessibility

> Both permissions are required. The **Start Dictation** button will remain disabled until both are granted.

### 3. Add your Sarvam API key

If you already have a Sarvam project on this Mac, LikhoLive will automatically import your API key on first launch.

To add or update a key manually:
- Click the menu bar icon → **Settings & Status…**
- Scroll to **Sarvam API Key**
- Paste your key and click **Save**

Get a key at [sarvam.ai](https://sarvam.ai).

---

## Usage

### Start / stop dictation

- Click the menu bar **mic icon** → **Start Dictation**
- Or press `Control + Option + Space`
- Speak normally — text will appear in whatever app is focused
- Press the hotkey again, or click **Stop**, or simply stop speaking (auto-stop after 5 seconds)

### Change output mode

Open **Settings & Status…** and choose a mode:

| Mode | Output |
|------|--------|
| `transcribe` | Standard transcription in the spoken language (default) |
| `translate` | Translate any language to English |
| `verbatim` | Exact spoken form, no normalization |
| `translit` | Roman/Latin script output |
| `codemix` | English words in English, Indic words in native script |

### Change language

Default is `Auto-detect (unknown)`. Select a specific language for slightly faster detection.

---

## Known limitations

- **Unsigned app**: macOS Gatekeeper will warn on first launch. Use Right-click → Open.
- **Text field locking**: LikhoLive locks the frontmost *app* at session start, not the specific text field. Switching apps during dictation will auto-stop the session.
- **Secure fields**: Dictation is blocked in password/secure input fields.
- **Network required**: Audio is streamed to Sarvam's servers. Latency depends on your connection.
- **Devanagari typing**: Direct CGEvent injection may not work in all apps for Devanagari text. LikhoLive will automatically fall back to paste.

---

## Project structure

```
LikhoLive/
├── LikhoLive/
│   ├── AppDelegate.swift              # App entry point
│   ├── Models/
│   │   ├── AppState.swift             # SessionState, SarvamMode, SarvamLanguage, TranscriptSession
│   │   └── AppSettings.swift          # User settings (UserDefaults)
│   ├── Services/
│   │   ├── AudioCaptureService.swift  # AVAudioEngine mic capture
│   │   ├── SarvamStreamingClient.swift # WebSocket streaming client
│   │   ├── SilenceDetector.swift      # Local RMS silence detection
│   │   ├── SessionCoordinator.swift   # Session lifecycle and coordination
│   │   ├── HistoryStore.swift         # Local session history
│   │   └── KeychainStore.swift        # Sarvam API key in Keychain
│   ├── Managers/
│   │   ├── PermissionManager.swift    # Mic + Accessibility permissions
│   │   ├── FrontmostAppMonitor.swift  # Detects app focus changes
│   │   ├── SecureFieldGuard.swift     # Detects secure text fields
│   │   ├── TextInjector.swift         # CGEvent typing + paste fallback
│   │   ├── HotkeyManager.swift        # Global hotkey (Carbon)
│   │   └── LaunchAtLoginHelper.swift  # SMAppService launch-at-login
│   ├── UI/
│   │   ├── StatusBarController.swift  # Menu bar status item
│   │   ├── PanelWindowController.swift # Floating panel window
│   │   └── SettingsViewController.swift # Main panel UI
│   └── Resources/
│       ├── Info.plist
│       └── LikhoLive.entitlements
├── project.yml                        # XcodeGen project spec
└── scripts/
    └── release.sh                     # Local release build script
```

---

## Release a new version

```bash
# Build a local release
./scripts/release.sh 1.0.1

# Or push a tag to trigger GitHub Actions
git tag v1.0.1
git push origin v1.0.1
```

---

## License

MIT
