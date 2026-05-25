# Architecture — Phone to TestFlight Pipeline

## System overview

```
┌─────────────┐     ┌──────────────────────────────────┐     ┌─────────────────┐
│   iPhone     │     │          Mac mini (always on)      │     │    Cloud         │
│              │     │                                    │     │                 │
│  iMessage/   │────▶│  OpenClaw Gateway (:18789)         │     │  GitHub         │
│  WhatsApp/   │     │    │                               │     │    │            │
│  Clawk app   │     │    ▼                               │     │    ▼            │
│              │     │  Claude Code (agent session)       │     │  Xcode Cloud   │
│              │     │    │                               │     │    │            │
│  TestFlight  │◀────│    ├── XcodeBuildMCP (build/test)  │     │    ▼            │
│  (result)    │     │    └── git push ──────────────────────▶  │  TestFlight    │
└─────────────┘     └──────────────────────────────────┘     └─────────────────┘
```

## Components

### 1. Phone (input + output)

**Input options:**
- **OpenClaw messaging** — text your Mac mini via iMessage, WhatsApp, Telegram, Slack, or Discord. OpenClaw routes the message to a Claude Code session.
- **Clawk iOS app** — native app that connects directly to OpenClaw gateway via WebSocket for a richer experience (thinking steps, tool calls visible).
- **Omnara** — third-party app for Claude Code mobile control with voice mode, diff review, and localhost preview.
- **GitHub mobile** — for reviewing PRs and triggering merges.

**Output:**
- TestFlight delivers the built app directly to your phone.
- OpenClaw messages back build status, errors, or completion.

### 2. Mac mini (the engine)

Everything runs here. The Mac mini needs:
- **macOS 15+** with Xcode 26 beta installed
- **Node.js 18+** for Claude Code and OpenClaw
- **Tailscale** for remote access from anywhere
- **OpenClaw** as the messaging gateway
- **Claude Code** as the coding agent
- **XcodeBuildMCP** for headless Xcode builds and testing

The Mac mini does NOT need Xcode open. XcodeBuildMCP uses `xcodebuild` CLI directly for headless builds. This is important — it means the Mac mini can sit in a closet with the display off.

### 3. GitHub (version control + CI trigger)

The GitHub repo serves two purposes:
- **Version control** — all code changes are committed and pushed
- **CI trigger** — pushes to `main` or merges of PRs trigger Xcode Cloud

Branch strategy:
- `main` — production, triggers TestFlight builds
- `agent/*` — agent working branches, can trigger test builds
- PRs from `agent/*` → `main` — review on GitHub mobile, merge to deploy

### 4. Xcode Cloud (build + distribute)

Apple's CI/CD service, included with your developer account (25 hrs/month free):
- Builds the app from source on Apple's servers
- Handles code signing automatically (no manual certificates)
- Distributes to TestFlight on success
- Sends push notification when build is ready

## Data flow for a typical request

1. You text "Add a settings screen with dark mode toggle" from your phone
2. OpenClaw receives the message on the Mac mini
3. OpenClaw spawns a Claude Code ACP session in the clawk-ios directory
4. Claude Code reads the codebase, understands the project (via CLAUDE.md)
5. Claude Code writes the SwiftUI views and modifies ClawkApp.swift
6. Claude Code uses XcodeBuildMCP to build and test locally
7. If build succeeds: Claude Code commits and pushes to `agent/settings-screen`
8. Claude Code opens a PR via `gh pr create`
9. Claude Code messages you back: "PR ready for review: [link]"
10. You review on GitHub mobile and tap "Merge"
11. Merge to `main` triggers Xcode Cloud
12. Xcode Cloud builds, signs, and uploads to TestFlight
13. You get a TestFlight notification ~15-30 min later
14. Install and test on your phone

## Security considerations

- **API keys** — Anthropic API key is set as an environment variable on the Mac mini, never committed to git
- **Tailscale** — encrypted mesh VPN, no ports exposed to the public internet
- **OpenClaw device tokens** — unique per device, stored in UserDefaults
- **Code signing** — handled entirely by Xcode Cloud using your Apple Developer account, no certificates stored in the repo
- **App Store Connect API key** — only exists in Xcode Cloud settings, not in the repo

## Cost breakdown

| Component | Cost |
|-----------|------|
| Apple Developer Program | $99/year |
| Xcode Cloud (included) | 25 hrs/month free |
| Tailscale (personal) | Free |
| OpenClaw | Free (open source) |
| Claude Code (API usage) | ~$5-20/month depending on usage |
| Mac mini | Already owned |
| **Total** | **~$110-130/year** |
