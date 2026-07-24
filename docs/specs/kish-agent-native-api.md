# kish-agent Native API Contract

Last updated: 2026-06-10

KishOS talks directly to `kish-agent` through `KishAgentClient`. The default development endpoint is:

```text
http://kishs-mac-mini-1:17891
```

Both iOS and macOS let the user override this URL at runtime. The app stores the override in `UserDefaults` under `KishOSAgentBaseURL`.

## Health

`GET /health`

Minimum response:

```json
{ "ok": true }
```

Recommended response for demo and release readiness:

```json
{
  "ok": true,
  "version": "2026.06.10",
  "endpoints": [
    "health",
    "chat-stream",
    "cancel",
    "conversations",
    "attachments",
    "approve",
    "projects",
    "projects/files",
    "projects/branches",
    "projects/switch-branch",
    "tools"
  ]
}
```

If `endpoints` is omitted, KishOS keeps the connection usable and shows the native API status as `Unknown`. If `endpoints` is present and missing a required path, KishOS shows `Needs update`.

## Required Endpoints

- `POST /chat-stream`: stream agent turns as newline-delimited JSON events.
- `POST /cancel`: cancel an active thread by `threadId`.
- `GET /conversations`: fetch shared conversation history.
- `DELETE /conversations/:id`: delete a conversation.
- `POST /attachments`: upload multipart file/photo payloads.
- `POST /approve`: answer or reject pending agent questions/approvals.
- `GET /projects`: list recent or all project folders.
- `GET /projects/files`: list files/folders for `@` references.
- `GET /projects/branches`: list project branches/worktrees.
- `POST /projects/switch-branch`: switch branches, optionally with a dirty-worktree action.
- `GET /tools`: report available commands, engines, and recent tools.

## Publish Requirement

Before giving KishOS to anyone outside the current personal setup, make the agent endpoint discoverable or user-configurable during onboarding and protect it with an authentication model appropriate for the deployment network.
