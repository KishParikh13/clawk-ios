# Handoff: Project Folder Selector

**Date:** 2026-06-04
**For:** the next agent picking this up
**Branch:** `KishParikh13/project-folder-selector` (app repo)

Read these two first, they are the source of truth:
- Spec: `docs/superpowers/specs/2026-06-04-project-folder-selector-design.md`
- Plan: `docs/superpowers/plans/2026-06-04-project-folder-selector.md` (bite-sized, TDD, exact code)

This handoff covers what is DONE, what is LEFT, and the traps that are not obvious from the plan alone.

---

## What the feature does

Let a conversation start in a chosen folder on the Mac mini instead of always running from `$HOME`. Default is Home (`~`). The picker's default list is `~/Code` (recents + browse), but **any existing directory is valid** and the user can paste a path (including `~/...`). The folder is **fixed for the life of a conversation**. Each conversation shows a project + git-branch badge. Folders you chat with get pinned. iOS and Mac both get the picker.

## The architecture in one paragraph

The app (this repo, Swift) talks directly to the **kish-agent HTTP server on the mini** at `http://kishs-mac-mini-1:17891`. The app sends `{threadId, message, conversationId, attachments, projectPath}` to `/chat-stream`. The agent maps `threadId` to a persisted session, and now binds `projectPath` to that session on the first turn and spawns Claude/Codex with `cwd = that folder`. The agent also mirrors conversations in `.kishos-conversations.json` and serves them via `/conversations`, so `projectPath` + `projectName` + `branch` round-trip back to every device. **Two repos, ships as one feature.**

---

## STATE: what is done

### Agent half — DONE, committed locally, NOT deployed, NOT pushed to GitHub

Repo: `~/Code/kish-agent` on the **laptop** (`kishs-macbook-pro`). 7 commits on `main`, from `44114bc` to `b829e27`. Tests: `cd ~/Code/kish-agent/listener && node --test projects.test.js` → 10/10 pass. `node --check index.js` clean.

What landed:
- `listener/projects.js` (new) + `listener/projects.test.js` (new): `validateProjectPath` (accepts any existing dir, expands leading `~`, rejects missing path / file, returns home-relative `relPath`), `listProjects` (7-day recents or full `~/Code` list), `gitBranch` (via `git symbolic-ref --short HEAD`, null if no repo/detached).
- `listener/index.js`: `runClaude`/`runCodex` take a `cwd` param; `runHttpTurn` binds the folder on first turn (persists to thread state, falls back to `$HOME` if it vanishes, returns `ok:false` on bad path); `beginSharedConversationTurn` stores `projectPath`/`projectName`/`branch` on the conversation record; new `GET /projects` route (`?all=1` for the full list).

**Two things NOT done on the agent:**
1. **Not deployed to the mini.** The mini still runs the old code. Deploy = Plan Task A6: `~/Scripts/code-sync.sh kish-agent push` then `ssh kishparikh@kishs-mac-mini-1 'launchctl kickstart -k gui/$(id -u)/com.kishparikh.kishos-bot'`, then the curl verifications in A6. **This restarts Kish's always-on bot — get his explicit OK before running it.**
2. **Not pushed to GitHub** (`origin` = `https://github.com/KishParikh13/kish-agent.git`). Decide with Kish whether to `git push` the agent commits.

### App half — NOT STARTED (only docs committed)

No Swift code written yet. Plan Phases B, C, D, E are all open. The only app-repo commits for this feature are the spec, the plan, and a docs-update commit (`9a5c409`).

---

## TRAP 1 (most important): Kish is editing the same files live

At handoff, the app workspace had **uncommitted changes** in:
`Clawk/Clawk/KishOSIOSRootView.swift`, `Clawk/KishOSCore/Conversation.swift`, `Clawk/KishOSCore/KishOSWorkspace.swift`, `Clawk/KishOSMac/KishOSMacApp.swift`, `Clawk/Clawk/KishOSLiveActivityController.swift`.

Phase B/C/D edit four of those same files. **Do not start Phase B until Kish's concurrent edits are committed and the tree is stable**, or you will collide. When you resume:
1. `git status` — if those files are still dirty, ask Kish to commit/stash first, or confirm which lines are his.
2. Re-read the current versions of `Conversation.swift`, `KishOSWorkspace.swift`, `KishOSIOSRootView.swift`, `KishOSMacApp.swift` before editing — the plan's line numbers and anchor strings may have moved. Anchor on the quoted code, not the line numbers.

## TRAP 2: the app codebase drifts; re-read before editing

This tree moves fast (attachments + live-activity work landed mid-design). The plan's exact line numbers are stale by nature. Every plan task says which function/struct to edit and quotes the surrounding code — match on the quoted text and re-grep for current locations. Confirmed-stable facts as of handoff: `Conversation` struct head (fields/init/CodingKeys) is unchanged from the plan; `AgentClient.sendStreaming` already has an `attachments:` param and `ChatRequest` already has `attachments`; the iOS root view already calls `sendStreaming(..., attachments:)`.

## TRAP 3: agent edits happen on the laptop, deploy is manual

`~/Code/kish-agent` is checked out on the laptop and is identical to the mini's copy (both were at `78a0f1e` before this work). Edit + `node --test` locally, then deploy with code-sync + launchctl (Task A6). Never edit the mini's copy directly. Do not run `code-sync` while a git op is in progress on either side. Restart label: `com.kishparikh.kishos-bot`. Health check: `curl -s http://kishs-mac-mini-1:17891/health` → `{"ok":true}`.

## TRAP 4: KishOSCore access control

Before adding `public` to new core types (`Project`, `ProjectStore`, `ProjectCatalog`), check the prevailing convention: `grep -n "public" Clawk/KishOSCore/Conversation.swift`. KishOSCore is compiled directly into the app targets, so it almost certainly uses **no** `public`. Match it or you get a wall of access errors. (Plan Task B2 Step 3 has this note too.)

## TRAP 5: new files must be registered with XcodeGen

The project is generated from `Clawk/project.yml`. New `.swift` files under `KishOSCore/`, `Clawk/`, `KishOSMac/`, `KishOSMacTests/` must be added to the project (run the repo's generate step / `xcodegen generate`, or add in Xcode). A file that compiles locally but is missing from its target fails the build. (Plan Task B2 Step 0.)

---

## What is LEFT, in order

1. **Task A6 — deploy the agent + curl-verify** (gated on Kish's OK; restarts the bot). After this the backend is live and Phase B+ can be validated end to end.
2. **Phase B — KishOSCore (Swift, TDD via `KishOSMac` scheme / `KishOSMacTests`):** project fields on `Conversation`; `Project` + `ProjectListResponse`; `fetchProjects` + `projectPath` on `ChatRequest`/`sendStreaming`/`send`; `ProjectStore` (pinned, UserDefaults); `createConversation` passthrough.
3. **Phase C — iOS UI:** `ProjectCatalog`; `ProjectPickerSheet` (Home / recents / browse / search / **paste a path**); composer chip; send `projectPath`; sidebar badge.
4. **Phase D — Mac UI:** `ProjectPickerPopover` (same, incl. paste a path); wire chip + send + badge into `KishOSMacApp.swift` (read that file first — Phase D is structural and references Phase C for the repeated code).
5. **Phase E — full suite + device smoke test + cross-device sync check.**

Test command (from `Clawk/`):
`xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/<Class>`

---

## Design decisions already locked (do not relitigate)

- **Any existing directory is valid.** No `~/Code` containment check (the agent already runs from `$HOME` with full access, so a chosen folder is never broader). Reject only missing paths and files. `~/Code` is the *default list* only; paste-a-path escapes it.
- **Folder is fixed at creation.** Agent enforces it (first binding wins); app reflects it (the chip locks to a read-only badge once the conversation has messages). No "change folder" affordance.
- **Branch via `git symbolic-ref --short HEAD`** (handles brand-new repos with no commits; the plan's older `rev-parse --abbrev-ref` text was superseded).
- **`projectPath` is sent on every turn**; the agent binds on the first and ignores it after.

## Environment quick reference

- Mini: `kishs-mac-mini-1` / `100.96.61.83`. Laptop: `kishs-macbook-pro` / `100.84.197.54`. Both user `kishparikh`, passwordless SSH both ways. Skill: `remote-mac-access`.
- Agent URL: `http://kishs-mac-mini-1:17891`. Endpoints: `/health`, `/chat`, `/chat-stream`, `/conversations`, `/conversations/:id` (DELETE), `/tools`, `/approve`, `/attachments`, and new `/projects`.
- No auth header needed (no `HTTP_TOKEN` set on the mini; `httpAuthorized` returns true).
- Node on laptop: v23. On mini: v25. Use a login shell for node over SSH: `ssh kishparikh@kishs-mac-mini-1 'zsh -lc "node --version"'`.
