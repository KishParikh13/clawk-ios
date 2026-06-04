# KishOS Glasses Integration Roadmap

Date: 2026-06-04

## Current Build

KishOS now treats glasses as a first-class audio route without depending on Meta DAT. This is the right V1 because Ray-Ban Meta and similar glasses can work as standard Bluetooth call audio, while camera/display access requires Meta Developer Preview setup and user/device permissions.

Implemented in the app:

- Shared route model for system, built-in, Bluetooth, headset, and glasses-like routes.
- Prefer External setting that asks iOS to activate a hands-free Bluetooth route before dictation.
- Mac Settings audio panel with input, output, route mode, route health, route list, and capability readiness.
- iOS Audio settings sheet from the conversation panel with route controls, wake phrase state, and capability readiness.
- Capability labels for audio route, dictation, wake phrase, snapshot ask, planned Meta camera, and planned Ray-Ban Display.

## Glassbridge Findings

Reusable ideas from `/Users/kishparikh/Code/glassbridge/glassbridge`:

- `AudioController.swift` proved the important AVAudioSession behavior: use `.playAndRecord`, `.voiceChat`, `.allowBluetoothHFP`, and route activation polling. The app should accept Ray-Ban/Meta names, generic Bluetooth, BLE audio, headset mic, and headphones.
- `WakeWordListener.swift` proved that a local Apple Speech wake phrase is viable, but it must pause while an active chat/call owns the microphone.
- `SessionCoordinator.swift` proved the state machine shape: idle, listening, thinking, speaking, and error.
- The DAT camera path is real but externally gated. It should be integrated behind a capability flag instead of becoming a compile-time dependency for the V1 audio feature.

## Meta Wearables SDK Research

Official sources checked:

- `facebook/meta-wearables-dat-ios` README: DAT is an iOS Swift Package for hands-free wearable experiences with Meta AI glasses, including video streaming and photo capture, and is in Developer Preview.
- DAT v0.7 discussion and changelog dated 2026-05-14: adds Display capability for Meta Ray-Ban Display, the new Device Access Toolkit App Model, live device/thermal state, battery/thermal errors, and updated session/camera APIs.
- DAT `AGENTS.md`: SDK modules are `MWDATCore`, `MWDATCamera`, `MWDATDisplay`, and `MWDATMockDevice`; setup requires Meta AI companion app, Developer Mode or release channel, Info.plist entries, URL callbacks, registration, and permissions.

Technical implications:

- V1 should not import DAT. Audio through glasses is already possible through iOS Bluetooth route APIs and is more reliable for daily use.
- DAT should be added as a separate V2/V3 module when we are ready to build explicit glasses camera/display features.
- DAT work needs MockDeviceKit tests from the start so simulator QA is possible without physical glasses.
- Vision must remain explicit: capture one photo or a short frame burst only after the user asks.

## Next Milestones

### M7a: Hardware Audio QA

Goal: prove the current V1 with real glasses.

Checklist:

- Pair Ray-Ban Meta or target glasses with iPhone.
- Enable Prefer External in Audio settings.
- Confirm route status becomes Glasses, Bluetooth, or Headset.
- Dictate from normal chat and confirm transcript lands in the composer.
- Start live call and confirm listening uses the selected route.
- Disconnect/reconnect glasses and confirm fallback is visible and recoverable.

### M7b: Walkie-Talkie Polish

Goal: make live call feel like the glasses mode.

Build:

- Compact route chip in Live Call header with health state.
- One-tap route refresh/prefer external before call starts.
- Short spoken status only inside live call mode.
- Clear fallback state when glasses disappear mid-call.

### M8: DAT Vision Spike

Goal: build the smallest safe path for "look at this".

Build:

- Add DAT package behind an isolated optional integration target or feature flag.
- Configure Info.plist keys and URL callback handling.
- Add registration/permission UI in Audio/Glasses settings.
- Use MockDeviceKit in simulator tests.
- Capture one JPEG, show review UI, upload via existing attachment path, then send.

### M9: Display / Agent Status

Goal: use Ray-Ban Display only when available.

Build:

- Capability-detect display support.
- Show call state, agent state, and one pending decision at a time.
- Keep all actions mirrored in the app so display remains optional.

## Maintenance Plan

- Keep `clawk-ios` as the production app.
- Keep `glassbridge` as hardware/prototype reference until DAT integration is stable.
- Do not duplicate agent/MCP execution on-device; KishOS app sends transcript, attachments, references, and decisions to `kish-agent`.
- Add DAT only behind a small boundary so non-DAT builds remain simple and shippable.
