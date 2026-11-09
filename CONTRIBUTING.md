# Contributing to Sticky-AI

Thank you for your interest in contributing to **Sticky-AI** — the open-source native macOS floating assistant for Google Gemini!

## Local Development

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/madmicrowave/sticky-ai.git
   cd sticky-ai
   ```
2. Run the automated Swift test suite:
   ```bash
   zsh scripts/run-tests.sh
   ```
3. Build and launch `Sticky-AI.app`:
   ```bash
   zsh scripts/build-app.sh
   open ./Sticky-AI.app
   ```

## Pull Request Guidelines

- Keep Sticky-AI **zero-dependency** (pure Swift `AppKit`, `WebKit`, and Carbon `HIToolbox`).
- Ensure `zsh scripts/run-tests.sh` and `zsh scripts/build-app.sh` pass cleanly before opening a PR.
- Add unit tests in `Tests/TestMain.swift` when modifying hotkey state transitions, frame clamping, or download handling.

