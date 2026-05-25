# Research Notes — Phone-to-TestFlight Pipeline

Reference material collected during research. Useful for future agents picking up this project.

---

## Key resources

### Guides and tutorials
- **claude-code-ios-dev-guide** — https://github.com/keskinonur/claude-code-ios-dev-guide
  Complete setup guide for Claude Code + iOS development. Templates for .claude/settings.json, CLAUDE.md, and XcodeBuildMCP integration. Good reference for agent skills in Swift/SwiftUI.

- **Thomas Ricouard's Codex → TestFlight guide** — https://dimillian.medium.com/how-to-deploy-testflight-app-from-codex-web-automatically-1de715248269
  Real-world case study using the Ice Cubes app (open-source Mastodon client). Shows how cloud agent → PR → Xcode Cloud → TestFlight works end to end.

- **Mac mini + OpenClaw setup guide** — https://github.com/guglielmofonda/mac-mini-openclaw-guide
  Complete guide for running OpenClaw + Claude Code on a Mac mini. Covers Slack, Telegram, WhatsApp, cron automation, MCP servers.

- **Two MCP Servers Made Claude Code an iOS Build System** — https://blakecrosley.com/blog/xcode-mcp-claude-code
  Practical walkthrough of XcodeBuildMCP + Apple's native Xcode MCP for complete iOS build automation.

### Tools
- **XcodeBuildMCP** — https://github.com/getsentry/XcodeBuildMCP / https://www.xcodebuildmcp.com
  MCP server with 82 tools for headless Xcode builds, simulators, real device deployment, LLDB debugging. Works without Xcode running. Key component for agent-driven iOS builds.

- **OpenClaw** — https://github.com/openclaw/openclaw / https://docs.openclaw.ai
  Open-source AI assistant gateway. Connects messaging apps to LLMs. ACP (Agent Communication Protocol) lets you spawn Claude Code sessions from chat messages.

- **Omnara** — https://www.omnara.com / App Store
  YC S25 company. iOS app for controlling Claude Code remotely. Features: voice coding, diff review, localhost preview, agent orchestration. Alternative to OpenClaw for mobile agent control.

### Community discussions
- **Reddit: Building entirely on phone with Claude** — https://www.reddit.com/r/ClaudeAI/comments/1prdrpe/
  Key insight: must add ITSAppUsesNonExemptEncryption = NO to Info.plist for seamless TestFlight deployment.

- **Hacker News: Omnara launch** — https://news.ycombinator.com/item?id=44878650
  Discussion about running Claude Code from anywhere.

---

## XcodeBuildMCP details

XcodeBuildMCP (v2.3.2) provides 82 MCP tools organized into categories:

**Build & compile:**
- Build for simulator or device
- Incremental builds via xcodemake integration
- Clean builds
- Archive for distribution

**Testing:**
- Run unit tests
- Run UI tests
- Test result parsing

**Simulators:**
- List available simulators
- Boot/shutdown simulators
- Install and launch apps
- Take screenshots

**Real devices:**
- Deploy to connected devices
- Device management

**Debugging:**
- LLDB integration
- Breakpoints
- Variable inspection
- Memory debugging

**Project management:**
- List schemes, targets, configurations
- Modify build settings
- Add/remove files

The MCP server runs via npx — no separate install needed:
```json
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest"]
    }
  }
}
```

---

## Xcode Cloud details

### Pricing (as of 2026)
- **Free tier:** 25 compute hours/month (included with Apple Developer Program)
- Paid tiers: 100 hrs ($49.99), 250 hrs ($99.99), 1000 hrs ($399.99)
- One compute hour ≈ 6 builds at ~10 min each

### What it handles automatically
- Code signing (uses your Apple Developer account credentials)
- Provisioning profiles
- Build environment (macOS + Xcode version)
- TestFlight distribution
- App Store submission (if configured)

### Workflow triggers
- Branch changes (e.g., push to `main`)
- Pull request (build on PR open/update)
- Tag (build on version tags)
- Scheduled (daily/weekly builds)
- Manual (trigger from App Store Connect)

### Limitations
- Requires GitHub/GitLab/Bitbucket (no self-hosted git)
- Build environment is fixed (latest stable macOS/Xcode, or specific versions)
- No custom build scripts beyond what Xcode supports (ci_scripts/)
- Queue times can be 5-10 min during peak hours

---

## OpenClaw ACP (Agent Communication Protocol)

How OpenClaw spawns Claude Code sessions:

1. User sends message to OpenClaw via any channel
2. OpenClaw's acp-router skill detects coding intent
3. Calls `sessions_spawn` with `runtime: "acp"` and `agentId: "claude"`
4. Session is bound to the thread (persistent context)
5. Claude Code runs in the project directory
6. Results stream back through the same thread
7. User can continue iterating in the same conversation

Key commands:
```bash
# Interactive CLI
openclaw acp client

# Send message directly to a session
openclaw acp --session main:main --message "Build the project"

# List active sessions
openclaw acp sessions

# Check gateway health
openclaw health
```

---

## Alternative approaches considered

### GitHub Actions + Fastlane (not chosen)
- More control but significantly more setup
- Need to manage certificates, provisioning profiles, match
- Free tier: 2000 min/month but macOS runners burn 10x = ~200 min effective
- Base64-encode distribution certificate, store as GitHub secret
- More moving parts to break

### Self-hosted CI (not chosen)
- Could run Fastlane directly on Mac mini
- Eliminates cloud dependency but adds maintenance burden
- No benefit over Xcode Cloud for a single developer

### Omnara instead of OpenClaw (viable alternative)
- More polished mobile experience
- Voice coding mode
- Diff review in-app
- But: closed source, subscription cost, less customizable
- Good complement to OpenClaw rather than replacement
