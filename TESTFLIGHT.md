# Clawk iOS — TestFlight Setup

## Prerequisites

1. **Apple Developer Account** ($99/year)
   - Enroll at https://developer.apple.com

2. **App ID Registration**
   - Go to https://developer.apple.com/account/resources/identifiers/list
   - Register new App ID: `com.kishparikh.clawk`
   - Enable Push Notifications capability

3. **App Store Connect**
   - Go to https://appstoreconnect.apple.com
   - Create new app: Clawk
   - Bundle ID: `com.kishparikh.clawk`

## Setup Steps

### 1. Configure Fastlane

Edit `fastlane/Appfile`:
```ruby
apple_id("your-apple-id@icloud.com")
team_id("YOUR_TEAM_ID")  # From Apple Developer portal
app_identifier("com.kishparikh.clawk")
```

### 2. Set Up Certificates (Match - Recommended)

Create a private repo for certificates:
```bash
# Create empty private repo on GitHub called 'clawk-certificates'
# Then run:
bundle exec fastlane match init
```

Or manual certificates:
```bash
fastlane match appstore
fastlane match development
```

### 3. App Store Connect API Key (Recommended)

Instead of Apple ID + 2FA, use API key:

1. Go to App Store Connect → Users and Access → Keys
2. Generate new key with "App Manager" role
3. Download the .p8 file
4. Place in `fastlane/AuthKey_XXX.p8`
5. Edit `fastlane/Matchfile` with your key ID and issuer ID

### 4. Build and Upload

```bash
# First time - set up certificates
fastlane match appstore

# Build and upload to TestFlight
fastlane beta
```

## Quick Build (Simulator/Device Testing)

If you just want to test on your device without TestFlight:

```bash
# Build for development
fastlane build

# Then in Xcode:
# - Open Clawk.xcodeproj
# - Connect your iPhone
# - Select your device as target
# - Hit Run
```

## Troubleshooting

**"No code signing identities found"**
- Run `fastlane match development` or `fastlane match appstore`

**"Invalid team ID"**
- Check your team ID at https://developer.apple.com/account/#!/membership

**"App ID not found"**
- Register the bundle ID in Apple Developer portal first

**2FA Issues**
- Use App Store Connect API Key instead (recommended)
- Or set up FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD

## Alternative: Manual Xcode Upload

If Fastlane gives you trouble:

1. Open `Clawk.xcodeproj` in Xcode
2. Select target → Signing & Capabilities
3. Select your team
4. Product → Archive
5. Distribute App → App Store Connect → Upload
6. Wait for processing (~10-30 min)
7. Add to TestFlight in App Store Connect

## TestFlight Testing

Once uploaded:

1. Go to https://appstoreconnect.apple.com
2. Select Clawk → TestFlight
3. Add yourself as internal tester
4. Download TestFlight app on iPhone
5. Accept invitation and install Clawk
