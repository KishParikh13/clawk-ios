# Project folder selector — design

**Date:** 2026-06-04
**Status:** Approved, ready for implementation plan

## Goal

Let me choose which folder on the mini a conversation runs in. Default is home (`~`).
The default pick list is `~/Code` (recents + browse), but any existing directory is
valid: I can paste a path (including `~/...`) to run anywhere. The folder is fixed for
the life of a conversation. Each conversation shows a small project badge plus its
current git branch. Recently edited folders (last 7 days) are the quick-pick list, I
can browse the rest of `~/Code`, and once I chat with a folder it stays pinned.

Both halves (app + agent) ship together. The feature does nothing without the agent
honoring the chosen folder as the working directory.

## Current state (confirmed)

- The iOS/Mac app talks directly to the kish-agent HTTP server on the mini
  (`~/Code/kish-agent/listener/index.js`) over HTTP, sending `{threadId, message,
  conversationId, attachments}` to `/chat-stream`.
- The agent maps each `threadId` to a saved session in `.slack-sessions.json`
  (`{engine, claude: sessionId, codex: threadId}`), then spawns Claude/Codex with
  `cwd = AGENT_CWD = os.homedir()` always. Every conversation runs from home today.
- The agent mirrors conversations in `.kishos-conversations.json` keyed by
  `conversationId` (shape matches the Swift `Conversation` Codable). `/conversations`
  returns them; the app merges via `mergeRemoteConversations`. So project + branch can
  round-trip to every device through the existing sync.
- `~/Code` has ~140 folders, ~40 are git repos.

## Architecture

### Agent (kish-agent listener on the mini)

1. **cwd binding.** `/chat` and `/chat-stream` accept a new optional `projectPath`.
   On the first turn of a thread the agent validates it, stores it on the thread state
   (`.slack-sessions.json`) and on the conversation record, then spawns Claude/Codex
   with `cwd = boundPath || $HOME`. Later turns reuse the stored binding, so the folder
   is fixed for the conversation's life.
2. **Validation.** `projectPath` may be any path (a leading `~` is expanded). It must
   resolve to an existing directory; otherwise the turn returns `ok:false`
   (`not_found` / `not_directory`) and the app falls back to Home. No `~/Code`
   containment check — the agent already runs from `$HOME` with full access, so a
   chosen folder is never broader than the default.
3. **`/projects` endpoint.** Scopes the *default list* to `~/Code` (discovery only;
   pasted paths bypass it).
   - `GET /projects` → recents: top-level dirs under `~/Code` modified within 7 days,
     newest first.
   - `GET /projects?all=1` → every top-level dir under `~/Code` for the browse list,
     sorted by name.
   - Each entry: `{name, path, relPath, branch, lastModified}`. Branch via
     `git -C <dir> symbolic-ref --short HEAD` (null if not a repo or detached).
4. **Conversation records** (`.kishos-conversations.json`) gain `projectPath`,
   `projectName`, `branch`. `beginSharedConversationTurn` stores `projectPath` /
   `projectName` from the input on the first turn. Branch is recomputed when
   `/conversations` is built (cheap, cached per build). These flow back via sync.

### App (KishOSCore + iOS + Mac)

1. **Model.** `Conversation` gains `projectPath: String?` (nil = Home),
   `projectName: String?`, `branch: String?`, all `decodeIfPresent` for back-compat.
   New `Project` value type `{name, path, relPath, branch?, lastModified?}`. Client
   methods `fetchRecentProjects()` and `fetchAllProjects()` hit `/projects`.
2. **Send path.** `createConversation` records the chosen project. `send` /
   `sendStreaming` include `projectPath` in the request (sent every turn; the agent
   binds on the first and ignores it thereafter).
3. **Picker.** A "Project" chip in the composer row (next to `+`), prominent on the
   empty new-chat screen, showing "Home" or the folder name + branch. Tap opens a
   sheet: a "Recent (7 days)" section, a "Browse all folders" row to the full `~/Code`
   list, a search field, and a "Use a custom path" field to paste any directory (e.g.
   `~/Desktop/scratch`). Pinned folders (any I've chatted with, remembered in
   `UserDefaults`) float to the top even if outside the 7-day window. Once the
   conversation has messages the chip locks to a read-only badge (fixed at creation).
4. **Sidebar.** Each conversation row in the `ConversationPicker` shows a small folder
   badge + branch glyph. Home chats read "Home". Same on both platforms: iOS uses a
   sheet, Mac a popover, with shared SwiftUI underneath.

## Data flow

New chat → pick project (or Home) → first send carries `projectPath` → agent
validates, binds cwd to the thread, runs Claude there, saves project on the record →
reply → `/conversations` sync returns project + branch → all devices render the badge.

## Edge cases

- **Deleted/moved or mistyped folder.** A new bind to a missing path or a file returns
  `ok:false` (`not_found` / `not_directory`); the app surfaces the error and offers
  Home. A previously bound folder that later vanishes falls back to `$HOME` with an
  activity note and null branch.
- **Back-compat.** Old conversations with no `projectPath` are treated as Home.
- **Offline/queued.** A queued first message stores the project locally on the
  conversation and sends it when the queue drains.
- **Non-repo folder.** Branch is null; the badge shows the folder name only.
- **Pasted paths.** A leading `~` is expanded; the path is realpath-resolved before
  use.

## Testing

- **Agent:** path validation (any existing dir accepted, nonexistent + file rejected,
  `~` expansion + home-relative display), `/projects` 7-day recents filter, branch
  resolution, cwd binding persists across a restart, fallback to `$HOME` when a bound
  folder vanishes.
- **Core:** `Conversation` Codable round-trip with and without `projectPath`;
  `createConversation` sets the fields; `ChatRequest` encodes `projectPath`; pinned
  store persistence.

## Out of scope (future)

- Diff counts (+/-) per row, like the screenshot.
- Changing a conversation's folder after creation.
- A full filesystem browser (the paste-a-path field covers folders outside `~/Code`;
  deeper in-app navigation can come later).
- Per-conversation worktrees or branch creation.
