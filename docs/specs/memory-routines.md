# Memory and Routines Spec

Last updated: 2026-06-04

Suggested worktree: `memory-routines`

## Problem Statement

KishOS is becoming a many-chat command center, but useful autonomy requires continuity across chats, days, projects, agent runs, context sources, and correction history. The app can show conversations, project context, background notifications, legacy memory files, and legacy cron jobs, but it does not yet expose the always-on learning and routine system that Kish wants.

The next step is to turn memory and cron into proactive learning plus approved routines: KishOS should learn from chats and available context all the time, reflect on what happened, find patterns, propose new routines, and execute safe recurring work. Newly identified routines require approval before they are enabled.

## Product Thesis

The destination is a system that helps build itself. Kish should be able to give input, ideas, constraints, and corrections through the app; KishOS should remember them, reflect on them, turn them into specs or routines, do safe prep automatically, and ask for approval only for high-risk actions.

For now, KishOS remains a many-chat command center. Memory and routines are the path from many-chat to supervised autonomy.

## Approval Philosophy

Allowed without per-action approval after the relevant tool/source/routine is enabled:

- Read chats, conversations, memory, project metadata, approved context sources, and recent run history.
- Reflect on activity and extract memory candidates.
- Update non-sensitive observed memory with provenance.
- Generate briefs, summaries, specs, plans, and draft artifacts.
- Run lightweight analysis and status checks.
- Propose new routines.
- Run enabled safe routines.

Requires approval:

- Enable a new routine.
- Initiate a long coding task or implementation job.
- Send email.
- Send Slack messages.
- Delete files, memory, routines, conversations, or external records.
- Merge, deploy, publish, purchase, transfer money, or perform other irreversible actions.
- Act on sensitive personal/legal/financial/health/family/credential data outside read-only summarization.

## Current Baseline

Live or implemented in some form:

- Native persistent conversations and shared sync.
- Project/folder context locked per conversation.
- Attachments and `@` references.
- Approval/question cards.
- Status notifications and Live Activity summary.
- Capability map.
- Legacy `MemoryView` and `DashboardAPIClient` memory file endpoints in the old dashboard path.
- Legacy `CronManagementView` and gateway cron models in the old dashboard path.
- `.ralph/prd.json` as a completed story queue and `.ralph/verify.sh` as a verifier.
- Existing personal context engine in `/Users/kishparikh/Code/kish-context`.
- Existing screen/context capture work in `/Users/kishparikh/Code/screencontext-macos-backup`, `/Users/kishparikh/Code/screencontext-landing`, and `/Users/kishparikh/Code/limitless`.
- Existing memory/dashboard precedent in `/Users/kishparikh/Code/vibecraft`.

Known gaps:

- Native app does not consume `kish-context` memory/routine state directly.
- Memory is not integrated into the primary native KishOS chat surface.
- Legacy memory is file-oriented, not user-intent oriented.
- Cron jobs are infrastructure-oriented, not routine-oriented.
- There is no native daily brief product flow.
- There is no native routine proposal/review lifecycle.
- There is no native routines page for user-created and agent-proposed routines.
- There is no first-class bridge from ideas/feedback to app self-improvement routines.

## Existing Context Assets to Integrate

### `/Users/kishparikh/Code/kish-context`

Primary prior art and likely backend source of truth. It is a personal context engine built from Claude Code history, messages, projects, Slack/Gmail/Notion/calendar sources, and voice/work-pattern analysis.

Useful assets:

- `kish.md`: master context.
- `index.md` and `wiki/`: canonical memory graph.
- `WIKI-SCHEMA.md`: maintenance model.
- `assistant/ROUTINES.md`: scheduled jobs and always-on Mac mini routines.
- `assistant/brief-latest.md`: current brief artifact.
- `docs/data-sources.md`: tapped and next sources.
- `docs/research-memory-learning.md`: researched memory/self-improvement strategy.
- `scripts/build_reflector_payload.py`: bounded read-only evidence payload for nightly reflection.
- `scripts/memory_apply.py`: applies accepted memory proposals to canonical wiki blocks.
- `scripts/nightly_refresh.py`, `scripts/mini_autoingest.sh`, `scripts/reconcile.py`, `assistant/build_queue.py`: existing ingest/proposal/review loop.

Spec implication:

- Do not rebuild this blindly inside the app.
- The native app should surface, control, and extend this system.
- The Mac mini agent should expose native KishOS endpoints over the existing `kish-context` proposal/memory/routine data.

### ScreenContext and Limitless

Relevant repos:

- `/Users/kishparikh/Code/screencontext-macos-backup`
- `/Users/kishparikh/Code/screencontext-landing`
- `/Users/kishparikh/Code/limitless`

These capture screen activity, OCR, app/window titles, session summaries, search, and local APIs. They are relevant as context sources for "what was I doing?" and pattern detection.

Spec implication:

- Treat screen context as an optional source with explicit privacy controls.
- Use summaries and patterns before promoting anything to durable memory.

### Vibecraft

Relevant repo:

- `/Users/kishparikh/Code/vibecraft`

Contains prior memory dashboard/API concepts, including `/api/memory/list` and `/api/memory/file`, plus event/activity capture ideas. Useful for UI/API precedent, but not the native product source of truth.

## Goals

- Let KishOS proactively learn durable memory from normal chat and available context all the time.
- Make memory inspectable, editable, pinnable, and forgettable.
- Generate concise daily briefs from active chats, recent runs, open decisions, project state, prior context systems, and routine outcomes.
- Let Kish and the agent create routine proposals; require explicit approval before enabling new routines.
- Add a native routines page for enabled, proposed, paused, failed, and recently-run routines.
- Let enabled safe routines run without asking every time.
- Create the first safe path toward self-improvement: ideas become specs and prep work automatically; long coding starts only after approval.

## Non-Goals

- No invisible memory system. Proactive learning is allowed, but memory must be visible, editable, and forgettable.
- No initiating long coding tasks without explicit approval and verification.
- No sending email or Slack messages without explicit approval.
- No deleting anything without explicit approval.
- No irreversible actions without explicit approval.
- No replacing normal chat with a separate productivity dashboard.
- No broad third-party account automation unless the relevant connector/tool is authenticated and approved.
- No speculative vector database requirement before the memory model is useful.

## Personas

### Kish, using many chats

Needs the app to remember preferences, active projects, open decisions, and "what we decided" without manually searching old threads.

### Kish, starting a day

Needs a short brief: what changed, what is waiting, what matters today, which routines ran, and what the system learned.

### Kish, improving KishOS

Needs to say ideas naturally, have the system learn them, turn them into specs, and eventually queue implementation in separate worktrees when approved.

### Agent/routine executor

Needs a narrow contract: what to run, when to run, what context is allowed, what requires approval, where to report, and how to avoid duplicate work.

## Product Model

### Memory Types

Preference:

- Stable user preference or instruction.
- Example: "For unrelated major features, use separate worktrees."

Project fact:

- Durable information about a project/repo/workstream.
- Example: "KishOS native chat uses the Mac mini agent at `http://kishs-mac-mini-1:17891`."

Open decision:

- Choice that still needs Kish.
- Example: "Should wake phrase start live call or shortcut into the app?"

Active task:

- Work that is ongoing or waiting for review.
- Example: "Spec glasses/voice and memory/routines separately."

Learning:

- Retrospective fact from implementation, rejection, or correction.
- Example: "Old relay dashboard is not source of truth for native KishOS."

Routine instruction:

- Durable instruction attached to a recurring routine.
- Example: "Every morning, summarize active KishOS worktrees and ask what to prioritize."

Context observation:

- Fact learned from approved context sources such as `kish-context`, ScreenContext, or run history.

### Memory Lifecycle

States:

- `observed`: agent extracted a possible memory from chat/context.
- `active`: memory is available for retrieval/context.
- `pinned`: Kish explicitly blessed the memory as durable and important.
- `conflicted`: new evidence conflicts with older memory.
- `archived`: retained but not actively used.
- `forgotten`: removed or excluded from future context.

Rules:

- KishOS can proactively create observed/active memories from chats and trusted context without interrupting Kish.
- Important or sensitive memory should be promoted to pinned only through explicit action or clear user instruction.
- Every memory has provenance: source conversation, message id, source file/context, date, and author/process.
- Every memory can be forgotten from the app.
- Conflict handling asks Kish or creates a review item rather than silently overwriting.
- Sensitive categories require review before they can drive external action.

### Routine Types

Daily brief:

- Summarizes active work, recent outcomes, pending decisions, routine results, memory changes, and suggested priorities.

Reflection loop:

- Looks across recent chats, memory changes, routine outcomes, rejected proposals, and approved context sources to identify patterns.

Nudge:

- Watches for blocked, failed, stale, or review-needed runs and asks Kish whether to resume, cancel, or defer.

Project maintenance:

- Runs bounded checks on a project: status, tests, stale branches, docs to clean, open TODOs.

Self-improvement proposal:

- Turns feedback/ideas into specs, worktree plans, or implementation queue items.

Review queue:

- Collects completed routine outputs or agent work needing approval.

### Routine Lifecycle

States:

- `draft`: generated from a user request.
- `proposed`: generated by the agent/reflection loop.
- `needsApproval`: schedule/action/safety scope awaits Kish approval.
- `enabled`: routine can run.
- `running`: one routine run is active.
- `needsReview`: output or approval is waiting.
- `paused`: routine will not run until resumed.
- `disabled`: routine is off.
- `failed`: last run failed and needs attention.

Rules:

- Routines can be created by Kish or proposed by the agent.
- New routines are not enabled until Kish approves them.
- Every routine has a trigger, allowed context, allowed tools/projects, output destination, and approval policy.
- Routine runs are idempotent and create a normal conversation/run record.
- Routine output is visible in the many-chat surface, not hidden in a cron table.
- Safe enabled routines can run without per-run approval.

## UX Requirements

### Native Memory Surface

Create a native memory surface reachable from the conversation panel/settings.

Sections:

- Pinned memories.
- Active observed memories.
- Conflicts and sensitive items needing review.
- Recently learned.
- Forgotten/archived filter.

Actions:

- Search/filter.
- Open source conversation/context.
- Edit.
- Pin.
- Archive.
- Forget.
- Resolve conflict.

Acceptance:

- Given an observed memory, Kish can pin/edit/forget it.
- Given Kish forgets a memory, it is excluded from future briefs/routines.
- Given a memory came from a conversation or context source, the source can be opened or inspected.

### Chat Memory Actions

Within a conversation:

- "Remember this."
- "Forget this."
- "Turn into routine."
- "Add to daily brief."
- "Spec this idea."

Acceptance:

- Given a message contains a durable preference, when Kish chooses Remember this, a memory draft appears with editable text and type.
- Given a memory is active/pinned, future daily brief generation can include it.

### Daily Brief

Daily brief should be a normal generated artifact with a compact entry point.

Sections:

- Today: 3-5 recommended priorities.
- Waiting on Kish: pending questions/approvals.
- Active work: running or recent conversations.
- Routines: what ran, failed, or needs review.
- Memory changes: new, pinned, conflicted, or forgotten.
- Patterns noticed: recurring themes from reflection loop.
- Ideas to improve KishOS: optional suggestions based on feedback.

Acceptance:

- Given there are active threads and pending decisions, daily brief includes them with source links.
- Given there are no active items, brief is short and says what it checked.
- Given routines ran overnight, brief includes routine results.

### Routines Page

Add a native routines page.

Sections:

- Enabled routines.
- Proposed routines.
- Paused/disabled routines.
- Recent routine runs.
- Failures or needs-review items.

Routine row:

- Name.
- Source: user-created or agent-proposed.
- Trigger/schedule.
- Last run and next run.
- Approval policy.
- Output destination.
- Quick actions: approve, pause, run now, edit, disable.

Acceptance:

- Given reflection proposes a routine, it appears under Proposed routines.
- Given Kish approves it, it moves to Enabled routines and can run.
- Given Kish pauses it, scheduled runs do not start until resumed.

### Routine Builder

Routine creation starts from plain language.

Examples:

- "Every morning, brief me on active tasks."
- "Every weekday at 5, summarize what changed in KishOS."
- "If a run is blocked for 10 minutes, nudge me."
- "When I say an app idea, turn it into a spec draft."
- "Look across what I did today and suggest useful new routines."

Review screen:

- Name.
- Trigger/schedule.
- Allowed context.
- Allowed tools/projects.
- Approval policy.
- Output destination.
- Notification behavior.
- Dry run preview.

Acceptance:

- Given Kish asks to create a routine, app presents a draft before enabling it.
- Given agent proposes a routine, it appears in proposed state until approved.
- Given routine runs, output appears in normal conversation or review card.

### Routine Output and Review

Routine runs should not disappear into infrastructure.

- Every run has a conversation or run record.
- Output can be marked reviewed.
- Failures create notifications.
- Routines that need approval create decision cards.
- Repeated failures auto-pause after a threshold.

Acceptance:

- Given a routine fails twice, it stops spamming and asks Kish what to do.
- Given a routine produces work needing approval, app shows it in the conversation/review flow.

### Self-Improvement Loop

V1 should support:

- Capture app improvement ideas as memories or queue items.
- Generate specs from selected ideas.
- Suggest separate worktree names and verification gates.
- Do safe prep automatically.
- Ask Kish before starting long coding or implementation work.

V1 must not:

- Auto-merge code.
- Delete code without review.
- Send email or Slack.
- Start long implementation tasks without approval.
- Run broad cleanup without explicit scope.

Acceptance:

- Given Kish says an app improvement idea, KishOS can create a spec draft automatically.
- Given spec is approved, it can become an approved work item.
- Long coding work waits for explicit Kish approval.

## Requirements

### P0: Bridge Existing Context System

Requirements:

- Identify the `kish-context` data/API surface to expose through `kish-agent`.
- Add native endpoints for memory, daily brief, routine proposals, and routine runs.
- Keep provenance and review status intact.
- Avoid duplicating canonical memory in the app.

Acceptance:

- Native app can list current memory/proposals from the backend.
- Native app can show latest brief or request a new one.
- Native app can list proposed/enabled routines.

### P0: Native Memory Model and UI

Requirements:

- Add shared memory models in `KishOSCore`.
- Support observed/active/pinned/conflicted/archived/forgotten states.
- Store provenance.
- Add pin/edit/forget flows.
- Provide native memory UI.

Acceptance:

- Memory can be proactively created, inspected, edited, pinned, forgotten, and traced back to source.
- Forgotten memory is excluded from generated briefs.
- Sensitive memory is review-gated before it can drive external action.

### P0: Daily Brief V1

Requirements:

- Generate daily brief on demand.
- Inputs: active conversations, pending decisions, recent completed/failed runs, routine results, active/pinned memory, approved context summaries.
- Output appears in normal conversation or dedicated brief thread.
- Brief includes source links where possible.

Acceptance:

- Requesting a brief produces a short structured summary with active work and waiting items.
- Empty state remains useful and concise.

### P0: Routine Proposal, Approval, and Page

Requirements:

- Convert user requests and reflection findings into editable routine drafts/proposals.
- Require approval before enabling.
- Include trigger, allowed context, output destination, and approval policy.
- Support approve, pause, disable, run now, and edit.
- Add native routines page.

Acceptance:

- Kish can create, approve, pause, and disable one routine.
- Agent can propose one routine and have it appear in routines page.
- Routine cannot run until approved.

### P0: Routine Run Records

Requirements:

- Every routine execution creates a run record.
- Runs have status: queued, running, done, failed, needsReview, needsApproval.
- Runs are idempotent to avoid duplicate output after retry/reconnect.
- Output is visible from normal chat/review surface.

Acceptance:

- Routine run can be traced to routine definition and output conversation.
- Retrying after reconnect does not create duplicate routine work.

### P1: Always-On Reflection Loop

Requirements:

- Run reflection over chats, recent context, memory changes, rejected/corrected outputs, and routine outcomes.
- Identify patterns about Kish preferences, work habits, recurring tasks, and app improvement opportunities.
- Produce memory updates, proposed routines, lessons, and spec ideas.
- Record evidence for each proposal.

Acceptance:

- Daily reflection run produces useful memory updates/proposed routines or a concise "nothing new" result.
- Proposed routines stay proposed until approved.

### P1: Suggested Memories From Conversations

Requirements:

- Agent can create observed memory candidates after meaningful conversations.
- Non-sensitive candidates can become active automatically with provenance.
- Sensitive, conflicting, or high-impact candidates remain pending review.
- Candidates are concise and typed.

Acceptance:

- After conversation with durable decisions, memory candidates appear and can be pinned/edited/forgotten.

### P1: Routine Triggers Beyond Time

Requirements:

- Trigger on blocked run.
- Trigger on failed run.
- Trigger on stale conversation.
- Trigger on project/worktree status.
- Trigger on detected pattern.

Acceptance:

- A blocked-run nudge fires and stops after Kish resolves or dismisses it.

### P1: Self-Improvement Spec Routine

Requirements:

- Capture product ideas.
- Draft specs automatically when safe.
- Suggest worktree and verification gate.
- Ask Kish before long coding or implementation starts.

Acceptance:

- Idea can become a spec automatically.
- Implementation job requires Kish approval before it starts.

### P1: Memory Conflict Handling

Requirements:

- Detect likely conflicts by type/key/source.
- Show conflict card.
- Let Kish choose keep old, replace, merge, or forget both.

Acceptance:

- Conflicting preferences do not silently overwrite each other.

### P2: Retrieval and Ranking

Requirements:

- Add search/ranking when memory count grows.
- Use lessons from `kish-context/docs/research-memory-learning.md`: reconcile-dont-append, temporal invalidation, context fencing, recency + importance + relevance, hybrid lexical/vector/graph retrieval.
- Consider embeddings only after structured model proves insufficient.

Acceptance:

- No vector DB dependency blocks P0.

### P2: Worktree Execution Queue

Requirements:

- Integrate routines with Factory/Ralph-style isolated worktrees.
- Each job has spec, branch/worktree, verification command, and review gate.
- No auto-merge.
- No long coding task starts without Kish approval.

Acceptance:

- Routine can propose a worktree job, but Kish must approve before it starts.

## Technical Architecture

### Client

Likely files:

- `Clawk/KishOSCore/Conversation.swift`
- `Clawk/KishOSCore/KishOSFeaturePlan.swift`
- New `Clawk/KishOSCore/MemoryModels.swift`
- New `Clawk/KishOSCore/RoutineModels.swift`
- New `Clawk/KishOSCore/MemoryStore.swift`
- New `Clawk/KishOSCore/RoutineStore.swift`
- `Clawk/KishOSCore/AgentClient.swift`
- iOS root/settings/conversation panel files.
- Mac app settings/sidebar files.
- `Clawk/KishOSMacTests/*`

Potential models:

```swift
enum MemoryKind: String, Codable, CaseIterable {
    case preference
    case projectFact
    case openDecision
    case activeTask
    case learning
    case routineInstruction
    case contextObservation
}

enum MemoryState: String, Codable {
    case observed
    case active
    case pinned
    case conflicted
    case archived
    case forgotten
}

struct KishMemory: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: MemoryKind
    var state: MemoryState
    var text: String
    var sourceConversationID: UUID?
    var sourceMessageID: UUID?
    var sourcePath: String?
    var projectPath: String?
    var createdAt: Date
    var updatedAt: Date
}
```

```swift
enum RoutineState: String, Codable {
    case draft
    case proposed
    case needsApproval
    case enabled
    case running
    case needsReview
    case paused
    case disabled
    case failed
}

struct KishRoutine: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var state: RoutineState
    var source: String
    var triggerDescription: String
    var allowedProjectPaths: [String]
    var outputConversationID: UUID?
    var approvalPolicy: String
    var createdAt: Date
    var updatedAt: Date
}
```

### Backend

The Mac mini `kish-agent` should expose native endpoints over `kish-context` and any successor routine store:

- `GET /memory`
- `POST /memory`
- `PATCH /memory/:id`
- `DELETE /memory/:id` or `PATCH state=forgotten`
- `POST /briefs/daily`
- `GET /routines`
- `POST /routines/draft`
- `PATCH /routines/:id`
- `POST /routines/:id/run`
- `GET /routine-runs`
- `GET /context-sources`
- `POST /reflection/run`
- `GET /routine-proposals`
- `PATCH /routine-proposals/:id`

Backend requirements:

- Persist memory and routines in a stable store.
- Bridge to `kish-context` scripts where possible: reflector payload, proposal queue, memory apply, daily routine, and review queue.
- Include provenance and idempotency keys.
- Return output conversation ids for routine runs.
- Expose pending approvals/questions in the same model the app already understands where possible.
- Do not let routine execution bypass approval policy.

### Context Contract

Brief/routine generation may receive:

- Active conversations.
- Recent conversation summaries.
- Pending questions/approvals.
- Active and pinned memories.
- Sensitive/conflicted memory proposals only when relevant and marked unapproved.
- Recent routine results.
- Project context.
- Approved context sources such as `kish-context`, ScreenContext summaries, and relevant repo metadata.

It must not receive:

- Forgotten memory.
- Archived memory unless explicitly requested.
- Broad filesystem context outside approved project/routine scope.
- Untrusted recalled context as instructions.

### Storage and Privacy

Principles:

- Proactive memory must be visible.
- Forget means future context excludes it.
- Every routine has visible scope.
- Routine runs are auditable.
- Private content should not be spoken or notified verbosely unless Kish opts in.
- Read-only learning is broadly allowed.
- Externally visible, destructive, irreversible, or long-running implementation actions are gated.

## Phased Worktree Plan

### Phase 1: Backend Bridge and Inventory

- Inventory `kish-context` memory, proposal, routine, and brief artifacts.
- Define native API contract.
- Add or stub endpoints in `kish-agent`.
- Add tests around response shape and permission/approval policy.

Exit criteria:

- Native app can load memory/proposals/routines from backend or a stable mock.

### Phase 2: Native Memory UI

- Add shared memory models/store.
- Add native memory list/detail surface.
- Support proactive observed memories plus pin/edit/forget.
- Add source/provenance display.

Exit criteria:

- KishOS can show existing/proactive memory and Kish can pin/edit/forget it.

### Phase 3: Daily Brief On Demand

- Add brief generation endpoint/client flow.
- Pull active conversations, pending decisions, recent outcomes, routine results, and memory.
- Render brief in normal conversation or brief thread.
- Add source links.

Exit criteria:

- Kish can ask "brief me" and get useful current state without legacy dashboard dependency.

### Phase 4: Routines Page and Approval

- Add routine draft/proposal models.
- Add routines page.
- Add approve/pause/disable/run now/edit.
- Add routine run records.
- Support one user-created and one agent-proposed routine.

Exit criteria:

- One user-created routine and one agent-proposed routine can be approved, run, and report back.

### Phase 5: Always-On Reflection

- Add reflection run endpoint/control.
- Feed chats, context summaries, memory changes, rejected/corrected outputs, and routine outcomes.
- Produce memory updates, proposed routines, lessons, and spec ideas.
- Surface results in memory/routines pages.

Exit criteria:

- Reflection can identify a useful proposed routine or explain that nothing new was found.

### Phase 6: Self-Improvement Queue

- Capture app ideas as memory/queue items.
- Draft specs automatically when safe.
- Suggest worktree names and verification.
- Gate long coding work behind approval.

Exit criteria:

- KishOS can turn an idea into a spec and approved work item without auto-merging code or starting long implementation without approval.

## Success Metrics

Leading:

- KishOS can ingest and surface useful observed memories without blocking Kish.
- Kish can pin/edit/forget a memory in under 30 seconds.
- Daily brief completes in under 20 seconds for current local context.
- First user-created routine can be drafted, approved, run, and paused.
- First agent-proposed routine can be approved or rejected from routines page.
- No new routine becomes enabled without approval.
- No long coding, email/Slack send, delete, or irreversible action starts without approval.
- No forgotten memory appears in brief generation tests.

Lagging:

- Daily brief becomes useful enough to run most workdays.
- More app ideas become specs/work items instead of disappearing in chat history.
- Fewer "what were we doing?" recovery moments across worktrees.
- Routine nudges increase completed reviews without notification fatigue.
- KishOS proposes routines that Kish actually approves.

## Remaining Open Questions

- Should daily brief run automatically in the morning, only on demand, or both?
- Should routine output create one shared "Daily Brief" conversation or separate routine-specific conversations?
- Should memory live primarily on the Mac mini agent, in the app, or both with sync?
- What does "too proactive" feel like for notifications and nudges?
- Which `kish-context` review console concepts should be native first: memory proposals, routine proposals, daily brief, or lessons?
