# Sticky-AI (`sticky-ai`)

[![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-000000?logo=apple&logoColor=white)](https://github.com/madmicrowave/sticky-ai)
[![AI: Google Gemini](https://img.shields.io/badge/AI-Google%20Gemini-4285F4?logo=google&logoColor=white)](https://gemini.google.com)
[![Built with Swift](https://img.shields.io/badge/Built%20with-Swift%205.10-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](./LICENSE)
[![Powered by DOMONK Factory](https://img.shields.io/badge/Powered%20by-DOMONK%20Factory-7c3aed)](https://domonk.com)

> **Open-Source Native macOS Software for Google Gemini** — Free and open source for everyone under the MIT License.
>
> **Powered by [DOMONK Factory](https://domonk.com)** • Repository: **[github.com/madmicrowave/sticky-ai](https://github.com/madmicrowave/sticky-ai)**

**Sticky-AI** is a lightweight, zero-dependency, native **macOS** desktop utility built specifically for **Google Gemini** (`https://gemini.google.com/app`). Press **`Option + Space` (`⌥ + Space`)** from **anywhere on macOS** — across any app, Desktop Space, or full-screen window — to summon an always-on-top floating Google Gemini assistant with instant prompt focus, smart translucency when unfocused, persistent Google sign-in, and automatic file/image downloads to `~/Downloads`.

Built natively in Swift using Apple's `AppKit`, `WebKit` (`WKWebView`), and Carbon `HIToolbox` (`RegisterEventHotKey`), **Google Account Sign-In (`accounts.google.com`) works natively inside the app** without triggering Google's `"This browser or app may not be secure"` block common to Electron/CEF wrappers.

---

## Key Features

1. **Dedicated Native macOS Window for Google Gemini (`https://gemini.google.com/app`)**
   - Runs quietly as a menu bar utility (`LSUIElement`, zero Dock clutter) with persistent `WKWebsiteDataStore` storage so your Google account stays signed in across hides and restarts.
   - **Zero-Black-Screen Instant Open**: Soft-hides using a click-through, shadowless `1pt` edge keep-alive + App Nap prevention + cached snapshot shield + background sleep-wake recovery so macOS `WebKit` never purges GPU `IOSurface` tiles or drops your live Gemini DOM even after hours idle.
2. **Global `Option + Space` (`⌥ + Space`) Hotkey Anywhere on macOS**
   - Registered directly with the macOS WindowServer via Carbon `HIToolbox` (`RegisterEventHotKey`), working across every app, Space, and full-screen window **without requiring Accessibility permissions**.
3. **3-State Focus, Translucency & Hide Cycle**
   - **Hidden + `Option + Space`** → Appears **on top of all windows**, activates Sticky-AI at **`100%` opacity**, and **auto-focuses the Google Gemini prompt input** ready to type.
   - **Visible & Unfocused** → Remains pinned **on top of all windows** at configurable translucency (**`60%` opacity / `40%` transparent** by default) so you can reference Google Gemini responses while coding or reading behind the window.
   - **Visible & Unfocused + `Option + Space`** (or mouse click) → Restores **`100%` opacity** and focuses the Google Gemini message input.
   - **Visible & Focused + `Option + Space`** → **Hides Sticky-AI** immediately and restores keyboard focus to the exact external app you were using before.
4. **Compact, Movable & Multi-Display Aware**
   - Opens at a compact `420 × 560` floating panel near the top-right of your active screen (`min 280 × 320`).
   - Remembers your custom window position, size, and unfocused transparency in `~/Library/Application Support/Sticky-AI/sticky-ai-config.json`, automatically clamping back onto a visible display if monitors change.
5. **Seamless One-Click Downloads to `~/Downloads`**
   - Clicking **Download** on generated Google Gemini images, code archives, PDFs, or exports saves directly to `~/Downloads` (inferring MIME file extensions automatically and numbering duplicates as `file (1).png`, `file (2).png` without overwriting).

---

## System Requirements

- **macOS 13.0 (Ventura) or newer** (Apple Silicon & Intel supported)
- **Xcode Command Line Tools** (`xcode-select --install`, providing `swiftc` 5.10+)
- *(Optional)* **Node.js / npm** if you prefer running `npm start` / `npm run build:app` convenience scripts (you can also run the shell scripts directly with `zsh`)

---

## Installation & Quick Start

### 1. Clone & Build `Sticky-AI.app`

```bash
git clone https://github.com/madmicrowave/sticky-ai.git
cd sticky-ai
zsh scripts/build-app.sh
```

*(Or with npm: `npm run build:app`)*

This compiles the optimized native Swift binary (`StickyAI`), bundles resources and `Info.plist`, ad-hoc codesigns `Sticky-AI.app`, and places it in the project root.

### 2. Launch Sticky-AI

```bash
open ./Sticky-AI.app
```

*(Or simply run `npm start`, which builds `Sticky-AI.app` automatically if needed and opens it.)*

You can also drag **`Sticky-AI.app`** into `/Applications` for permanent installation:

```bash
cp -R ./Sticky-AI.app /Applications/
open /Applications/Sticky-AI.app
```

---

## First-Time Google Gemini Sign-In

1. Launch `Sticky-AI.app` (or press **`Option + Space`**).
2. Click **Sign in** inside the Google Gemini window and complete your normal Google authentication (including Passkeys / 2-Step Verification).
3. Cookies and session state are stored persistently in macOS `WKWebsiteDataStore` — Google Gemini stays signed in across window toggles and macOS reboots.

---

## Start Automatically at macOS Login (Optional)

1. Open **System Settings → General → Login Items & Extensions**.
2. Under **Open at Login**, click **`+`**.
3. Select `Sticky-AI.app` (e.g., in `/Applications/Sticky-AI.app`) and click **Open**.

---

## Keyboard Shortcuts & Menu Bar Controls

Click the **Sticky-AI** icon in the top-right macOS menu bar at any time to access:

| Action | Shortcut / Menu Item |
| :--- | :--- |
| **Show / Focus / Hide Sticky-AI** | `Option + Space` (`⌥Space`) — global across macOS |
| **Focus Google Gemini Input** | Menu Bar → *Focus Message Input* |
| **Open Gemini Home** | Menu Bar → *Open Gemini Home* (`https://gemini.google.com/app`) |
| **Reload Page** | `Cmd + R` |
| **Reset Window Size & Position** | Menu Bar → *Reset Window Size & Position* |
| **Unfocused Opacity Presets** | `80%`, `60% (Default)`, `40%`, `20%` |
| **Quit Sticky-AI** | `Cmd + Q` |

### Optional Environment Overrides

- `STICKY_AI_UNFOCUSED_OPACITY`: Float between `0.05` and `1.0` (e.g. `0.5`) overriding unfocused window alpha.
- `STICKY_AI_DOWNLOADS_DIR`: Custom directory path for downloaded Gemini assets (defaults to `~/Downloads`).

---

## Architecture & Project Structure

```text
sticky-ai/
├── Package.swift                              # Swift Package Manager manifest (macOS 13+)
├── Sources/
│   ├── StickyAICore/
│   │   ├── StickyAppController.swift          # Floating NSPanel, WKWebView session, OAuth popups & menu bar UI
│   │   ├── StateMachine.swift                 # 3-state Option+Space transition logic, opacity & ConfigStore
│   │   ├── HotKeyManager.swift                # Carbon HIToolbox global Option+Space hotkey registration
│   │   ├── FocusInput.swift                   # Resilient DOM prompt-input auto-focus & caret placement
│   │   └── DownloadHelper.swift               # MIME extension inference, filename sanitization & unique ~/Downloads paths
│   └── StickyAIApp/
│       └── main.swift                         # Native macOS NSApplication entrypoint
├── Resources/
│   ├── AppIcon.icns                           # macOS application bundle icon
│   └── MenuBarIcon.png                        # macOS status bar icon
├── Tests/
│   └── TestMain.swift                         # Automated test suite for state machine, config, focus & downloads
├── scripts/
│   ├── build-app.sh                           # Standalone `Sticky-AI.app` builder & ad-hoc codesigner
│   ├── run-tests.sh                           # Compiles & runs automated Swift test suite
│   └── generate-icon.swift                    # Icon asset generator script
├── package.json                               # Optional npm convenience scripts (`start`, `build:app`, `test`)
└── LICENSE                                    # MIT License
```

---

## Running Automated Tests

```bash
zsh scripts/run-tests.sh
```

*(Or `npm test`)* — Compiles `StickyAICore` with `Tests/TestMain.swift` and verifies the 3-state hotkey state machine, unfocused opacity clamping, multi-screen frame persistence, Google OAuth domain routing, filename sanitization, and collision-free `~/Downloads` resolution.

---

## Companion macOS Google Gemini Software

Check out **[Phone Agent Control (`phone-agent-control`)](https://github.com/madmicrowave/phone-agent-control)** — open-source macOS software for **Google Gemini & Antigravity IDE (`agy`)** that lets you control local IDE workspaces, switch Gemini models/levels, commit/branch Git changes, and run Jenkins CI/CD deployments from Telegram on your phone.

---

## Open Source License & Credits

Released as free and open-source software for everyone under the **[MIT License](./LICENSE)**.

**Powered by [DOMONK Factory](https://domonk.com)** — [https://domonk.com](https://domonk.com)
