# KishOS Handoff

Last updated: 2026-06-04

## Current State

- Repo: `https://github.com/KishParikh13/clawk-ios/tree/main`
- Current source of truth: `docs/ROADMAP.md`
- Detailed specs: `docs/specs/glasses-voice-hands-free.md` and `docs/specs/memory-routines.md`
- Code-backed feature list: `Clawk/KishOSCore/KishOSFeaturePlan.swift`
- Ralph queue history: `.ralph/prd.json`

The native KishOS app is live as the primary product path. It uses shared SwiftUI code across iOS and macOS and talks to the Mac mini `kish-agent` at `http://kishs-mac-mini-1:17891`.

## Recent Commits

- `f9f3879 chore: ignore local conflict and xcode files`
- `df645be fix: allow concurrent chat sends`

The concurrency fix scopes send disablement to the active conversation, so a running chat no longer disables input in unrelated chats.

## Last Verified

```bash
xcodebuild test -project Clawk/Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/AgentClientTests
xcodebuild build -project Clawk/Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS Simulator'
```

## Planning Focus

The next major work should be split into separate worktrees:

- Glasses/voice hands-free: `docs/specs/glasses-voice-hands-free.md`
- Memory/routines: `docs/specs/memory-routines.md`

Kish direction: the product is many-chat for now, moving toward supervised autonomy where the app captures ideas/input, turns them into specs/work items, and eventually helps improve itself. Old relay/dashboard code should be deleted when native replacements are verified, rather than kept around indefinitely.
