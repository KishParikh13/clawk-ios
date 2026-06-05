# Glasses and Voice Hands-Free Spec

Last updated: 2026-06-04

Suggested worktree: `glasses-voice-hands-free`

First hardware target: Meta Ray-Ban Gen 2 glasses.

## Problem Statement

KishOS already supports native chat, dictation, live call mode, spoken replies, wake phrase support, audio route awareness, Live Activity, and status notifications. The missing product layer is a reliable hands-free interface: Kish should be able to put on Meta Ray-Ban Gen 2 glasses and start a live voice session with KishOS at any time, without babysitting the phone.

V1 should use the glasses as normal Bluetooth call audio. Later phases should add explicit photo and video capture from what Kish is looking at, with review before anything is sent.

## Product Thesis

KishOS is a many-chat command center right now. Hands-free mode should extend that command center into moments where typing is awkward. It should let Kish start, steer, interrupt, and rejoin agent work by voice while preserving the full transcript, project context, decisions, and run history in the normal chat surface.

This is not a settings feature. The product is "I am wearing glasses and can talk to KishOS now."

## Live Call vs Walk Mode

Live call is the engine:

- Owns the active voice conversation.
- Listens, finalizes spoken turns, sends chat turns, streams agent replies, and optionally speaks final replies.
- Writes normal conversation transcript.
- Handles mute, interruption, questions, retries, project context, and backend runs.

Walk mode is the glasses-first control layer:

- A focused way to start and control live call when Kish is moving, not looking at the phone, or using glasses.
- Optimized for one primary control, route truth, short status, and recovery.
- Uses live call underneath. It should not create a separate conversation model.

Practical implementation rule:

- Build live call as the durable capability.
- Build walk mode as the no-look/glasses UI and activation experience on top of live call.

## Current Baseline

Live or implemented in some form:

- `AudioRouteMonitor` in `Clawk/KishOSCore/AudioRouteMonitor.swift`.
- Route kind model for system, built-in, Bluetooth, glasses, headset, and unknown routes.
- Prefer external route setting persisted in `UserDefaults`.
- iOS and Mac audio route surfaces.
- `VoiceController` for speech-to-composer dictation.
- `WakePhraseController` on iOS.
- `LiveCallController` and `LiveCallView`.
- Spoken replies in live call mode through `AVSpeechSynthesizer`.
- Live Activity and local status notifications.
- Snapshot review and native image attachment transport.
- Prior glasses work in `/Users/kishparikh/Code/meta-rayban-ai/glassbridge`.

Useful `glassbridge` references:

- `/Users/kishparikh/Code/meta-rayban-ai/glassbridge/README.md`
- `/Users/kishparikh/Code/meta-rayban-ai/glassbridge/ios/README.md`
- `/Users/kishparikh/Code/meta-rayban-ai/glassbridge/docs/ARCHITECTURE_V2.md`
- `/Users/kishparikh/Code/meta-rayban-ai/glassbridge/docs/LEARNINGS.md`
- `/Users/kishparikh/Code/meta-rayban-ai/glassbridge/docs/USE_CASES.md`

Known gaps:

- Glasses walk mode is marked in progress, but it is not yet a complete product mode.
- Route truth exists, but Meta Ray-Ban Gen 2 hardware QA and route recovery need a deliberate pass.
- Live call mode works, but it needs a glasses-first activation path, concise voice behavior, interruption, and route-loss recovery.
- Wake phrase behavior exists, but the start behavior needs to be productized.
- Meta DAT photo/video is not part of audio V1 and should not block live voice.

## Goals

- Kish can wear Meta Ray-Ban Gen 2 glasses and start a KishOS live voice session at any time.
- Route state is truthful: system, external available, external active, switching, lost, or blocked.
- Live voice preserves selected conversation and project context.
- Voice input remains reviewable in normal dictation; live call/walk mode can auto-finalize spoken turns.
- Spoken replies are concise and limited to hands-free contexts by default.
- The system recovers from mute, interruption, route loss, failed speech recognition, and backend failure.
- The architecture leaves room for explicit glasses photo/video capture after audio is reliable.

## Non-Goals

- No passive camera capture.
- No always-on ambient recording.
- No automatic sending from normal dictation.
- No Meta DAT dependency in the audio V1 slice.
- No promise that iOS can force an exact hardware route when the OS only exposes category/options.
- No spoken reading of private intermediate steps by default.
- No separate conversation model for walk mode.

## Primary User Flow

1. Kish wears Meta Ray-Ban Gen 2 glasses.
2. Kish starts KishOS live voice through the chosen activation path.
3. App activates or attempts to prefer the glasses/headset route.
4. App starts live call in the selected or default conversation.
5. Kish speaks a request.
6. Speech finalizes into a turn.
7. Agent streams work in the normal conversation.
8. App speaks a concise final reply when hands-free spoken output is enabled.
9. Kish can interrupt, answer questions, mute, or end.
10. The transcript and agent work remain in the normal chat.

## Activation Paths

P0 needs at least one dependable activation path plus fallback. Candidate paths:

- Wake phrase from iPhone while glasses are active or available.
- Siri Shortcut / App Shortcut.
- Lock Screen or Live Activity action.
- In-app call button.
- Hardware headset/call affordance if iOS exposes a usable behavior for the glasses.

Preferred product behavior:

- Wake phrase or shortcut should start the glasses-first live voice flow.
- It should not merely open the app unless permissions, route state, or app state block live voice.
- If glasses are unavailable, start on phone audio or show a clear blocked state.

Acceptance:

- Given Kish is wearing paired Meta Ray-Ban Gen 2 glasses, when he uses the chosen entry point, then KishOS starts live voice or shows a clear blocked/fallback state.
- Given glasses are unavailable, when Kish starts the flow, then KishOS falls back to phone audio rather than silently failing.

## Product Model

### Normal Chat

- Text entry and attachments.
- Dictation fills composer.
- User manually sends.
- Spoken output off unless explicitly requested.

### Live Call

- Conversation is active as a voice session.
- Speech can finalize into turns.
- Agent reply streams and can be spoken.
- User can mute, interrupt, answer questions, retry, or end.

### Walk Mode

- Focused live-call presentation for glasses/no-look use.
- Uses current conversation or starts a new conversation with selected project.
- Shows route, listening state, transcript preview, and one primary action.
- Keeps the normal chat transcript as the durable record.

### Route States

- `System`: built-in phone/Mac audio is active.
- `External available`: headset/glasses are visible but not active.
- `External active`: headset/glasses are active input or output.
- `Switching`: user asked to prefer external, app is trying to activate it.
- `Lost`: preferred route was active or available and disappeared.
- `Blocked`: permissions, OS route limitations, or failed audio session setup prevent capture.

### Capture Rules

- Normal dictation never auto-sends.
- Live call and walk mode can auto-finalize after silence.
- Wake phrase can start the live voice flow only when enabled and not suppressed.
- Photo/video capture remains explicit and review-first.

## UX Requirements

### Conversation Audio Status

Show one compact audio status affordance in the conversation surface:

- Route label: `System`, `AirPods`, `Glasses`, `Bluetooth`, or `Lost`.
- Listening state only when active.
- Tap opens route details/settings.
- Avoid repeating the same route state in header, composer, and call body.

Acceptance:

- Given glasses are paired but not active, the UI says available, not active.
- Given glasses disconnect while active, the UI changes to lost or system fallback within one second of route notification.

### Route Sheet

Provide compact iOS and Mac route detail surfaces:

- Current input.
- Current output.
- Available route candidates.
- Prefer external toggle.
- Refresh routes.
- Route health.
- Capability readiness for dictation, wake phrase, live call, snapshot ask, and DAT future.

Acceptance:

- Given external route is available, when Kish enables Prefer external, then app attempts Bluetooth HFP / voiceChat route activation.
- Given route activation fails, chat remains usable and UI explains fallback.

### Walk Mode Surface

Walk mode is launched from live voice activation or from the current conversation.

Layout:

- Top: conversation title, project badge if available, route chip.
- Center: large mic/stop/mute control.
- Middle: live transcript preview.
- Bottom: stop/end while in call; edit/discard/send only for captured text outside active call.
- Small status: listening, thinking, replying, blocked, reconnecting, or lost route.

Acceptance:

- Given selected conversation has project context, when Kish starts walk/live call from glasses, first spoken turn preserves that context.
- Given speech recognition produces a partial, when Kish mutes or discards, stale partial text is cleared and not sent.
- Given backend asks a question, walk mode shows answer controls or a compact path back to the normal question card.

### Spoken Replies

Default:

- Spoken replies are enabled only in live call/walk mode.
- Normal chat never speaks unless explicitly requested.
- The app speaks final assistant text only, not tool steps or private intermediate activity.

Controls:

- Stop speaking.
- Mute output.
- Repeat last answer.
- Optional concise mode.

Acceptance:

- Given spoken replies are enabled, only final assistant answer is spoken.
- Given Kish presses stop while speaking, speech stops immediately and call remains usable.

### Wake Phrase

Wake phrase remains opt-in.

Rules:

- Pauses when dictation, live call, or walk mode owns the mic.
- Does not run without speech/mic permission.
- Does not auto-send normal dictation.
- Default product direction: start the glasses-first live voice flow.

Acceptance:

- Given wake phrase is enabled and no call is active, saying the phrase starts live voice or shows a clear blocked/fallback state.
- Given live call is active, wake recognition is suppressed.

## Requirements

### P0: Meta Ray-Ban Gen 2 Live Voice Start

Requirements:

- Determine the most reliable V1 activation path.
- Start live call through current infrastructure.
- Prefer or truthfully report glasses route.
- Preserve selected conversation/project context.
- Fall back to phone audio when glasses are unavailable.

Acceptance:

- Kish can put on Meta Ray-Ban Gen 2 glasses and start KishOS live voice without a multi-step app flow.
- App makes route state explicit before or immediately after session start.
- If glasses are unavailable, flow falls back or shows a clear blocked state.

### P0: Reliable Walk Mode

Requirements:

- One route-aware entry point from iOS conversation view.
- Route state visible before and during capture.
- Capture, stop, discard, send/edit flows where applicable.
- Clean recovery from mute, route loss, failed speech recognition, and backend failure.
- No auto-send outside live call/walk mode.

Acceptance:

- Manual QA covers iPhone built-in mic, AirPods or Bluetooth headset, and Meta Ray-Ban Gen 2.
- Hardware or simulated route tests cover system, external available, external active, and lost route.
- iOS build passes.
- Focused live call/audio tests pass or are added before closure.

### P0: Truthful Route State

Requirements:

- `AudioRouteMonitor` publishes current input/output, preferred route, active route kind, available candidates, activation result, and lost/fallback state.
- UI never implies glasses are active solely because they are paired.
- Prefer external fails soft.

Acceptance:

- Given no external route exists, Prefer external does not break dictation.
- Given iOS refuses activation, UI displays fallback and dictation still works.

### P0: Live Call Hardening for Hands-Free Use

Requirements:

- Mute clears pending partials.
- Interrupt/stop cancels local stream and backend run.
- Retry from failure restarts setup.
- Spoken reply can be stopped.
- Project context persists.
- Route changes refresh while call is active.

Acceptance:

- User can start live call, speak, interrupt, retry, and end without leaving a stuck running state.

### P1: Wake Phrase or Shortcut Activation

Requirements:

- Implement the chosen start behavior.
- Preferred direction: wake phrase or shortcut starts the glasses-first live voice flow.
- Suppress wake phrase while live call owns the mic.
- Provide fallback if permissions or audio state block capture.

Acceptance:

- Wake/shortcut starts live voice when possible.
- Wake suppression resumes correctly after call ends.

### P1: Concise Spoken Reply Mode

Requirements:

- Add concise spoken-answer mode for walk/live call.
- Avoid reading long logs, code blocks, or tool output.
- Keep full transcript available in chat if needed.

Acceptance:

- Spoken output is short enough for hands-free use without losing the durable transcript.

### P1: Hands-Free Decision Answering

Requirements:

- Let voice answer normal agent questions during walk mode.
- Map spoken answer to pending question response with transcript confirmation.
- Risky approvals require explicit approve/deny confirmation.

Acceptance:

- Normal question can be answered by voice.
- Risky approval requires clear confirmation before submission.

### P1: Lock Screen and Notification Rejoin

Requirements:

- Live Activity shows walk/live-call state.
- Done, failed, or needs-answer notifications open exact conversation.
- Duplicate notifications are suppressed.

Acceptance:

- Kish can background a run, receive status, and rejoin the correct conversation.

### P2: Explicit First-Person Photo

Requirements:

- Add "ask about this" as explicit capture from walk mode.
- Reuse snapshot review and native attachment path for phone camera.
- Use Meta DAT only for glasses camera capture.

Acceptance:

- User captures one image, reviews it, and sends it with current thread context.

### P2: Meta DAT Photo/Video Capture

Requirements:

- Separate module after audio V1 is reliable.
- Capability flag controlled.
- MockDeviceKit tests required.
- Explicit permission and capture review.
- Photo before video.
- Video has visible recording state, short duration limits, and review before send.

Acceptance:

- No DAT dependency is introduced in audio V1.
- Follow-up worktree can send an explicitly approved photo or short video from what Kish is looking at.

## Technical Architecture

### Client

Likely files:

- `Clawk/KishOSCore/AudioRouteMonitor.swift`
- `Clawk/KishOSCore/VoiceController.swift`
- `Clawk/Clawk/WakePhraseController.swift`
- `Clawk/Clawk/LiveCallController.swift`
- `Clawk/Clawk/LiveCallView.swift`
- `Clawk/Clawk/KishOSIOSRootView.swift`
- `Clawk/Clawk/KishOSLiveActivityController.swift`
- `Clawk/KishOSMac/KishOSMacApp.swift`
- `Clawk/KishOSCore/KishOSFeaturePlan.swift`
- `Clawk/KishOSMacTests/*`

Model additions to consider:

```swift
enum HandsFreeModeState: String, Codable {
    case inactive
    case routeSetup
    case ready
    case listening
    case transcriptReady
    case thinking
    case speaking
    case blocked
    case failed
}

struct HandsFreeSessionSnapshot: Codable, Equatable {
    var conversationID: UUID?
    var projectPath: String?
    var routeKind: AudioRouteKind
    var routeLabel: String
    var state: HandsFreeModeState
    var transcriptPreview: String
    var canAutoFinalize: Bool
}
```

Walk mode should not introduce a second conversation model.

### Backend

No new backend is required for audio route handling. Backend work may be needed for:

- Better cancel semantics if live-call stop leaves remote runs alive.
- Run status recovery if app resumes mid-call.
- Concise spoken reply prompt hints.
- Pending decision metadata for voice answering.
- Future DAT photo/video attachment ingest.

## Testing

Automated:

- Unit tests for route status derivation.
- Unit tests for live-call state transitions around mute, stop, retry, route loss, and speech stop.
- Agent client tests for preserving project context in call sends.
- iOS simulator build.

Manual:

- Built-in iPhone mic.
- AirPods or generic Bluetooth headset.
- Meta Ray-Ban Gen 2 glasses.
- Route disconnect/reconnect during listening.
- Background/reopen during live call.
- Wake phrase suppression/resume.
- Spoken reply stop/repeat.

Suggested commands:

```bash
xcodebuild test -project Clawk/Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/AgentClientTests
xcodebuild build -project Clawk/Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS Simulator'
```

## Phased Worktree Plan

### Phase 1: Hardware Audit and Activation Decision

- Run current app with Meta Ray-Ban Gen 2.
- Record route names and behavior.
- Identify false active/available states.
- Determine the most reliable activation path.
- Add route-state tests.

Exit criteria:

- Known hardware matrix exists.
- Activation path is selected.
- Route model is trustworthy enough for UI.

### Phase 2: Walk Mode V1

- Add focused iOS walk surface.
- Reuse live-call controller where possible.
- Preserve transcript, project, and conversation context.
- Make default flow "start live voice," not "open route settings."

Exit criteria:

- Kish can start and complete a hands-free turn without stuck state.

### Phase 3: Spoken Reply and Interrupt Polish

- Stop/repeat spoken replies.
- Concise spoken mode.
- Better interruption from voice and UI.
- Route loss handling while speaking.

Exit criteria:

- Hands-free mode survives speak/listen/reply/interruption loop.

### Phase 4: Decision and Notification Integration

- Voice answer pending questions.
- Require explicit confirmation for risky approvals.
- Rejoin from notification/Live Activity.

Exit criteria:

- Kish can leave the app, get needs-answer status, and resolve it in voice mode.

### Phase 5: Explicit Glasses Photo/Video Plan

- Evaluate Meta DAT setup using `glassbridge` learnings.
- Add capability flags and permission states.
- Spec photo capture before video.
- Require review before send.

Exit criteria:

- Follow-up worktree can add explicit glasses photo capture without disturbing live voice.

## Success Metrics

Leading:

- 90% of manual voice captures produce usable transcript without losing state.
- Route state updates within one second of connect/disconnect in manual QA.
- No stuck running conversations after stop/end/retry test matrix.
- At least five consecutive hands-free turns complete with Meta Ray-Ban Gen 2.

Lagging:

- Kish uses voice/walk mode for real tasks multiple days in a row.
- Fewer manual keyboard corrections during quick prompts.
- More long-running tasks are supervised from notifications or voice instead of abandoned.

## Remaining Open Questions

- Should walk mode be iPhone-first only, or should Mac get a parallel hands-free surface later?
- Is wake phrase the primary activation path, or should Shortcut/Siri/Lock Screen action be first?
- Is tap-to-toggle enough inside the app, or do you want press-and-hold for short captures?
- How much spoken output is acceptable in public: full answer, concise answer, or only summaries?
- Should normal dictation ever offer "send immediately," or should it always require review?
- Do you want voice answers to approvals, or should approvals always require a tap for now?
