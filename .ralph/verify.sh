#!/usr/bin/env bash
set -euo pipefail

git diff --check

xcodebuild test \
  -project Clawk/Clawk.xcodeproj \
  -scheme KishOSMac \
  -destination 'platform=macOS' \
  -derivedDataPath .context/DerivedData-Ralph \
  -only-testing:KishOSMacTests/ConversationTests \
  -only-testing:KishOSMacTests/ConversationStoreTests \
  -only-testing:KishOSMacTests/AgentClientTests \
  -only-testing:KishOSMacTests/ProjectStoreTests

xcodebuild build \
  -project Clawk/Clawk.xcodeproj \
  -scheme Clawk \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .context/DerivedData-Ralph-iOS
