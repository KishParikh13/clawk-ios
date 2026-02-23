# Clawk iOS — Quick Start

## 1. Clone and Setup

```bash
git clone https://github.com/kish2576/clawk-ios.git
cd clawk-ios
```

## 2. Deploy Backend to Railway

```bash
cd backend
railway login
railway init
railway up
```

Get your domain:
```bash
railway domain
# → https://clawk-production.up.railway.app
```

## 3. Update iOS Config

Edit `Clawk/Clawk/Config.swift`:
```swift
static let baseURL = "https://your-app.up.railway.app"
```

## 4. Generate Xcode Project

```bash
./generate-project.sh
```

Or manually:
```bash
cd Clawk
xcodegen generate
```

## 5. Run on Device

```bash
open Clawk/Clawk.xcodeproj
```

- Select your iPhone as target
- Hit Run (⌘R)
- App will auto-pair on first launch

## 6. Send a Test Message

```bash
curl -X POST https://your-app.up.railway.app/message \
  -H "Content-Type: application/json" \
  -H "x-device-token: your-device-token-from-app" \
  -d '{
    "message": "Hello from OpenClaw!",
    "actions": ["👍", "👎", "Dismiss"]
  }'
```

Get your device token from the app logs in Xcode.

## Tailscale Setup (Optional but Recommended)

For fully private networking:

1. Install Tailscale on iPhone
2. Install Tailscale on Railway:
   ```bash
   railway add --plugin tailscale
   ```
3. Or run relay on a local machine with Tailscale
4. Update `Config.swift` to use Tailscale IP:
   ```swift
   static let baseURL = "http://100.x.x.x:3000"
   ```

## Project Structure

```
├── backend/           # Node.js relay service
│   ├── server.js      # WebSocket + REST API
│   └── package.json
├── Clawk/             # SwiftUI iOS app
│   ├── Clawk/
│   │   ├── ClawkApp.swift      # App entry
│   │   ├── ContentView.swift   # Main UI
│   │   ├── MessageStore.swift  # WebSocket + state
│   │   └── Config.swift        # Your settings
│   └── project.yml    # XcodeGen config
├── generate-project.sh
└── README.md
```

## What's Working

- ✅ WebSocket real-time connection
- ✅ Auto-pairing on first launch
- ✅ Card UI with buttons
- ✅ Message history
- ✅ Connection status indicator
- ✅ Response tracking

## Next Up

- [ ] Push notifications (APNs)
- [ ] Rich media (images in messages)
- [ ] Quick actions from lock screen
- [ ] Siri shortcuts

## Troubleshooting

**App can't connect?**
- Check Railway URL in Config.swift
- Ensure device is paired (POST to /pair)
- Check Xcode console for WebSocket errors

**Messages not appearing?**
- Verify device token matches
- Check relay logs: `railway logs`

**WebSocket disconnects?**
- Normal on background — app reconnects on foreground
- For persistent connection, enable Background Mode (coming soon)
