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
    Sources/EditKeysWindow.swift \
    Sources/KeyAction.swift \
    Sources/ActionRunner.swift \
    Sources/HotKeyManager.swift \
    Sources/MediaKeys.swift \
    Sources/WindowManager.swift \
    Sources/ClipboardFilter.swift \
    Sources/ClipboardHistory.swift \

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
    Sources/EditKeysWindow.swift \
    Sources/KeyAction.swift \
    Sources/ActionRunner.swift \
    Sources/HotKeyManager.swift \
    Sources/MediaKeys.swift \
    Sources/WindowManager.swift \
    Sources/ClipboardFilter.swift \
    Sources/ClipboardHistory.swift \

# Create Universal Binary
lipo -create -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

# Cleanup intermediate binaries
rm "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

# Copy Info.plist
cp Resources/Info.plist "$APP_BUNDLE/Contents/"

# Stable local signing: a self-signed cert in the login keychain gives every
# build the same designated requirement (certificate leaf), so macOS keeps the
# Accessibility / TCC grants across reinstalls. Falling back to ad-hoc makes
# TCC see a new app each build and the user must re-grant every time.
SIGN_ID="bttopn Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    codesign --force --sign "$SIGN_ID" "$APP_BUNDLE"
    echo "🔏 Signed with '$SIGN_ID' (TCC grants persist across rebuilds)"
else
    codesign --force --sign - "$APP_BUNDLE"
    echo "⚠️  '$SIGN_ID' not found in keychain — signed ad-hoc;"
    echo "    Accessibility will need re-granting after each reinstall."
    echo "    See README → Local Compilation for how to create it."
fi

echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "First launch: Grant Accessibility in System Settings → Privacy & Security → Accessibility"
