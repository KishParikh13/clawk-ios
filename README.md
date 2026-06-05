# Clawk / KishOS

KishOS is the native iOS and macOS app for working with the `kish-agent` that runs on Kish's Mac mini. The current app is a shared SwiftUI shell with persistent conversations, project selection, attachments, voice/live-call controls, tool visibility, and status notifications.

The canonical planning doc is [docs/ROADMAP.md](docs/ROADMAP.md). Detailed specs for the next worktrees live under [docs/specs](docs/specs).

## Current Architecture

- `Clawk/Clawk`: iOS app target, product name `KishOS`.
- `Clawk/KishOSMac`: macOS app target.
- `Clawk/KishOSCore`: shared models, stores, agent client, feature map, and reusable views.
- `Clawk/KishOSWidget`: widgets and Live Activity support.
- `backend/`: legacy Node relay/dashboard backend. It remains in the repo for now, but the primary native chat path uses `KishAgentClient` against the Mac mini agent. Prefer deleting old relay/dashboard code once native replacements are confirmed.

The default native agent endpoint is `http://kishs-mac-mini-1:17891`. Runtime conversations, projects, attachments, branch changes, and streaming tool events are served by the Mac mini agent.

## Live Capabilities

- Persistent, shared conversations across iOS and macOS.
- Concurrent chat sends per conversation, so one running chat does not disable input everywhere.
- Project folder picker with browse, search, custom paths, recent paths, and branch switching.
- Native file/photo attachments and `@` file/folder references.
- Streaming agent text, event rows, tool activity, approvals, and capability inventory.
- Conversation search, retry, offline queue, and delete reconciliation.
- Push-to-talk, live-call mode, spoken replies, wake phrase support, audio route awareness, and Live Activity summaries.
- Snapshot review and status notifications for background work.

See [docs/ROADMAP.md](docs/ROADMAP.md) for what is available, in progress, deferred, and planned.

## Setup

Install Xcode and XcodeGen, then generate the project:

```bash
./generate-project.sh
```

Open the generated Xcode project:

```bash
open Clawk/Clawk.xcodeproj
```

Run either:

- `Clawk` for the iOS app.
- `KishOSMac` for the macOS app.

The Mac mini agent must be reachable from the device or simulator at `http://kishs-mac-mini-1:17891`, or the endpoint must be changed in `KishAgentClient`.

## Verification

Focused macOS agent-client tests:

```bash
xcodebuild test -project Clawk/Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/AgentClientTests
```

iOS simulator build:

```bash
xcodebuild build -project Clawk/Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS Simulator'
```

Ralph verification queue:

```bash
.ralph/verify.sh
```

## Docs

- [docs/ROADMAP.md](docs/ROADMAP.md): canonical live status and roadmap.
- [docs/specs](docs/specs): detailed specs for upcoming worktrees.
- [HANDOFF.md](HANDOFF.md): current handoff for the next agent.
- [SETUP.md](SETUP.md): detailed local setup.
- [TESTFLIGHT.md](TESTFLIGHT.md): TestFlight build and upload notes.
- [docs/features](docs/features): feature-specific docs that are still useful.
