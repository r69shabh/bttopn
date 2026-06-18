#!/bin/bash
set -e

APP_NAME="bttopn"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile Swift sources for Apple Silicon (arm64)
swiftc \
    -target arm64-apple-macosx14.0 \
    -o "$BUILD_DIR/${APP_NAME}_arm64" \
    -import-objc-header Sources/TouchBarPrivateApi.h \
    -framework AppKit \
    -framework Carbon \
    -F /System/Library/PrivateFrameworks \
    -framework DFRFoundation \
    -suppress-warnings \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/TouchBarManager.swift \
    Sources/KeySimulator.swift \
    Sources/ConfigManager.swift \
    Sources/KeyCodes.swift \
    Sources/EditKeysWindow.swift

# Compile Swift sources for Intel (x86_64)
swiftc \
    -target x86_64-apple-macosx14.0 \
    -o "$BUILD_DIR/${APP_NAME}_x86_64" \
    -import-objc-header Sources/TouchBarPrivateApi.h \
    -framework AppKit \
    -framework Carbon \
    -F /System/Library/PrivateFrameworks \
    -framework DFRFoundation \
    -suppress-warnings \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/TouchBarManager.swift \
    Sources/KeySimulator.swift \
    Sources/ConfigManager.swift \
    Sources/KeyCodes.swift \
    Sources/EditKeysWindow.swift

# Create Universal Binary
lipo -create -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

# Cleanup intermediate binaries
rm "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

# Copy Info.plist
cp Resources/Info.plist "$APP_BUNDLE/Contents/"

# Ad-hoc code sign
codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "First launch: Grant Accessibility in System Settings → Privacy & Security → Accessibility"
