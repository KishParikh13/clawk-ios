# User-Required Tasks

Last updated: 2026-06-10

These tasks need Kish's accounts, hardware, network access, or product decisions. They should be done after the local engineering checklist is green.

## Apple and Publishing

- Confirm Apple Developer Team ID and replace placeholders in `fastlane/Appfile`.
- Create or select the private Match certificate repository and update `fastlane/Matchfile`.
- Create an App Store Connect API key for Fastlane upload.
- Confirm the App Store app record name, SKU, category, age rating, support URL, marketing URL, and privacy policy URL.
- Review App Store privacy answers for microphone, speech recognition, camera/photos, Bluetooth, local network, notifications, memory, and agent transcripts.
- Upload the first TestFlight build and add internal testers.

## Backend and Network

- Decide the external-user deployment model:
  - personal Mac mini companion,
  - team-hosted agent client,
  - or standalone app with managed backend.
- Decide authentication for `kish-agent` before non-personal distribution.
- Update `kish-agent` `/health` to report `version` and `endpoints`.
- Confirm which old relay/dashboard workflows, if any, are still used before deleting `backend/` and old dashboard screens.

## Hardware QA

- Test live call audio with real Meta Ray-Ban Gen 2 glasses.
- Test route loss, reconnection, mute, spoken reply stop, wake phrase suppression, and fallback to phone audio.
- Test explicit glasses photo capture with review before sending.

## Product Decisions

- Pick the first reliable hands-free activation path: wake phrase, Shortcut/Siri, Live Activity action, in-app button, or another OS-supported entry.
- Decide whether daily brief runs automatically, on demand, or both.
- Decide whether routine outputs land in one shared thread or routine-specific conversations.
- Decide the first narrow set of safe routines that may run without per-run approval.
