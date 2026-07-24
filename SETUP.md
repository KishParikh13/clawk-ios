# KishOS Local Setup

This setup is for the current native KishOS app. Older Railway relay setup notes were removed because the primary chat path now talks to the Mac mini `kish-agent`.

## Prerequisites

- macOS with Xcode installed.
- XcodeGen. `./generate-project.sh` installs it with Homebrew if needed.
- Network access to a compatible `kish-agent`; the default development URL is `http://kishs-mac-mini-1:17891`.
- Optional for TestFlight: Apple Developer account and App Store Connect access.

## Generate the Project

```bash
./generate-project.sh
```

This reads `Clawk/project.yml` and creates `Clawk/Clawk.xcodeproj`.

## Run Locally

Open the project:

```bash
open Clawk/Clawk.xcodeproj
```

Useful schemes:

- `Clawk`: iOS app target.
- `KishOSMac`: macOS app target.
- `KishOSWidgetExtension`: widget and Live Activity extension.

The native client default is `KishAgentClient.defaultBaseURL`, currently:

```text
http://kishs-mac-mini-1:17891
```

The app expects the agent to provide conversation, streaming, project, attachment, file-reference, branch-switch, approval, cancel, and tool-inventory endpoints. If the Mac mini hostname is not resolvable from the current network, use a reachable hostname or IP from Settings in the app. See [docs/specs/kish-agent-native-api.md](docs/specs/kish-agent-native-api.md) for the current native API contract.

## Verify

Run the full local verifier:

```bash
scripts/verify-local.sh
```

Run focused client tests:

```bash
xcodebuild test -project Clawk/Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/AgentClientTests
```

Run an iOS simulator build:

```bash
xcodebuild build -project Clawk/Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS Simulator'
```

Run the Ralph queue verifier:

```bash
.ralph/verify.sh
```

## Legacy Backend

`backend/` and some legacy app files still reference the older relay/dashboard architecture. Keep them available until they are deliberately removed, but do not treat them as the source of truth for the native KishOS roadmap.
