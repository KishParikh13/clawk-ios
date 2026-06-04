#!/bin/bash

# Deploy Clawk backend to Railway
# Run this from your Mac

cd "$(dirname "$0")/backend"

echo "🚀 Deploying Clawk backend to Railway..."
echo ""

# Check if railway CLI is installed
if ! command -v railway &> /dev/null; then
    echo "Installing Railway CLI..."
    npm install -g @railway/cli
fi

# Login (will open browser)
echo "Step 1: Login to Railway"
railway login

# Initialize project
echo ""
echo "Step 2: Initialize project"
railway init

# Deploy
echo ""
echo "Step 3: Deploy!"
railway up

# Get the URL
echo ""
echo "Step 4: Getting your permanent URL..."
sleep 5
railway domain

echo ""
echo "✅ Done! Update Config.swift with the URL above."
echo ""
echo "Then rebuild the iOS app: open Clawk.xcodeproj and hit ⌘R"
