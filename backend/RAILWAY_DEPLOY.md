# Clawk Backend — Quick Railway Deploy

## Option 1: One-Click Deploy (Easiest)

Coming soon — need to set up Railway template

## Option 2: CLI Deploy (Fast)

In terminal:

```bash
cd clawk-ios/backend

# 1. Login (opens browser)
railway login

# 2. Link to project (creates new if needed)
railway link

# 3. Deploy
railway up

# 4. Get URL
railway domain
```

## Option 3: GitHub Auto-Deploy (Best)

1. Push this repo to GitHub
2. Go to https://railway.app/new
3. Select "Deploy from GitHub repo"
4. Choose `clawk-ios`
5. Set root directory to `backend/`
6. Deploy!

## Environment Variables

None needed for basic operation.

Optional:
- `PORT` — defaults to 3000

## After Deploy

Update `Clawk/Clawk/Config.swift`:
```swift
static let baseURL = "https://your-app.up.railway.app"
```

Then rebuild iOS app (⌘R in Xcode).
