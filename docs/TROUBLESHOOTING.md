# Troubleshooting Guide

Quick reference for when things break. Organized by symptom.

---

## OpenClaw / Agent Issues

### "OpenClaw gateway not responding"

```bash
# Check if it's running
openclaw status

# Restart it
openclaw gateway

# Check logs
openclaw logs

# Nuclear option — restart everything
openclaw sandbox recreate --all
openclaw gateway
```

### "Claude Code session not spawning"

```bash
# Verify Claude Code is installed
claude --version

# Check API key is set
echo $ANTHROPIC_API_KEY

# Test Claude Code directly
cd ~/Code/clawk-ios
claude "What files are in this project?"

# Check OpenClaw ACP config
openclaw acp client
```

### "Agent can't find the project"

Make sure the agent is pointed at the right directory. In your message, be explicit:

> "In the ~/Code/clawk-ios project, add a new view..."

Or set the default working directory in OpenClaw config.

### "Agent made changes but didn't push"

```bash
cd ~/Code/clawk-ios
git status
git log --oneline -5

# If changes are committed but not pushed:
git push origin HEAD

# If changes are uncommitted:
git add .
git commit -m "Agent changes"
git push
```

---

## Build Issues

### "xcodebuild fails — no scheme found"

The project needs an .xcodeproj or .xcworkspace. If you only have Swift files:

```bash
# Open Xcode and create a project wrapping the existing files
open -a Xcode ~/Code/clawk-ios/

# Or use swift package:
cd ~/Code/clawk-ios
swift package init --type executable
```

### "Build fails — module not found"

Common with SwiftData or other system frameworks:

```bash
# Make sure Xcode CLI tools point to the right Xcode
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer

# Verify
xcode-select -p
```

### "Signing errors in local build"

XcodeBuildMCP builds for simulator by default, which doesn't need signing. If you see signing errors:

```bash
# Build for simulator explicitly
xcodebuild -scheme Clawk -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

Xcode Cloud handles real device signing automatically.

### "Build succeeds locally but fails on Xcode Cloud"

Common causes:
1. **Missing files** — something wasn't committed. Run `git status` and commit everything.
2. **Hardcoded paths** — no absolute paths in the project.
3. **macOS version mismatch** — Xcode Cloud runs latest stable macOS.
4. **Swift version** — check `.swift-version` or Package.swift matches.

Check the Xcode Cloud build log in App Store Connect for the specific error.

---

## Xcode Cloud Issues

### "Build stuck in 'Waiting for review' on TestFlight"

This is the export compliance issue. Fix:

1. Add to Info.plist:
   ```xml
   <key>ITSAppUsesNonExemptEncryption</key>
   <false/>
   ```

2. Commit and push:
   ```bash
   git add Info.plist
   git commit -m "Add export compliance flag for automated TestFlight"
   git push
   ```

3. Or set it in App Store Connect → App → General → Export Compliance → "No"

### "Xcode Cloud workflow not triggering"

1. Check the workflow is active in App Store Connect → Xcode Cloud
2. Verify the branch trigger matches your push branch
3. Check GitHub connection is still authorized in Xcode Cloud settings
4. Look at recent builds — there might be a queue

### "Running out of Xcode Cloud compute hours"

You get 25 hrs/month free. Each build takes 5-15 min. At ~10 min per build, that's ~150 builds/month.

To conserve:
- Only trigger on `main` (not every branch push)
- Batch changes before merging instead of many small merges
- Check usage: App Store Connect → Xcode Cloud → Usage

---

## Connectivity Issues

### "Can't reach Mac mini from phone"

```bash
# On Mac mini, check Tailscale
tailscale status

# Verify the Mac mini is online in Tailscale admin
# https://login.tailscale.com/admin/machines

# From phone, try pinging the Mac mini
# (use Tailscale app or terminal app)
ping your-mac-mini.tailnet
```

### "Clawk app can't connect to gateway"

1. Check `Config.swift` has the correct Tailscale IP/hostname
2. Verify OpenClaw gateway is running on the Mac mini: `openclaw status`
3. Check port 18789 is accessible: `nc -z mac-mini-host 18789`
4. Check the Clawk app logs (Debug Logs panel in the app)

### "WebSocket keeps disconnecting"

The app has auto-reconnect (3 second delay). If it's constantly cycling:
1. OpenClaw gateway might be crashing — check `openclaw logs`
2. Network might be flaky — check Tailscale connection
3. The heartbeat might be failing — the app pings every 30s

---

## Git Issues

### "Merge conflicts"

If the agent and you both made changes:

```bash
cd ~/Code/clawk-ios
git fetch origin
git merge origin/main

# Fix conflicts manually, or ask the agent:
# "There are merge conflicts in ContentView.swift — resolve them keeping both the new settings button and the updated layout"
```

### "Wrong branch"

```bash
git checkout main
git pull

# Or ask the agent:
# "Switch to main branch and pull latest"
```

---

## Quick diagnostics checklist

When something's not working, run through this:

```bash
# 1. Is the Mac mini reachable?
tailscale ping your-mac-mini

# 2. Is OpenClaw running?
ssh your-mac-mini "openclaw status"

# 3. Is Claude Code working?
ssh your-mac-mini "claude --version && echo \$ANTHROPIC_API_KEY | head -c 10"

# 4. Does the project build?
ssh your-mac-mini "cd ~/Code/clawk-ios && xcodebuild -scheme Clawk -sdk iphonesimulator build 2>&1 | tail -5"

# 5. Is git clean?
ssh your-mac-mini "cd ~/Code/clawk-ios && git status"

# 6. Is Xcode Cloud connected?
# Check App Store Connect → Xcode Cloud → Workflows
```
