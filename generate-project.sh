#!/bin/bash

# Generate Xcode project for Clawk iOS app
# Run this after cloning the repo

echo "Generating Clawk.xcodeproj..."

# Check if xcodegen is installed
if ! command -v xcodegen &> /dev/null; then
    echo "Installing xcodegen..."
    brew install xcodegen
fi

cd Clawk
xcodegen generate

echo ""
echo "✅ Generated Clawk.xcodeproj"
echo "Open with: open Clawk.xcodeproj"
