# KishOS Live Status and Roadmap

Last updated: 2026-06-04

This is the source of truth for roadmap, PRD, feature-list, and Ralph queue status. The code-backed capability list lives in `Clawk/KishOSCore/KishOSFeaturePlan.swift`. Completed Ralph queue history lives in `.ralph/prd.json`. Detailed specs for the next worktrees live in `docs/specs`.

## Current Product Shape

KishOS is a native iOS and macOS shell for working with the `kish-agent` running on Kish's Mac mini. The shared app surface is built in SwiftUI with `KishOSCore` as the common package for models, stores, client logic, feature metadata, and reusable views.

The primary chat path is native:

- App target: `Clawk` on iOS.
- Desktop target: `KishOSMac` on macOS.
- Shared code: `Clawk/KishOSCore`.
- Widget and Live Activity target: `Clawk/KishOSWidget`.
- Agent endpoint: `http://kishs-mac-mini-1:17891`.

The legacy `backend/` relay remains in the repo for old dashboard paths, but it is not the source of truth for the current native chat experience. Direction from Kish: delete old code, especially code already tracked in git, once native replacements are confirmed and the cleanup has a clear verification gate.

## Product Direction

KishOS is a many-chat command center right now. The target is supervised autonomy: Kish gives input, ideas, corrections, and approvals through the app; the system remembers useful context, turns ideas into specs/work items, runs bounded work in separate worktrees, verifies it, and asks for review before risky actions or merge decisions.

The next two major specs should be developed in separate worktrees:

- `docs/specs/glasses-voice-hands-free.md`: make voice, live call, and glasses/headset audio feel like one reliable hands-free mode.
- `docs/specs/memory-routines.md`: build durable memory, daily briefs, routines, and the first safe path toward app self-improvement.

Recent direction from Kish:

- First hands-free hardware target is Meta Ray-Ban Gen 2.
- Desired glasses experience: wear glasses and start live voice with KishOS at any time.
- Later glasses phases should support explicit photo/video capture from what Kish is looking at.
- Memory should proactively learn from chats and available context all the time.
- Routines should be always-on loops that reflect on activity, identify patterns, and propose new routines.
- New routines require approval before being enabled.
- KishOS can do safe prep autonomously, but needs approval before long coding tasks, sending email/Slack, deleting anything, or other irreversible actions.

## Live Capabilities

### Chat and Session Core

- Native iOS and macOS shells.
- Persistent conversations mirrored from the Mac mini agent.
- Shared conversation store across app surfaces.
- Retry for failed messages.
- Offline queue for sends while disconnected.
- Delete reconciliation.
- Conversation search.
- Concurrent sends scoped per conversation, so one running chat does not disable input in every chat.

### Project Context

- Project folder selector outside the composer.
- Browse/search/custom path project selection.
- Recent projects.
- Branch display and branch switching.
- Project context preserved in live calls.
- `@` file and folder references.
- Native file and photo attachments.
- Explicit snapshot review before sending context.

### Agent Visibility and Control

- Streaming assistant text.
- Streaming event rows and tool activity.
- Collapsed implementation steps.
- Approval and question cards.
- Compact capability truth map.
- Tool inventory view.
- Cancel and recovery behavior for live-call runs.
- Removal of duplicate assistant text during live calls.

### Voice, Call, and Notifications

- Push-to-talk input.
- Live-call mode.
- Spoken replies while in call mode.
- Wake phrase support.
- Audio route awareness.
- Audio route picker and preference for external audio.
- Live Activity summary.
- Background status notifications.

## In Progress

- Session recovery after reconnects, app restarts, or interrupted streams.
- Glasses walk mode for hands-free work while using external audio/glasses.

## Planned

- Live run timeline for clearer long-running task state.
- Interrupt steering, including mid-run correction and escalation.
- Daily brief.
- Memory pins.
- Routines.

## Deferred

- Broader connection recovery beyond the current retry/offline queue behavior.
- Decision inbox for deferred approvals and questions.

## Roadmap

### Now

Spec and then implement the two next worktrees:

- Glasses and voice hands-free mode.
- Memory, daily brief, and routines.

Keep run supervision in view because both specs depend on it:

- Session recovery.
- Live run timeline.
- Interrupt steering.
- Decision inbox shape and approval taxonomy.

### Next

Build the app into a stronger operating surface for day-to-day work and a safer path to autonomy:

- Daily brief.
- Memory pins.
- Routine definition and execution.
- Self-improvement idea capture and spec generation.
- Better project safety around branch switching, dirty worktrees, and context selection.
- Stronger notification routing for background tasks.

### Later

Expand wearable and multimodal workflows after the core agent loop is reliable:

- DAT vision spike for Meta glasses when the platform path is available.
- Display/status surface for hands-free review.
- More structured autonomy around recurring work, handoffs, review queues, and separate-worktree implementation jobs.

## Completed Ralph Queue

`.ralph/prd.json` currently records completed and passing user stories:

- Collapsed implementation steps.
- Call button beside mic.
- Project selector moved out of composer.
- `@` file and folder references.
- Upload-first image flow.
- Conversation search.
- Cancel active live-call runs.
- Remove duplicate live-call assistant text.
- Recover failed live-call runs.
- Clear partial transcript on mute.
- Simplify live-call header.
- Preserve project context in live calls.
- Snapshot review.
- Background notifications.
- Compact capability truth.

Use `.ralph/verify.sh` to rerun the queue verifier.

## Risks and Dependencies

- The Mac mini `kish-agent` must stay reachable from devices and simulators.
- Project, attachment, file-reference, and branch endpoints must remain deployed on the agent.
- True session recovery needs persisted run state from the backend, not only local UI state.
- Glasses DAT work depends on Meta platform access, permissions, and a stable developer preview path.
- Memory and routines should integrate the existing `kish-context` system rather than rebuilding context from scratch.

## Specs

- `docs/specs/glasses-voice-hands-free.md`
- `docs/specs/memory-routines.md`

## Planning Questions

Open product decisions to settle before implementation:

- For hands-free start, should wake phrase, Shortcut/Siri, Lock Screen action, or in-app call be the first reliable trigger?
- Should daily brief run automatically, on demand, or both?
- Should routine outputs share one conversation or create routine-specific conversations?
- Which old relay/dashboard code can be deleted first without losing a workflow Kish still uses?
