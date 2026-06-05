# Memory/Routines Autonomy Contract

Updated: 2026-06-05  
Schema version: `1`  
Backend owner: `kish-agent`  
Native surface: `Autonomy`

This document is the API and data model agreement between the native app and `kish-agent` for the Autonomy MVP. `kish-agent` is canonical for memory, routines, durable policies, routine runs, review cards, tombstones, and scheduling. Native stores are cache-only and must be treated as offline read-only snapshots.

## Locked Decisions

- `kish-agent` is the only backend for this feature.
- Railway relay, dashboard memory files, gateway cron, `MemoryView`, and `CronManagementView` are legacy/reference only.
- Canonical memory, routines, policies, runs, and tombstones live behind `kish-agent`.
- The native surface name is `Autonomy`.
- Autonomy is a small review surface plus background work, not a dashboard.
- Routine enablement uses durable policy records, separate from transient chat approval cards.
- Local/Tailscale operation is trusted by default for V1, but policy records and approval gates still apply for irreversible or external actions.
- No mock-only phase. Build a real basic MVP path first, with fixtures/tests used only for verification.
- Each routine run creates or returns one normal conversation/thread.
- Routine conversations build on prior runs plus shared memory.
- Notification default is digest into daily brief and Autonomy review inbox. Only urgent unblockers produce active notifications.
- ScreenContext is a source only if already enabled outside KishOS. V1 uses summaries only and does not promote ScreenContext observations to durable memory without review.

## HTTP Envelope

All endpoints use HTTP JSON and the `KishAgentClient` envelope style.

Success:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "traceId": "trace_01jz0000000000000000000000",
  "data": {}
}
```

Error:

```json
{
  "ok": false,
  "schemaVersion": 1,
  "traceId": "trace_01jz0000000000000000000000",
  "error": {
    "code": "not_found",
    "message": "Memory was not found.",
    "details": {
      "id": "mem_01jz0000000000000000000000"
    }
  }
}
```

Envelope fields:

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `ok` | boolean | yes | `true` for success, `false` for error. |
| `schemaVersion` | integer | yes | MVP value is `1`. |
| `traceId` | string | yes | Backend-generated trace id for logs and support. |
| `data` | object | success only | Endpoint payload. |
| `error` | object | error only | Error payload. |

Common error codes:

- `bad_request`
- `unauthorized`
- `forbidden_by_policy`
- `needs_approval`
- `not_found`
- `conflict`
- `idempotency_conflict`
- `validation_failed`
- `rate_limited`
- `backend_unavailable`
- `internal_error`

Native offline behavior:

- Native may show the latest cached `data` for read endpoints.
- Native must not mark cached data canonical.
- Native must queue or reject mutations while offline; it must not apply authoritative state transitions locally.

## Exact Enum Values

Memory states:

- `active`
- `pinned`
- `archived`
- `forgotten`

Review flags:

- `needsReview`
- `sensitive`
- `conflicted`

Routine definition states:

- `proposed`
- `enabled`
- `paused`
- `disabled`

Routine run states:

- `queued`
- `running`
- `done`
- `failed`
- `needsReview`
- `needsApproval`

Action classes:

- `readContext`
- `summarize`
- `draftArtifact`
- `createReviewCard`
- `runLightChecks`
- `startCoding`
- `sendExternalMessage`
- `deleteOrDestructive`
- `mergeDeployPublish`

Context sources:

- `conversation`
- `routineRun`
- `memory`
- `projectContext`
- `screenContextSummary`

Output mode:

- `newConversationPerRun`

Notification behavior:

- `dailyBriefDigest`
- `autonomyInbox`
- `urgentActiveNotification`
- `silent`

Routine templates:

- `dailyBrief`
- `ideaGeneration`
- `projectMaintenance`
- `prioritization`

Review card states:

- `open`
- `approved`
- `rejected`
- `resolved`
- `dismissed`

Review card kinds:

- `approveRoutine`
- `resolveMemoryConflict`
- `reviewSensitiveMemory`
- `chooseProjectPriority`
- `approveLongCodingWork`
- `recoverFailedRoutine`
- `reviewIdea`

Recommended actions:

- `approve`
- `reject`
- `resolve`
- `dismiss`
- `openConversation`
- `editMemory`
- `enableRoutine`
- `pauseRoutine`
- `retryRun`

Runtime classes:

- `short`
- `medium`
- `long`

Cost classes:

- `low`
- `medium`
- `high`

Trigger types:

- `manual`
- `scheduled`
- `event`

`ContextSource` is used only by `allowedContextSources` on routines and policies. It is separate from `MemoryProvenance.sourceType`, which identifies audit origin.

## Schemas

Timestamps are ISO 8601 strings. IDs are backend-owned strings.

### AutonomySummary

```json
{
  "latestBrief": null,
  "pendingReviewCount": 2,
  "urgentReviewCount": 1,
  "recentRuns": [],
  "memoryCounts": {
    "active": 12,
    "pinned": 3,
    "archived": 4,
    "forgotten": 9,
    "needsReview": 1,
    "sensitive": 1,
    "conflicted": 0
  },
  "routineCounts": {
    "proposed": 1,
    "enabled": 4,
    "paused": 0,
    "disabled": 0
  },
  "policyIssues": [],
  "updatedAt": "2026-06-05T12:00:00Z"
}
```

Fields:

- `latestBrief`: nullable `DailyBrief`.
- `pendingReviewCount`: number of open review cards.
- `urgentReviewCount`: number of open review cards with urgent notification behavior.
- `recentRuns`: array of `RoutineRun`.
- `memoryCounts`: counts by memory state and review flag.
- `routineCounts`: counts by routine definition state.
- `policyIssues`: array of `PolicyIssue`.
- `updatedAt`: backend snapshot timestamp.

### PolicyIssue

```json
{
  "id": "issue_01jz0000000000000000000000",
  "policyId": "policy_01jz0000000000000000000000",
  "routineId": "routine_01jz0000000000000000000000",
  "severity": "warning",
  "message": "Policy expansion needs durable approval.",
  "reviewCardId": "review_01jz0000000000000000000000"
}
```

`severity` values:

- `info`
- `warning`
- `blocking`

### KishMemory

```json
{
  "id": "mem_01jz0000000000000000000000",
  "state": "active",
  "text": "Kish prefers concise engineering updates.",
  "summary": "Prefers concise engineering updates.",
  "reviewFlags": [],
  "confidence": 0.92,
  "provenance": [],
  "createdAt": "2026-06-05T12:00:00Z",
  "updatedAt": "2026-06-05T12:00:00Z",
  "lastUsedAt": "2026-06-05T12:05:00Z",
  "forgottenAt": null,
  "tombstoneReason": null
}
```

Rules:

- `state` is one of the memory states.
- `reviewFlags` uses exact review flag values.
- Non-sensitive high-confidence memory may become `active`.
- `sensitive` or `conflicted` memory requires review before it is used for action.
- `pinned` memory is active and elevated for context selection.
- `archived` memory is inspectable but excluded from default context unless explicitly requested by a reviewed workflow.
- `forgotten` memory is tombstoned and excluded from future context, daily briefs, and routine inputs.

### MemoryProvenance

```json
{
  "id": "prov_01jz0000000000000000000000",
  "sourceType": "conversation",
  "sourceId": "conv_01jz0000000000000000000000",
  "threadId": "thread_01jz0000000000000000000000",
  "routineRunId": "run_01jz0000000000000000000000",
  "quote": "Keep the update short.",
  "observedAt": "2026-06-05T12:00:00Z",
  "url": null
}
```

`sourceType` values:

- `conversation`
- `routineRun`
- `dailyBrief`
- `projectContext`
- `screenContextSummary`
- `manualEdit`

Provenance is retained for audit after forgetting unless the source explicitly cannot support retention. Forgotten memory text must not be reintroduced from retained provenance.

### KishRoutine

```json
{
  "id": "routine_01jz0000000000000000000000",
  "name": "Daily brief",
  "template": "dailyBrief",
  "state": "enabled",
  "policyId": "policy_01jz0000000000000000000000",
  "trigger": {
    "type": "scheduled",
    "schedule": "0 8 * * *",
    "timezone": "America/Los_Angeles",
    "eventName": null
  },
  "allowedContextSources": ["conversation", "routineRun", "memory", "projectContext"],
  "allowedProjectPaths": ["/Users/kishparikh/conductor/workspaces/clawk-ios/manila"],
  "allowedActionClasses": ["readContext", "summarize", "draftArtifact", "createReviewCard"],
  "outputMode": "newConversationPerRun",
  "createdAt": "2026-06-05T12:00:00Z",
  "updatedAt": "2026-06-05T12:00:00Z"
}
```

State transitions:

- `proposed` -> `enabled` requires durable policy approval.
- `enabled` -> `paused`, `disabled`.
- `paused` -> `enabled`, `disabled`.
- `disabled` -> `proposed` or `enabled` only via backend mutation and durable policy validation.

### RoutinePolicy

```json
{
  "id": "policy_01jz0000000000000000000000",
  "routineId": "routine_01jz0000000000000000000000",
  "allowedActions": ["readContext", "summarize", "draftArtifact", "createReviewCard", "runLightChecks"],
  "blockedActions": ["startCoding", "sendExternalMessage", "deleteOrDestructive", "mergeDeployPublish"],
  "allowedContextSources": ["conversation", "routineRun", "memory", "projectContext"],
  "allowedProjectPaths": ["/Users/kishparikh/conductor/workspaces/clawk-ios/manila"],
  "maxRuntimeClass": "short",
  "maxCostClass": "low",
  "notificationBehavior": "dailyBriefDigest",
  "createdAt": "2026-06-05T12:00:00Z",
  "approvedAt": "2026-06-05T12:00:00Z",
  "updatedAt": "2026-06-05T12:00:00Z"
}
```

Durable policy gating and approval flow:

- Enabled routines may do `readContext`, `summarize`, `draftArtifact`, `createReviewCard`, and bounded `runLightChecks` only if allowed by the routine policy.
- `startCoding`, `sendExternalMessage`, `deleteOrDestructive`, and `mergeDeployPublish` require explicit review/approval and must not be enabled by transient chat approval alone.
- Transient chat `ApprovalRequest` cards authorize only the current chat/run action. They do not modify `RoutinePolicy`.
- Durable policy changes happen only through `PATCH /policies/:id` and are recorded on the policy.
- `approvedAt` is server-owned. Clients never send it directly.
- Creating a routine or expanding policy scope returns `ok: true` with the proposed routine/policy plus an open `approveRoutine` review card when durable approval is needed.
- Approving that review card is the durable approval action. Backend then updates `RoutinePolicy.approvedAt` and enables or updates the related routine/policy if validation still passes.
- Rejecting or dismissing that review card leaves the routine/policy unapproved and does not grant future authority.
- Transient chat approvals must not approve or expand durable policy.

### RoutineDefinitionTrigger

```json
{
  "type": "scheduled",
  "schedule": "0 8 * * *",
  "timezone": "America/Los_Angeles",
  "eventName": null
}
```

Rules:

- `type` is `manual`, `scheduled`, or `event`.
- `KishRoutine.trigger` uses `RoutineDefinitionTrigger`.
- Definition triggers describe when a routine should be available or scheduled. They do not include run instance fields.
- Manual definition triggers use `{ "type": "manual", "schedule": null, "timezone": null, "eventName": null }`.
- Scheduled definition triggers include `schedule` and `timezone`.
- Event definition triggers include `eventName`.
- `scheduledFor` and `manualRunId` are never present on definition triggers.

### RoutineRunTrigger

```json
{
  "type": "manual",
  "manualRunId": "manual_01jz0000000000000000000000",
  "scheduledFor": null,
  "eventName": null
}
```

Rules:

- Run endpoints use `RoutineRunTrigger`.
- Manual run triggers include `manualRunId`.
- Scheduled run triggers include `scheduledFor`; backend computes their idempotency key.
- Event run triggers include `eventName` and an event-derived run id in the idempotency key.
- Run triggers do not include `schedule` or `timezone`.

### RoutineRun

```json
{
  "id": "run_01jz0000000000000000000000",
  "routineId": "routine_01jz0000000000000000000000",
  "idempotencyKey": "routine:routine_01jz0000000000000000000000:manual:manual_01jz0000000000000000000000",
  "status": "done",
  "conversationId": "conv_01jz0000000000000000000000",
  "threadId": "thread_01jz0000000000000000000000",
  "startedAt": "2026-06-05T12:00:00Z",
  "finishedAt": "2026-06-05T12:02:00Z",
  "priorRunIdsUsed": ["run_01jy0000000000000000000000"],
  "error": null,
  "retryOfRunId": null,
  "reviewCardIdsCreated": ["review_01jz0000000000000000000000"],
  "createdAt": "2026-06-05T12:00:00Z",
  "updatedAt": "2026-06-05T12:02:00Z"
}
```

Rules:

- `conversationId` and `threadId` identify the normal conversation containing routine output.
- Every run creates or returns exactly one conversation/thread.
- `needsReview` means the run completed enough to require user input.
- `needsApproval` means the run is blocked before an action by policy or per-run approval.
- Duplicate run keys return the same `RoutineRun`, `conversationId`, and `threadId`.

### RoutineRunError

```json
{
  "code": "forbidden_by_policy",
  "message": "Routine needs approval before starting long coding work.",
  "details": {
    "actionClass": "startCoding"
  },
  "retryable": false
}
```

### ReviewCard

```json
{
  "id": "review_01jz0000000000000000000000",
  "kind": "reviewSensitiveMemory",
  "state": "open",
  "title": "Review sensitive memory",
  "body": "A routine found a possible sensitive preference.",
  "routineId": "routine_01jz0000000000000000000000",
  "routineRunId": "run_01jz0000000000000000000000",
  "memoryId": "mem_01jz0000000000000000000000",
  "policyId": null,
  "conversationId": "conv_01jz0000000000000000000000",
  "threadId": "thread_01jz0000000000000000000000",
  "reviewFlags": ["sensitive"],
  "recommendedAction": "approve",
  "notificationBehavior": "autonomyInbox",
  "createdAt": "2026-06-05T12:00:00Z",
  "updatedAt": "2026-06-05T12:00:00Z",
  "resolvedAt": null
}
```

Review state transitions:

- `open` -> `approved`, `rejected`, `resolved`, or `dismissed`.
- Closed states do not reopen. Backend creates a new card if later work needs new input.

Decision-to-state mapping:

- `approve` and `enableRoutine` usually close the card as `approved`.
- `reject` closes the card as `rejected`.
- `resolve`, `editMemory`, `pauseRoutine`, and `retryRun` close the card as `resolved` after the related mutation succeeds.
- `dismiss` closes the card as `dismissed`.
- `openConversation` is navigation-only and does not change card state.

Review decision semantics:

| Review kind | Valid decisions | Backend behavior |
| --- | --- | --- |
| `reviewSensitiveMemory` | `approve`, `reject`, `editMemory`, `dismiss`, `openConversation` | `approve` clears the blocking sensitive review for use; `reject` archives or forgets according to backend safety rules; `editMemory` updates the memory then re-evaluates flags; `dismiss` closes without use; `openConversation` is navigation only. |
| `resolveMemoryConflict` | `resolve`, `reject`, `editMemory`, `dismiss`, `openConversation` | `resolve` applies the selected memory resolution; `reject` rejects the proposed memory; `editMemory` stores corrected text; `dismiss` closes without promoting conflicted memory. |
| `approveRoutine` | `enableRoutine`, `pauseRoutine`, `reject`, `dismiss`, `openConversation` | `enableRoutine` durably approves the related policy and enables/updates the routine; `pauseRoutine` keeps or moves the routine to `paused` without granting new authority; `reject` keeps the routine proposed/disabled; `dismiss` closes without approval. |
| `approveLongCodingWork` | `approve`, `reject`, `dismiss`, `openConversation` | `approve` authorizes only the current run/action unless represented by an `approveRoutine` durable policy card; it does not expand durable policy. |
| `recoverFailedRoutine` | `retryRun`, `dismiss`, `openConversation` | `retryRun` starts a new run with a new idempotency key and links `retryOfRunId`; `dismiss` closes the recovery prompt. |
| `chooseProjectPriority` | `resolve`, `dismiss`, `openConversation` | `resolve` records the chosen priority and closes the card; `dismiss` leaves priority unchanged. |
| `reviewIdea` | `approve`, `reject`, `dismiss`, `openConversation` | `approve` may create a follow-up artifact/card allowed by policy; `reject` records negative feedback; `dismiss` closes without feedback. |

### DailyBrief

```json
{
  "id": "brief_01jz0000000000000000000000",
  "routineRunId": "run_01jz0000000000000000000000",
  "conversationId": "conv_01jz0000000000000000000000",
  "threadId": "thread_01jz0000000000000000000000",
  "previousBriefRunId": "run_01jy0000000000000000000000",
  "summary": "Two items need review. Project maintenance found one stale failed run.",
  "sections": [
    {
      "title": "Needs input",
      "items": ["Approve or reject one sensitive memory."]
    }
  ],
  "reviewCardIds": ["review_01jz0000000000000000000000"],
  "createdAt": "2026-06-05T12:02:00Z"
}
```

Daily brief inputs:

- active conversations
- prior daily brief run
- recent routine runs
- active/pinned memory
- pending durable policy/review cards
- project/worktree status

Daily brief exclusions:

- `forgotten` memory and tombstoned content
- `archived` memory unless explicitly selected by a reviewed workflow
- sensitive/conflicted memory that has not been reviewed for use

## Required Fields And Nullability

Native models should decode all listed fields. Nullable fields are present with `null` when unavailable unless an endpoint explicitly documents an omitted request field.

### AutonomySummary Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `latestBrief` | `DailyBrief` | yes | yes |
| `pendingReviewCount` | integer | yes | no |
| `urgentReviewCount` | integer | yes | no |
| `recentRuns` | `[RoutineRun]` | yes | no |
| `memoryCounts` | object | yes | no |
| `routineCounts` | object | yes | no |
| `policyIssues` | `[PolicyIssue]` | yes | no |
| `updatedAt` | string | yes | no |

### PolicyIssue Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `policyId` | string | yes | yes |
| `routineId` | string | yes | yes |
| `severity` | string | yes | no |
| `message` | string | yes | no |
| `reviewCardId` | string | yes | yes |

### KishMemory Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `state` | memory state | yes | no |
| `text` | string | yes | no |
| `summary` | string | yes | yes |
| `reviewFlags` | `[review flag]` | yes | no |
| `confidence` | number | yes | no |
| `provenance` | `[MemoryProvenance]` | yes | no |
| `createdAt` | string | yes | no |
| `updatedAt` | string | yes | no |
| `lastUsedAt` | string | yes | yes |
| `forgottenAt` | string | yes | yes |
| `tombstoneReason` | string | yes | yes |

### MemoryProvenance Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `sourceType` | provenance source type | yes | no |
| `sourceId` | string | yes | yes |
| `threadId` | string | yes | yes |
| `routineRunId` | string | yes | yes |
| `quote` | string | yes | yes |
| `observedAt` | string | yes | no |
| `url` | string | yes | yes |

### KishRoutine Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `name` | string | yes | no |
| `template` | routine template | yes | no |
| `state` | routine definition state | yes | no |
| `policyId` | string | yes | yes |
| `trigger` | `RoutineDefinitionTrigger` | yes | no |
| `allowedContextSources` | `[ContextSource]` | yes | no |
| `allowedProjectPaths` | `[string]` | yes | no |
| `allowedActionClasses` | `[action class]` | yes | no |
| `outputMode` | output mode | yes | no |
| `createdAt` | string | yes | no |
| `updatedAt` | string | yes | no |

### RoutinePolicy Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `routineId` | string | yes | no |
| `allowedActions` | `[action class]` | yes | no |
| `blockedActions` | `[action class]` | yes | no |
| `allowedContextSources` | `[ContextSource]` | yes | no |
| `allowedProjectPaths` | `[string]` | yes | no |
| `maxRuntimeClass` | runtime class | yes | no |
| `maxCostClass` | cost class | yes | no |
| `notificationBehavior` | notification behavior | yes | no |
| `createdAt` | string | yes | no |
| `approvedAt` | string | yes | yes |
| `updatedAt` | string | yes | no |

### RoutineDefinitionTrigger Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `type` | trigger type | yes | no |
| `schedule` | string | yes | yes |
| `timezone` | string | yes | yes |
| `eventName` | string | yes | yes |

### RoutineRunTrigger Request Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `type` | trigger type | yes | no |
| `manualRunId` | string | for manual runs | no |
| `scheduledFor` | string | for scheduled runs | no |
| `eventName` | string | for event runs | no |

### RoutineRun Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `routineId` | string | yes | no |
| `idempotencyKey` | string | yes | no |
| `status` | routine run state | yes | no |
| `conversationId` | string | yes | yes |
| `threadId` | string | yes | yes |
| `startedAt` | string | yes | yes |
| `finishedAt` | string | yes | yes |
| `priorRunIdsUsed` | `[string]` | yes | no |
| `error` | `RoutineRunError` | yes | yes |
| `retryOfRunId` | string | yes | yes |
| `reviewCardIdsCreated` | `[string]` | yes | no |
| `createdAt` | string | yes | no |
| `updatedAt` | string | yes | no |

`RoutineRun.conversationId` and `threadId` are nullable only while a queued run has not yet created its conversation. `startedAt` is nullable until the run starts. `finishedAt` is nullable until the run reaches `done`, `failed`, `needsReview`, or `needsApproval`.

### RoutineRunError Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `code` | string | yes | no |
| `message` | string | yes | no |
| `details` | object | yes | yes |
| `retryable` | boolean | yes | no |

### ReviewCard Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `kind` | review card kind | yes | no |
| `state` | review card state | yes | no |
| `title` | string | yes | no |
| `body` | string | yes | no |
| `routineId` | string | yes | yes |
| `routineRunId` | string | yes | yes |
| `memoryId` | string | yes | yes |
| `policyId` | string | yes | yes |
| `conversationId` | string | yes | yes |
| `threadId` | string | yes | yes |
| `reviewFlags` | `[review flag]` | yes | no |
| `recommendedAction` | recommended action | yes | no |
| `notificationBehavior` | notification behavior | yes | no |
| `createdAt` | string | yes | no |
| `updatedAt` | string | yes | no |
| `resolvedAt` | string | yes | yes |

### DailyBrief Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `id` | string | yes | no |
| `routineRunId` | string | yes | no |
| `conversationId` | string | yes | no |
| `threadId` | string | yes | no |
| `previousBriefRunId` | string | yes | yes |
| `summary` | string | yes | no |
| `sections` | `[DailyBriefSection]` | yes | no |
| `reviewCardIds` | `[string]` | yes | no |
| `createdAt` | string | yes | no |

### DailyBriefSection Fields

| Field | Type | Required | Nullable |
| --- | --- | --- | --- |
| `title` | string | yes | no |
| `items` | `[string]` | yes | no |

## Endpoints

All mutating or run endpoints return the updated entity, created review cards if any, related conversation/thread ids if any, and the envelope `traceId`.

### `GET /autonomy/summary`

Returns:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "traceId": "trace_01jzsummary",
  "data": {
    "summary": {
      "latestBrief": {
        "id": "brief_01jzbrief",
        "routineRunId": "run_01jzbrief",
        "conversationId": "conv_01jzbrief",
        "threadId": "thread_01jzbrief",
        "previousBriefRunId": "run_01jyprevbrief",
        "summary": "One review item needs input. Daily brief is otherwise current.",
        "sections": [
          {
            "title": "Needs input",
            "items": ["Review one sensitive memory."]
          }
        ],
        "reviewCardIds": ["review_01jzsensitive"],
        "createdAt": "2026-06-05T15:00:00Z"
      },
      "pendingReviewCount": 1,
      "urgentReviewCount": 0,
      "recentRuns": [],
      "memoryCounts": {
        "active": 18,
        "pinned": 4,
        "archived": 6,
        "forgotten": 2,
        "needsReview": 1,
        "sensitive": 1,
        "conflicted": 0
      },
      "routineCounts": {
        "proposed": 0,
        "enabled": 4,
        "paused": 0,
        "disabled": 0
      },
      "policyIssues": [],
      "updatedAt": "2026-06-05T15:00:00Z"
    }
  }
}
```

### `GET /memory`

Query parameters:

- `state`: optional memory state.
- `reviewFlag`: optional review flag.
- `includeForgotten`: optional boolean, default `false`.
- `limit`: optional integer.
- `cursor`: optional string.

Returns:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "traceId": "trace_01jzmemory",
  "data": {
    "memory": [
      {
        "id": "mem_01jzconcise",
        "state": "pinned",
        "text": "Kish prefers concise engineering updates.",
        "summary": "Prefers concise engineering updates.",
        "reviewFlags": [],
        "confidence": 0.96,
        "provenance": [
          {
            "id": "prov_01jzconcise",
            "sourceType": "conversation",
            "sourceId": "conv_01jzsource",
            "threadId": "thread_01jzsource",
            "routineRunId": null,
            "quote": "Keep it concise.",
            "observedAt": "2026-06-04T19:00:00Z",
            "url": null
          }
        ],
        "createdAt": "2026-06-04T19:00:00Z",
        "updatedAt": "2026-06-05T15:00:00Z",
        "lastUsedAt": "2026-06-05T15:00:00Z",
        "forgottenAt": null,
        "tombstoneReason": null
      }
    ],
    "nextCursor": null
  }
}
```

### `PATCH /memory/:id`

Request body:

```json
{
  "state": "pinned",
  "text": "Kish prefers concise engineering updates.",
  "reviewFlags": []
}
```

Allowed native actions:

- pin: set `state` to `pinned`.
- edit: update `text` and/or `summary`; backend refreshes provenance/edit metadata.
- archive: set `state` to `archived`.
- clear review: remove resolved `reviewFlags` when backend validation allows it.

Returns `{ "memory": KishMemory, "reviewCards": [] }`.

### `POST /memory/:id/forget`

Request body:

```json
{
  "reason": "User requested forgetting this memory."
}
```

Behavior:

- Sets `state` to `forgotten`.
- Sets `forgottenAt` and `tombstoneReason`.
- Writes or updates a backend tombstone for the memory id and source ids.
- Excludes the memory from future context, daily briefs, and routine inputs.
- Prevents future routines/reflection from recreating the same memory from retained provenance.
- Retains provenance for audit unless explicitly unsupported by the source.

Returns `{ "memory": KishMemory, "reviewCards": [] }`.

### `POST /briefs/daily`

Request body:

```json
{
  "idempotencyKey": "routine:routine_dailyBrief:manual:manual_01jzbrief",
  "trigger": {
    "type": "manual",
    "manualRunId": "manual_01jzbrief",
    "scheduledFor": null,
    "eventName": null
  }
}
```

Returns a `DailyBrief`, `RoutineRun`, created review cards, and related conversation/thread ids:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "traceId": "trace_01jzdaily",
  "data": {
    "brief": {
      "id": "brief_01jzbrief",
      "routineRunId": "run_01jzbrief",
      "conversationId": "conv_01jzbrief",
      "threadId": "thread_01jzbrief",
      "previousBriefRunId": "run_01jyprevbrief",
      "summary": "Project maintenance found one stale failed run. One sensitive memory needs review.",
      "sections": [
        {
          "title": "Changed",
          "items": ["A project maintenance routine completed."]
        },
        {
          "title": "Needs input",
          "items": ["Review one sensitive memory before it can be used for actions."]
        }
      ],
      "reviewCardIds": ["review_01jzsensitive"],
      "createdAt": "2026-06-05T15:00:00Z"
    },
    "run": {
      "id": "run_01jzbrief",
      "routineId": "routine_dailyBrief",
      "idempotencyKey": "routine:routine_dailyBrief:manual:manual_01jzbrief",
      "status": "needsReview",
      "conversationId": "conv_01jzbrief",
      "threadId": "thread_01jzbrief",
      "startedAt": "2026-06-05T14:59:00Z",
      "finishedAt": "2026-06-05T15:00:00Z",
      "priorRunIdsUsed": ["run_01jyprevbrief"],
      "error": null,
      "retryOfRunId": null,
      "reviewCardIdsCreated": ["review_01jzsensitive"],
      "createdAt": "2026-06-05T14:59:00Z",
      "updatedAt": "2026-06-05T15:00:00Z"
    },
    "reviewCards": [
      {
        "id": "review_01jzsensitive",
        "kind": "reviewSensitiveMemory",
        "state": "open",
        "title": "Review sensitive memory",
        "body": "A routine found a possible sensitive memory that needs approval before use.",
        "routineId": "routine_dailyBrief",
        "routineRunId": "run_01jzbrief",
        "memoryId": "mem_01jzsensitive",
        "policyId": null,
        "conversationId": "conv_01jzbrief",
        "threadId": "thread_01jzbrief",
        "reviewFlags": ["sensitive"],
        "recommendedAction": "approve",
        "notificationBehavior": "autonomyInbox",
        "createdAt": "2026-06-05T15:00:00Z",
        "updatedAt": "2026-06-05T15:00:00Z",
        "resolvedAt": null
      }
    ],
    "conversationId": "conv_01jzbrief",
    "threadId": "thread_01jzbrief"
  }
}
```

### `GET /routines`

Query parameters:

- `state`: optional routine definition state.
- `template`: optional routine template.

Returns `{ "routines": [KishRoutine] }`.

### `POST /routines`

Request body:

```json
{
  "name": "Prioritization",
  "template": "prioritization",
  "trigger": {
    "type": "manual",
    "schedule": null,
    "timezone": null,
    "eventName": null
  },
  "allowedContextSources": ["conversation", "routineRun", "memory", "projectContext"],
  "allowedProjectPaths": ["/Users/kishparikh/conductor/workspaces/clawk-ios/manila"],
  "allowedActionClasses": ["readContext", "summarize", "draftArtifact", "createReviewCard"]
}
```

Behavior:

- Backend creates a routine definition in `proposed` unless an existing durable policy already authorizes it.
- Backend creates or links a `RoutinePolicy`.
- If durable approval is needed, backend still returns `ok: true` with the proposed routine/policy and an open `approveRoutine` review card.

Returns `{ "routine": KishRoutine, "policy": RoutinePolicy, "reviewCards": [ReviewCard] }`.

### `PATCH /routines/:id`

Request body may update:

- `name`
- `state`
- `trigger`
- `allowedContextSources`
- `allowedProjectPaths`
- `allowedActionClasses`

Behavior:

- Enabling requires a durable policy that allows the requested actions/context.
- Requests outside policy return `ok: true` with the unchanged/proposed entity plus an open `approveRoutine` review card when durable approval can resolve the gap.
- Requests that cannot be represented as approvable policy changes return `forbidden_by_policy`.

Returns `{ "routine": KishRoutine, "policy": RoutinePolicy, "reviewCards": [ReviewCard] }`.

### `POST /routines/:id/run`

Request body:

```json
{
  "idempotencyKey": "routine:routine_01jzpriority:manual:manual_01jzpriority",
  "trigger": {
    "type": "manual",
    "manualRunId": "manual_01jzpriority",
    "scheduledFor": null,
    "eventName": null
  }
}
```

Duplicate run response example:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "traceId": "trace_01jzdupe",
  "data": {
    "run": {
      "id": "run_01jzpriority",
      "routineId": "routine_01jzpriority",
      "idempotencyKey": "routine:routine_01jzpriority:manual:manual_01jzpriority",
      "status": "done",
      "conversationId": "conv_01jzpriority",
      "threadId": "thread_01jzpriority",
      "startedAt": "2026-06-05T15:10:00Z",
      "finishedAt": "2026-06-05T15:11:00Z",
      "priorRunIdsUsed": ["run_01jyprevious"],
      "error": null,
      "retryOfRunId": null,
      "reviewCardIdsCreated": [],
      "createdAt": "2026-06-05T15:10:00Z",
      "updatedAt": "2026-06-05T15:11:00Z"
    },
    "reviewCards": [],
    "conversationId": "conv_01jzpriority",
    "threadId": "thread_01jzpriority",
    "duplicate": true
  }
}
```

### `GET /routine-runs`

Query parameters:

- `routineId`: optional routine id.
- `status`: optional routine run state.
- `limit`: optional integer.
- `cursor`: optional string.

Returns `{ "runs": [RoutineRun], "nextCursor": string | null }`.

### `GET /review-cards`

Query parameters:

- `state`: optional review card state, default `open`.
- `kind`: optional review card kind.
- `routineId`: optional routine id.
- `limit`: optional integer.
- `cursor`: optional string.

Returns:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "traceId": "trace_01jzreview",
  "data": {
    "reviewCards": [
      {
        "id": "review_01jzsensitive",
        "kind": "reviewSensitiveMemory",
        "state": "open",
        "title": "Review sensitive memory",
        "body": "A routine found a possible sensitive memory that needs approval before use.",
        "routineId": "routine_dailyBrief",
        "routineRunId": "run_01jzbrief",
        "memoryId": "mem_01jzsensitive",
        "policyId": null,
        "conversationId": "conv_01jzbrief",
        "threadId": "thread_01jzbrief",
        "reviewFlags": ["sensitive"],
        "recommendedAction": "approve",
        "notificationBehavior": "autonomyInbox",
        "createdAt": "2026-06-05T15:00:00Z",
        "updatedAt": "2026-06-05T15:00:00Z",
        "resolvedAt": null
      }
    ],
    "nextCursor": null
  }
}
```

### `PATCH /review-cards/:id`

Request body:

```json
{
  "decision": "approve",
  "note": "Looks correct.",
  "memoryPatch": null,
  "routinePatch": null
}
```

Behavior:

- Review card state change may update related memory, routine, run, or policy state.
- `decision` must be valid for the card kind according to the review decision table.
- Backend derives the resulting review card `state`; clients do not directly set closed states.
- Approving a transient action does not update durable policy.
- `enableRoutine` on an `approveRoutine` card is the durable approval path and may update the related policy `approvedAt` and routine state.

Returns `{ "reviewCard": ReviewCard, "relatedMemory": KishMemory | null, "relatedRoutine": KishRoutine | null, "relatedPolicy": RoutinePolicy | null }`.

### `GET /policies`

Query parameters:

- `routineId`: optional routine id.

Returns `{ "policies": [RoutinePolicy] }`.

### `PATCH /policies/:id`

Request body may update:

- `allowedActions`
- `blockedActions`
- `allowedContextSources`
- `allowedProjectPaths`
- `maxRuntimeClass`
- `maxCostClass`
- `notificationBehavior`

Behavior:

- Backend validates that blocked actions override allowed actions.
- Expanding policy scope returns `ok: true` with the updated proposed policy and an open `approveRoutine` review card when durable approval is needed.
- `approvedAt` is server-owned and changes only when the related durable approval review card is approved.
- Policy changes are durable and affect later routine runs.

Returns `{ "policy": RoutinePolicy, "reviewCards": [ReviewCard] }`.

### `POST /reflection/run`

Request body:

```json
{
  "idempotencyKey": "reflection:global:2026-06-05",
  "scope": "global"
}
```

Behavior:

- Runs memory/routine reflection for the requested scope.
- May create observed memory, proposed routines, and review cards.
- Must respect tombstones and durable policies.

Returns `{ "run": RoutineRun | null, "memory": [KishMemory], "routines": [KishRoutine], "reviewCards": [ReviewCard] }`.

## Idempotency

Every routine run and reflection run has an idempotency key.

Exact key formats:

```text
routine:{routineId}:{triggerType}:{scheduledForOrManualRunId}
reflection:{scope}:{dateOrManualRunId}
```

Rules:

- Client sends `idempotencyKey` for manual routine and reflection runs.
- Backend computes `idempotencyKey` for scheduled runs.
- `triggerType` is the `RoutineRunTrigger.type` value.
- `scheduledForOrManualRunId` is an ISO date such as `2026-06-05` for scheduled runs, or a client-generated manual id such as `manual_01jz...` for manual runs.
- Retrying the same key returns the existing run.
- Duplicate retries must not create duplicate conversations.
- Reusing a key with a different routine id, trigger type, scope, or request body returns `idempotency_conflict`.

## Output To Conversation

- Every routine run creates or returns one normal conversation/thread.
- The run record stores both `conversationId` and `threadId`.
- The conversation contains the routine output and any contextual links to prior run conversations.
- Routine conversations build on prior runs plus shared memory selected by backend policy.
- Duplicate run keys return the same `RoutineRun`, `conversationId`, and `threadId`.
- Low-confidence ideas stay in the routine conversation only.
- High-confidence items that need Kish appear as review cards and may also be linked from the conversation.

## Template Behavior

`dailyBrief`:

- Generates a daily brief on demand and schedule.
- Creates a conversation.
- Includes review card summaries inline, with approval state owned by backend.

`ideaGeneration`:

- Reads recent chats, ideas, rejected/corrected outputs, and project context.
- May draft specs and suggestions.
- Must not start coding, create worktrees, send messages, delete, merge, deploy, or publish without review.

`projectMaintenance`:

- May inspect git status/branch summary, recent conversations, open review items, stale failed runs, test command availability, and TODO/spec discovery.
- Requires approval before modifying files, creating branches/worktrees, running long implementation jobs, deleting/renaming, merging, or deploying.

`prioritization`:

- Recommends next work across active conversations, routine history, project state, memory/preferences, and pending approvals/questions.
- Adds review cards only for decisions that block progress.

## Backend/Native Implementation Checklist

Backend:

- Implement all endpoints with the envelope above.
- Own canonical ids, state transitions, policies, tombstones, run registry, and scheduling.
- Enforce idempotency and conversation reuse for duplicate run keys.
- Exclude forgotten memory from context, briefs, and routine inputs.
- Enforce durable policies separately from transient chat approvals.
- Seed V1 routine templates: `dailyBrief`, `ideaGeneration`, `projectMaintenance`, `prioritization`.

Native:

- Decode all schemas as `Codable`/`Equatable` models.
- Cache read endpoint responses for offline read-only display.
- Submit all mutations to backend and trust only envelope responses as canonical.
- Show Review as the default Autonomy section when open review cards exist; otherwise show latest Brief.
- Do not use legacy file-memory or cron-job language in Autonomy.
- Route routine run output to the returned conversation/thread.
