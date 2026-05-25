# Clawk iOS — Agent Instructions

## What this project is

Clawk is a native iOS client for the OpenClaw AI gateway. It connects to an OpenClaw instance via WebSocket and provides:
- **Gateway Chat** — direct WebSocket chat with the AI agent (port 18789)
- **Relay Messages** — message relay via a backend API (port 3002)
- **Dashboard** — system status and monitoring

The app is built with SwiftUI and targets iOS 17+. It uses SwiftData for persistence.

## Project structure

```
Clawk/Clawk/
├── ClawkApp.swift          # App entry point, TabView with 3 tabs
├── Config.swift            # Server URLs, device token, color extensions
├── GatewayConnection.swift # WebSocket client for OpenClaw gateway protocol
├── GatewayChatView.swift   # Chat UI for gateway connection
├── SessionChatView.swift   # Chat UI for individual sessions
├── ContentView.swift       # Relay messages tab (via backend)
├── DashboardView.swift     # System dashboard tab
├── MessageStore.swift      # Backend message store (relay mode)
├── ChatHistoryStore.swift  # SwiftData persistence for chat history
├── ThinkingStepsView.swift # UI for agent thinking/tool call display
├── IdentitySyncManager.swift # Agent identity sync
```

## Key conventions

- **SwiftUI only** — no UIKit unless absolutely necessary
- **No third-party dependencies** — everything uses Apple frameworks (Foundation, SwiftUI, SwiftData, URLSession)
- **WebSocket protocol** — the gateway connection follows OpenClaw's event protocol (hello, message, thinking, toolCall, toolResult, identity, ping)
- **Config.swift** — all server URLs and tokens are centralized here. The gateway defaults to `localhost:18789`, the relay backend to `localhost:3002`
- **Device tokens** — generated once and stored in UserDefaults for consistent device identity

## When making changes

1. **Always build and test before pushing.** Use XcodeBuildMCP tools to build, run tests, and check for warnings.
2. **Keep the app functional offline.** If the gateway is unreachable, the app should show a clear "Offline" state, not crash.
3. **SwiftData models** — `PersistedMessage`, `PersistedSession`, `AgentIdentityRecord` are the core entities. Changes to these require migration consideration.
4. **The WebSocket reconnect logic is important.** `GatewayConnection` auto-reconnects after 3 seconds. Don't remove this.
5. **Info.plist must include** `ITSAppUsesNonExemptEncryption = NO` for automated TestFlight deployment.

## Build and deploy

This project uses Xcode Cloud for CI/CD:
- Push to `main` → triggers Xcode Cloud build → TestFlight distribution
- Push to `agent/*` branches → triggers build for testing before merge

See `docs/PIPELINE.md` for the full phone-to-TestFlight workflow.
See `docs/NEW-APP-PLAYBOOK.md` to create a brand new iOS app autonomously (no human steps).
See `docs/TROUBLESHOOTING.md` when things break.

## Gateway connection details

The OpenClaw gateway runs on the Mac mini at the Tailscale IP. The app currently hardcodes `localhost:18789` in `Config.swift`. For production use, this should point to the Mac mini's Tailscale hostname or IP.

### Gateway protocol events (inbound):
- `hello` — connection established, start heartbeat
- `message` — chat message (supports streaming via `streaming: true`)
- `thinking` — agent thinking step
- `toolCall` — agent is using a tool
- `toolResult` — tool execution result
- `identity` — agent identity update (name, emoji, color)
- `error` — error message

### Gateway protocol events (outbound):
- `message` — send user message
- `sync_identity` — request identity info
- `ping` — heartbeat (every 30s)

## Testing approach

- Build with `xcodebuild` via XcodeBuildMCP
- Test on iOS Simulator (iPhone 16 Pro recommended)
- Verify WebSocket connection states: connecting → connected → disconnected → reconnecting
- Verify message persistence across app restarts
- Check that thinking steps and tool calls display correctly during agent responses
