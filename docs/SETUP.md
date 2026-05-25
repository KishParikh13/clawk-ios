# Setup Guide — Phone to TestFlight Pipeline

This is a one-time setup. After this, you can build and deploy iOS apps from your phone without touching Xcode again.

## Prerequisites

- Mac mini (M1 or later, always on, macOS 15+)
- Tailscale installed and running on Mac mini + phone
- Apple Developer Program membership ($99/year)
- GitHub account
- Anthropic API key (for Claude Code)

---

## Step 1: Mac mini software setup

### 1.1 Install Xcode

```bash
# Install Xcode 26 beta from developer.apple.com
# Or via mas (Mac App Store CLI):
mas install 497799835

# Accept license
sudo xcodebuild -license accept

# Install command line tools
xcode-select --install
```

### 1.2 Install Node.js

```bash
# Via Homebrew
brew install node

# Verify (needs 18+)
node --version
```

### 1.3 Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code

# Set your API key (add to ~/.zshrc for persistence)
export ANTHROPIC_API_KEY="sk-ant-your-key-here"
```

### 1.4 Install OpenClaw

```bash
npm install -g openclaw

# Initialize
openclaw init

# Start the gateway
openclaw gateway
```

### 1.5 Install XcodeBuildMCP

No separate install needed — it runs via npx. Verify it works:

```bash
npx xcodebuildmcp@latest --help
```

### 1.6 Install GitHub CLI

```bash
brew install gh
gh auth login
```

### 1.7 Install asc CLI (App Store Connect automation)

This lets agents create apps, register bundle IDs, and trigger Xcode Cloud builds without you touching App Store Connect.

```bash
brew install app-store-connect-cli
```

Create an API key in App Store Connect → Users and Access → Integrations → App Store Connect API (role: "App Manager"). Download the .p8 file.

```bash
# Add to ~/.zshrc for persistence
export ASC_KEY_ID="your-key-id"
export ASC_ISSUER_ID="your-issuer-id"
export ASC_PRIVATE_KEY_PATH="$HOME/AuthKey_XXXX.p8"
```

### 1.8 Install xcodegen (headless project generation)

This lets agents create .xcodeproj files without opening Xcode.

```bash
brew install xcodegen
```

---

## Step 2: Connect OpenClaw to your messaging channel

### Option A: iMessage (recommended for Apple ecosystem)

OpenClaw supports iMessage via the macOS Messages app. Follow the OpenClaw docs:
```bash
openclaw channel add imessage
```

### Option B: WhatsApp

```bash
openclaw channel add whatsapp
# Follow QR code pairing flow
```

### Option C: Telegram

```bash
openclaw channel add telegram
# Provide your bot token from @BotFather
```

### Option D: Slack / Discord

```bash
openclaw channel add slack    # or discord
# Follow OAuth flow
```

After adding a channel, verify:
```bash
openclaw status
```

---

## Step 3: Set up the GitHub repo

On your Mac mini:

```bash
cd ~/Code/clawk-ios

# Initialize git
git init
git add .
git commit -m "Initial commit: Clawk iOS OpenClaw client"

# Create GitHub repo and push
gh repo create clawk-ios --private --source=. --push
```

---

## Step 4: Configure Xcode Cloud

This step requires App Store Connect access (one time only):

### 4.1 Create the app in App Store Connect

1. Go to https://appstoreconnect.apple.com
2. My Apps → "+" → New App
3. Fill in: name "Clawk", bundle ID "com.yourname.clawk", SKU "clawk"

### 4.2 Connect to Xcode Cloud

**Option A: Via Xcode (easiest)**
1. Open the project in Xcode on your Mac mini
2. Product → Xcode Cloud → Create Workflow
3. Connect your GitHub repo
4. Set start condition: "Branch changes" → `main`
5. Add action: "Archive" → iOS
6. Add post-action: "TestFlight (Internal Testing)"
7. Save

**Option B: Via App Store Connect**
1. Go to App Store Connect → Xcode Cloud
2. Create workflow → Connect to GitHub
3. Select clawk-ios repo
4. Configure same triggers as above

### 4.3 Critical: Export compliance flag

Make sure your Info.plist contains:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Without this, TestFlight pauses the build and asks for export compliance review, breaking the automated flow.

---

## Step 5: Configure Tailscale

If not already done:

```bash
# Mac mini
brew install tailscale
# Sign in and approve the device

# Note your Mac mini's Tailscale hostname/IP
tailscale status
```

Update `Config.swift` in the Clawk app to use your Mac mini's Tailscale address instead of `localhost`:

```swift
// In Config.swift, update:
static let baseURL = "http://your-mac-mini.tailnet-name.ts.net:3002"

// And in GatewayConnection.swift init, update default host:
init(host: String = "your-mac-mini.tailnet-name.ts.net", port: Int = 18789)
```

---

## Step 6: Test the pipeline

### 6.1 Verify Mac mini services are running

```bash
# Check OpenClaw gateway
openclaw status

# Check Tailscale
tailscale status

# Check Xcode CLI
xcodebuild -version

# Check Claude Code
claude --version
```

### 6.2 Send a test message

From your phone, send a message to OpenClaw via your chosen channel:

> "Build the clawk-ios project and tell me if it compiles"

Claude Code should:
1. Read the project
2. Use XcodeBuildMCP to build
3. Report back success/failure

### 6.3 Test the full pipeline

> "Add a simple About screen to clawk-ios that shows the app version, then push it to GitHub"

This should:
1. Create the SwiftUI view
2. Build and test locally
3. Commit and push
4. You merge on GitHub mobile
5. Xcode Cloud builds
6. TestFlight notification arrives

---

## Step 7: Automate OpenClaw startup (optional)

Create a LaunchAgent so OpenClaw starts automatically when the Mac mini boots:

```bash
cat > ~/Library/LaunchAgents/com.openclaw.gateway.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/openclaw</string>
        <string>gateway</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ANTHROPIC_API_KEY</key>
        <string>YOUR_KEY_HERE</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/openclaw.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/openclaw.err</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.openclaw.gateway.plist
```

---

## What's next

- Read `docs/PIPELINE.md` for the daily workflow
- Read `docs/NEW-APP-PLAYBOOK.md` for creating new apps autonomously (agent does everything)
- Read `docs/TROUBLESHOOTING.md` when something breaks
- Read `docs/ARCHITECTURE.md` for how all the pieces connect
- Read `CLAUDE.md` for how the coding agent should work in this repo
