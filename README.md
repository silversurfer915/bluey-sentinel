# Bluey Sentinel

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-52%2F52%20Passing-brightgreen.svg)]()
[![Guard Rails](https://img.shields.io/badge/Guard%20Rails-100%2F100%20Verified-brightgreen.svg)]()

> **Bluey Sentinel** is a dual-brain autonomous AI companion and focus guardian for macOS with an optional encrypted iPhone/iPad companion. It lives in your menu bar and Dock, understands your screen, completes multi-step computer tasks, learns your study habits, and keeps you on-task with semantic continuity.

---

## ✨ Key Features

### 1. 🧠 Dual-Model Brain Routing
- **Fast Tier (`⚡ Fast`)**: Routes casual conversation, quick questions, greetings, jokes, and timer status to lightning-fast, cost-effective models (**Gemini 3.1 Flash Lite** or **Token Harbor DeepSeek Flash**).
- **Flagship Tier (`🧠 Flagship`)**: Routes computer-use tasks (clicking, typing, keyboard shortcuts, window management), screen understanding, OCR, planning, and multi-step workflows to flagship reasoning models (**DeepSeek Chat / DeepSeek V4.1** or **Gemini Pro**).
- **Per-Request Task Classifier**: Automatically analyzes each request and dispatches it to the optimal tier.
- **Per-Message User Override**: Simply say *"use big brain for this"* or *"use fast model"* on any message to force the tier.
- **Model Attribution**: Live badges on each assistant message show exactly which model and tier generated the response.

### 2. ⚡ Token & Context Caching
- **Deterministic Prefix Caching**: System prompts, Bluey's personality, tool schemas, and screen-annotation instructions form a stable prefix that triggers automatic provider context caching (Gemini explicit caching and DeepSeek prefix caching).
- **Huge Cost & Latency Savings**: Reuses cached tokens across multi-turn sessions at up to **75% lower cost** and sub-second TTFT.
- **Cache Debug Inspector**: Dedicated dashboard in Bluey Workspace logging real-time cache hit rate %, prompt tokens, cached tokens, latency ms, and estimated dollar savings.

### 3. 🔒 Persistent Local Memory & Learning
- **100% Private SQLite Store**: Stored in a local database on your Mac at `~/Library/Application Support/Googly/memory.sqlite`. Zero cloud analytics or tracking.
- **Memory Categories**:
  - `Profile Facts`: Facts about your subjects, projects, and workflow (e.g. *"Studies Wave Optics"*).
  - `User Preferences`: Personal defaults (e.g. *"Prefers dark mode and concise replies"*).
  - `Task Outcomes`: Historical record of past tasks and what worked.
  - `Learned Lessons`: **Mistake prevention**. When you correct Bluey (*"Don't click that button"*, *"Never close Terminal"*), it extracts a lesson and prioritizes it so the mistake is never repeated.
- **Dynamic Relevance Injection**: Automatically retrieves and injects matching memories and critical lessons before each request.
- **Settings Memory Viewer**: Browse, search, filter, edit, delete individual memories, or wipe everything with **Forget Everything**.

### 4. 🛡️ Focus Sentinel & Semantic Topic Continuity
- **Zero-Credit On-Target Checking**: Verifies active Xcode files and browser tabs with zero LLM tokens spent while on-target.
- **Semantic Topic Continuity**: Recognizes related study contexts (e.g. studying Wave Optics PDF in Preview and switching to Chrome practice questions is approved instantly without false alarms).
- **Safe Interventions**: Optional automated closing of the observed distracting tab or hiding the distracting app (never force-quits unrelated apps).
- **Latched Execution Gate**: Instant emergency stop via `Control + Option + S` or the Emergency Stop button.

### 5. 📱 Dock Companion & iPhone Companion
- **Native Dock Activity Ring**: Visual elapsed time ring with pause, resume, and finish actions in the macOS Dock menu.
- **Encrypted Phone Link**: CryptoKit-paired, replay-resistant, sequence-numbered transport over local Wi-Fi.
- **Built-in Mac Microphone**: Voice commands directly on Mac via `Option + Space` with automatic mic hot-plugging.
- **Sanctra Study Sync**: Bidirectional sync of study streaks and sessions with Sanctra accounts.

---

## 🚀 Installation & Quickstart

### Prerequisites
- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac
- Xcode 15+ / Command Line Tools (`xcode-select --install`)
- Optional: API keys for Gemini, Token Harbor, or DeepSeek

### 1. Clone the Repository
```bash
git clone https://github.com/silversurfer915/bluey-sentinel.git
cd bluey-sentinel
```

### 2. Build the macOS App
```bash
./scripts/build-mac.sh
open build/Bluey.app
```

### 3. Run Test Suites
```bash
# Run unit test suite (52 tests)
swift test

# Run Sentinel guard rails demo (100 checks)
GOOGLY_DEMO_SENTINEL=1 ./build/Bluey.app/Contents/MacOS/GooglyMac
```

### 4. Set Up API Keys
1. Open **Bluey** from your menu bar or press `Option + Space`.
2. Go to **Settings > AI Brain**.
3. Enter your **Gemini**, **Token Harbor**, or **DeepSeek** API key in the dedicated input field and click **Save**. Keys are safely stored in your macOS Keychain.
4. Click **Test Active AI Connection** to verify.

---

## 🎮 Usage & Controls

### Voice & Keyboard Shortcuts
| Shortcut | Action |
| :--- | :--- |
| `Option + Space` | Start or finish voice command on Mac |
| `Control + Option + S` | Emergency stop all active actions and latches execution gate |
| `Control + Option + L` | Lock current window as focus target |

### Example Voice & Chat Commands
- *"Focus on Wave Optics"* — Starts a focus session with topic continuity.
- *"Lock this window"* — Locks the frontmost application/tab as your focus target.
- *"Click the submit button and read the result"* — Routes to Flagship model for computer action.
- *"use big brain for this: analyze this crash log"* — Forces Flagship reasoning model.
- *"use fast model: what time is it?"* — Forces Fast lightweight model.
- *"Don't click the red button on Xcode"* — Instantly saves a learned lesson to prevent repeating the mistake.
- *"Pause focus for 10 minutes"* — Freezes the focus clock for a break.

---

## 🛠️ Architecture

```
bluey-sentinel/
├── Mac/
│   └── Sources/GooglyMac/
│       ├── AIConfig.swift          # ModelTier, ModelClassifier, Dual-Model Routing
│       ├── AIClient.swift          # OpenAI/Gemini/DeepSeek HTTP client
│       ├── CacheTracker.swift      # Context caching & token spend tracker
│       ├── MemoryStore.swift       # SQLite local persistent memory & learning
│       ├── RealtimeHost.swift      # Agent loop, computer actions, memory injection
│       ├── BlueyWorkspace.swift    # SwiftUI desktop workspace, tabs & settings
│       ├── Sentinel.swift          # Focus tracking & semantic continuity engine
│       ├── DockCompanion.swift     # macOS Dock tile & activity ring
│       ├── PhoneServer.swift       # Encrypted CryptoKit phone bridge
│       └── ComputerControl.swift   # Accessibility actions (clicks, keys, apps)
├── iOS/
│   └── Sources/
│       ├── BlueyAppView.swift      # iPhone/iPad companion interface
│       ├── MacLink.swift           # Encrypted frame transport to Mac
│       └── Assets.xcassets         # App icons & companion graphics
├── Shared/
│   └── GooglyLink.swift            # Shared encrypted packet protocol
└── Tests/
    └── GooglyMacTests/             # 52 unit tests (Memory, Routing, Cache, Sentinel)
```

---

## 📱 Building the iPhone Companion

1. Open `GooglyEyes.xcodeproj` in Xcode:
   ```bash
   open GooglyEyes.xcodeproj
   ```
2. Select your development team under **Signing & Capabilities**.
3. Connect your iPhone or iPad and select it as the run destination.
4. Press `Cmd + R` to build and run.
5. The companion automatically pairs with your Mac over local Bonjour Wi-Fi.

---

## 🔒 Privacy & Security

- **Memory Stays on Your Mac**: The SQLite database (`memory.sqlite`) is 100% local. It is never transmitted to analytics or telemetry servers.
- **Keychain Security**: All API keys and session tokens are encrypted using macOS Keychain (`com.bluey.credentials`).
- **Confirmation Prompts**: Consequential computer actions (closing tabs, submitting forms, deleting files) respect your configured autonomy mode (`Confirm Consequences` by default).
- **Prompt Isolation**: Passwords, credentials, and sensitive system dialogs are explicitly shielded from screen capture and OCR.

---

## 🤝 Contributing & Extending

Contributions are welcome!
1. Fork the repository.
2. Create your feature branch (`git checkout -b feature/amazing-feature`).
3. Ensure all tests pass (`swift test` and `GOOGLY_DEMO_SENTINEL=1`).
4. Commit your changes (`git commit -m 'feat: add amazing feature'`).
5. Push to the branch (`git push origin feature/amazing-feature`).
6. Open a Pull Request.

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
