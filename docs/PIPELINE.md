# Daily Workflow — Phone to TestFlight

## The 4-step loop

Once setup is complete (see SETUP.md), your daily workflow is:

### 1. Prompt from your phone

Send a message to OpenClaw from wherever you are:

**Via messaging (iMessage/WhatsApp/etc):**
> "Add a settings screen to clawk-ios with options for gateway host, port, and dark mode toggle"

**Via Clawk app (richer experience):**
Open Clawk → Gateway Chat → type the same prompt. You'll see thinking steps and tool calls in real time.

**Via Omnara (if installed):**
Open Omnara → voice or text prompt. You get diff previews and can approve changes from the app.

### 2. Agent works

Claude Code runs on your Mac mini:
1. Reads the codebase and CLAUDE.md
2. Plans the changes
3. Writes SwiftUI code
4. Builds via XcodeBuildMCP (catches compile errors)
5. Runs tests if they exist
6. Commits to a branch: `agent/settings-screen`
7. Pushes and opens a PR
8. Messages you back with the PR link

You can watch this happen in real-time if using Clawk or Omnara.

### 3. Review and merge

Open GitHub mobile app:
1. Check the PR diff (the agent should have a clean, focused changeset)
2. Tap "Merge pull request"
3. That's it — Xcode Cloud takes over

### 4. Install from TestFlight

15-30 minutes after merge:
1. You get a push notification from TestFlight
2. Open TestFlight → Install
3. Test the new feature on your phone

---

## Prompt tips for best results

### Be specific about what you want

Good:
> "Add a settings screen accessible from the dashboard tab. Include fields for gateway host (text input, default localhost), gateway port (number input, default 18789), and a dark mode toggle. Save settings to UserDefaults."

Less good:
> "Add settings"

### Reference existing patterns

> "Add a new tab called Settings, following the same pattern as DashboardView. Use the existing Config.swift for any new configuration values."

### Ask for multiple things in sequence

> "First, add a settings screen. Then update Config.swift to read the gateway host from UserDefaults instead of hardcoding localhost. Then update GatewayConnection to use the new config values."

### Ask the agent to test

> "Add the settings screen, build it, and test that the app launches in the simulator without crashes"

### Branch without deploying

> "Make the changes on a branch called agent/settings but don't merge to main — I want to review first"

---

## Starting a new app from scratch

You can use this same pipeline for any new iOS app:

1. Message OpenClaw:
   > "Create a new SwiftUI iOS app called 'MyApp' in ~/Code/my-app. It should be a simple CRUD app for tracking daily habits. Set up the project with SwiftData, add a CLAUDE.md, and push to GitHub."

2. Then go to App Store Connect and connect the new repo to Xcode Cloud (one-time step per app).

3. After that, the same prompt → build → merge → TestFlight loop works.

---

## Working with the agent across sessions

The agent starts fresh each session but reads CLAUDE.md for context. If you want it to remember something specific:

> "Add a note to CLAUDE.md that the settings screen stores values in UserDefaults with the prefix 'clawk_'"

This persists across sessions because it's committed to the repo.

---

## Emergency: fixing a broken build

If Xcode Cloud fails:

1. Check the build log in App Store Connect → Xcode Cloud → Recent Builds
2. Message the agent with the error:
   > "The Xcode Cloud build failed with: [paste error]. Fix it and push again."

3. If the agent can't fix it, SSH into your Mac mini via Tailscale and debug manually:
   ```bash
   ssh your-mac-mini.tailnet
   cd ~/Code/clawk-ios
   xcodebuild -scheme Clawk -sdk iphonesimulator build 2>&1 | tail -20
   ```
