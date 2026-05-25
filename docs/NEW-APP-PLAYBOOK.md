# New App Playbook — Fully Autonomous Setup

This playbook is for agents (Claude Code / OpenClaw ACP sessions) to create and deploy a new iOS app end-to-end with zero human intervention.

## Prerequisites (one-time, already installed on Mac mini)

```bash
# asc CLI — App Store Connect automation
brew install app-store-connect-cli
# Or: curl -fsSL https://asccli.sh/install | sh

# Auth: create an API key in App Store Connect → Users and Access → Integrations → App Store Connect API
# Store as environment variables:
export ASC_KEY_ID="your-key-id"
export ASC_ISSUER_ID="your-issuer-id"
export ASC_PRIVATE_KEY_PATH="~/AuthKey_XXXX.p8"

# GitHub CLI
brew install gh
gh auth login

# Claude Code + XcodeBuildMCP (already configured)
```

---

## Full automation script

An agent can run this entire sequence. Replace variables as needed.

### Step 1: Scaffold the project

```bash
APP_NAME="MyNewApp"
BUNDLE_ID="com.kishparikh.mynewapp"
APP_DIR="$HOME/Code/$APP_NAME"

mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Create Swift Package-based iOS app
cat > Package.swift << 'PKGEOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APP_NAME_PLACEHOLDER",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "APP_NAME_PLACEHOLDER", targets: ["APP_NAME_PLACEHOLDER"])
    ],
    targets: [
        .target(name: "APP_NAME_PLACEHOLDER", path: "Sources"),
        .testTarget(name: "APP_NAME_PLACEHOLDERTests", dependencies: ["APP_NAME_PLACEHOLDER"], path: "Tests")
    ]
)
PKGEOF
sed -i '' "s/APP_NAME_PLACEHOLDER/$APP_NAME/g" Package.swift

# Create minimal SwiftUI app
mkdir -p Sources Tests

cat > Sources/${APP_NAME}App.swift << 'APPEOF'
import SwiftUI

@main
struct APP_NAME_PLACEHOLDERApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
APPEOF
sed -i '' "s/APP_NAME_PLACEHOLDER/$APP_NAME/g" Sources/${APP_NAME}App.swift

cat > Sources/ContentView.swift << 'VIEWEOF'
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "star.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                Text("Welcome to APP_NAME_PLACEHOLDER")
                    .font(.title2.bold())
            }
            .navigationTitle("APP_NAME_PLACEHOLDER")
        }
    }
}
VIEWEOF
sed -i '' "s/APP_NAME_PLACEHOLDER/$APP_NAME/g" Sources/ContentView.swift

cat > Tests/${APP_NAME}Tests.swift << 'TESTEOF'
import Testing
@testable import APP_NAME_PLACEHOLDER

@Test func appExists() {
    #expect(true)
}
TESTEOF
sed -i '' "s/APP_NAME_PLACEHOLDER/$APP_NAME/g" Tests/${APP_NAME}Tests.swift
```

### Step 2: Create the Xcode project (headless)

```bash
# Use XcodeBuildMCP or xcodegen to create .xcodeproj from the Swift sources
# Option A: swift package generate-xcodeproj (deprecated but works)
swift package generate-xcodeproj

# Option B: Use xcodegen (preferred)
# brew install xcodegen
cat > project.yml << YMLEOF
name: $APP_NAME
options:
  bundleIdPrefix: com.kishparikh
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "26.0"
settings:
  base:
    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: false
    INFOPLIST_KEY_CFBundleDisplayName: $APP_NAME
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: 1
targets:
  $APP_NAME:
    type: application
    platform: iOS
    sources:
      - Sources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
    scheme:
      testTargets:
        - ${APP_NAME}Tests
  ${APP_NAME}Tests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - Tests
    dependencies:
      - target: $APP_NAME
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ${BUNDLE_ID}.tests
YMLEOF
xcodegen generate
```

### Step 3: Add agent config

```bash
# CLAUDE.md
cat > CLAUDE.md << 'CLAUDEEOF'
# Agent instructions

## Project
This is a SwiftUI iOS app targeting iOS 17+. It uses SwiftData for persistence where needed.

## Conventions
- SwiftUI only, no UIKit
- No third-party dependencies unless explicitly requested
- Build and test before pushing (use XcodeBuildMCP)
- Info.plist must include ITSAppUsesNonExemptEncryption = NO

## Build
Build via XcodeBuildMCP or: xcodebuild -scheme APP_NAME -sdk iphonesimulator build

## Deploy
Push to main → Xcode Cloud auto-builds → TestFlight distribution.
CLAUDEEOF
sed -i '' "s/APP_NAME/$APP_NAME/g" CLAUDE.md

# .claude/settings.json
mkdir -p .claude
cat > .claude/settings.json << 'SETTINGSEOF'
{
  "permissions": {
    "allow": [
      "Read", "Write", "Edit",
      "Bash(xcodebuild*)", "Bash(xcrun*)", "Bash(git*)",
      "Bash(swift*)", "Bash(open*)", "Bash(ls*)", "Bash(cat*)",
      "Bash(find*)", "Bash(grep*)", "Bash(mkdir*)", "Bash(cp*)",
      "Bash(mv*)", "Bash(rm*)", "Bash(asc*)"
    ]
  },
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest"]
    }
  }
}
SETTINGSEOF

# .gitignore
cat > .gitignore << 'GITEOF'
build/
DerivedData/
*.xcuserdata/
.build/
Package.resolved
.DS_Store
.env
*.p12
*.mobileprovision
AuthKey_*.p8
GITEOF
```

### Step 4: Git + GitHub

```bash
cd "$APP_DIR"
git init
git add .
git commit -m "Initial commit: $APP_NAME iOS app"
gh repo create "$APP_NAME" --private --source=. --push
```

### Step 5: Register bundle ID + create app in App Store Connect

```bash
# Register the bundle ID
asc bundle-ids create \
  --identifier "$BUNDLE_ID" \
  --name "$APP_NAME" \
  --platform IOS

# Create the app in App Store Connect
asc apps create \
  --name "$APP_NAME" \
  --bundle-id "$BUNDLE_ID" \
  --sku "$(echo $APP_NAME | tr '[:upper:]' '[:lower:]')" \
  --primary-locale "en-US"
```

### Step 6: Create Xcode Cloud workflow

```bash
# Get the app ID (created in step 5)
APP_ID=$(asc apps list --bundle-id "$BUNDLE_ID" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")

# Get the repo ID (GitHub connection must exist in App Store Connect)
# If not connected yet, this needs to be done once in App Store Connect UI
# After that, the asc CLI can manage workflows

# Create workflow: build on push to main → distribute to TestFlight
asc xcode-cloud workflows create \
  --app-id "$APP_ID" \
  --name "Deploy to TestFlight" \
  --branch "main" \
  --action "archive" \
  --distribution "testflight-internal"

# Or trigger an existing workflow
asc xcode-cloud run --app "$APP_NAME" --workflow "Deploy to TestFlight" --branch "main"
```

### Step 7: Verify

```bash
# Build locally to confirm it compiles
xcodebuild -scheme "$APP_NAME" -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

echo "✅ $APP_NAME is ready!"
echo "   Repo: https://github.com/kishparikh/$APP_NAME"
echo "   Next: push to main to trigger Xcode Cloud → TestFlight"
```

---

## Agent-friendly summary

When the user says "create a new app called X":

1. Run the scaffold script (Steps 1-3)
2. Push to GitHub (Step 4)
3. Register in App Store Connect (Steps 5-6)
4. Build to verify (Step 7)
5. Report back to the user with the GitHub link

The user's only action is installing from TestFlight when the notification arrives.

---

## Notes

- **Bundle ID format**: always `com.kishparikh.<lowercase-app-name>`
- **GitHub repos**: always private by default
- **First Xcode Cloud connection**: if GitHub hasn't been connected to App Store Connect before, this one-time step needs the App Store Connect web UI. After that, all subsequent apps work via CLI.
- **xcodegen** is preferred over `swift package generate-xcodeproj` since the latter is deprecated. Install via `brew install xcodegen`.
- **The `asc` CLI auth** uses App Store Connect API keys stored as env vars on the Mac mini. These keys should have "App Manager" role.
