# Demo and Release Checklist

Last updated: 2026-06-10

## Demo-Ready Baseline

- Run `./generate-project.sh` after changing `Clawk/project.yml`.
- Run `scripts/verify-local.sh`.
- Confirm the Mac mini `kish-agent` is reachable from the demo device.
- Open Settings and confirm:
  - Agent URL is correct.
  - Mac mini, HTTP, Agent, and Chat are healthy.
  - Native API is `Ready` or intentionally `Unknown` for an older compatible agent.
  - Tools are available.
- Create a new chat, stream a slow reply, cancel once, retry once.
- Select a project, send a follow-up, and confirm project context stays locked.
- Attach one photo/file and one `@` file/folder reference.
- Test one approval/question response.
- On iOS, test dictation, live call start/end, mute, and spoken reply stop.
- If showing glasses work, test with real Meta Ray-Ban Gen 2 hardware before the demo.

## Publish Blockers

- Replace personal-hostname assumptions with onboarding, clear auth, and deployment docs.
- Set up production signing, App Store Connect API key, and Fastlane Match values.
- Register app capabilities: Push Notifications, Live Activities, microphone, speech recognition, camera, Bluetooth, and local network messaging.
- Write the privacy policy and permission explanations for voice, speech recognition, camera/photos, Bluetooth, local network, memory, and notifications.
- Remove or quarantine legacy dashboard/gateway/relay code from the active product target.
- Decide the product boundary for external users: personal Mac mini companion, team-hosted agent client, or standalone app.
- Ship a backend compatibility matrix for `kish-agent`.
- Finish hardware QA for live voice route changes and Meta glasses capture.
- Add TestFlight tester onboarding with agent setup steps and known limitations.

## Product Completion Tracks

1. Hands-free/glasses: finish walk mode, activation path, route-loss recovery, concise spoken replies, and real-hardware QA.
2. Memory/routines: expose `kish-context` through native endpoints, add memory pins/forget controls, daily brief, routine proposal approval, and routine run records.
3. Supervision: session recovery, live run timeline, interrupt steering, and decision inbox.
4. Cleanup: delete legacy backend/dashboard paths once native replacements are verified.
