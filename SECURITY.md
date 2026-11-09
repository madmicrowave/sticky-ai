# Security Policy

## Architecture & Privacy

- **Sticky-AI** embeds Apple's native `WKWebView` pointing directly to `https://gemini.google.com/app` with standard Google OAuth domains.
- No third-party analytics, telemetry, proxy servers, or external SDKs are included.
- Google credentials and session cookies stay exclusively inside your local macOS `WKWebsiteDataStore`.

## Reporting a Vulnerability

If you discover a security issue, please report it responsibly via [GitHub Security Advisories](https://github.com/madmicrowave/sticky-ai/security/advisories/new) rather than opening a public issue.
