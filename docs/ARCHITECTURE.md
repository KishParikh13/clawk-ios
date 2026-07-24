# Architecture

Last updated: 2026-06-10

## Active Product Path

KishOS is a native SwiftUI app that talks directly to `kish-agent` on the Mac mini.

- iOS entry point: `Clawk/Clawk/ClawkApp.swift` -> `KishOSIOSRootView`.
- macOS entry point: `Clawk/KishOSMac/KishOSMacApp.swift` -> `MacRootView`.
- Shared native core: `Clawk/KishOSCore`.
- Widget/Live Activity extension: `Clawk/KishOSWidgets`.
- Native backend client: `KishAgentClient`.
- Default endpoint: `http://kishs-mac-mini-1:17891`.

The active app model is conversation-first:

- `KishAgentClient` owns HTTP requests, streaming, attachment upload, project APIs, branch switching, approvals, health, cancel, and tools.
- `KishOSWorkspace` owns local conversation state, queueing, streaming updates, approvals, retries, deletion, and sync merge.
- `Conversation` and related message/reference/attachment models are the durable shared data shape.

## Legacy Paths

The repo still contains older dashboard, gateway, relay, cron, and memory surfaces:

- `backend/`
- `GatewayConnection`
- `GatewayProtocol`
- `DashboardAPIClient`
- dashboard/gateway views such as `MainTabView`, `HomeView`, `DashboardView`, `CronManagementView`, `MemoryView`, `GatewayChatView`, `CostsView`, and related old settings views.

These are not the source of truth for new native KishOS work. They remain because the iOS target currently compiles the whole `Clawk/Clawk` directory, and some old types reference each other. Delete them only with a verification gate.

## Safe Cleanup Plan

1. Move active iOS views into an explicit `KishOSNative` source group or target path.
2. Move old dashboard/gateway views into a `LegacyDashboard` group.
3. Remove `LegacyDashboard` from the iOS target.
4. Delete `backend/` and old relay docs after confirming no demo workflow depends on them.
5. Run `scripts/verify-local.sh`.

## New Work Guidance

- Build new chat, project, voice, glasses, supervision, memory, and routines work against `KishAgentClient`, `KishOSWorkspace`, and `KishOSCore`.
- Do not add new product behavior to the gateway/dashboard path.
- If a useful old screen exists, port the behavior into the native conversation model instead of extending the legacy models.
