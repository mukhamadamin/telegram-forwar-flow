#!/usr/bin/env bash
# Builds and runs the UIKit demo in the iOS Simulator without an Xcode project:
#   Demo/build-demo.sh ["iPhone 18 Pro"]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-iPhone 18 Pro}"
OUT="${OUT:-build}"
APP="$OUT/ForwardFlowDemo.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
rm -rf "$APP" && mkdir -p "$APP"

xcrun -sdk iphonesimulator metal -c ForwardFlow/Resources/ForwardFlow.metal -o "$OUT/ForwardFlow.air"
xcrun -sdk iphonesimulator metallib "$OUT/ForwardFlow.air" -o "$APP/default.metallib"
xcrun -sdk iphonesimulator swiftc -O -parse-as-library -module-name ForwardFlowDemo -target "$ARCH-apple-ios17.0-simulator" -sdk "$SDK" \
  ForwardFlow/Sources/ForwardFlowTimeline.swift ForwardFlow/Sources/ForwardFlowAnimator.swift \
  Demo/DemoViewController.swift -o "$APP/ForwardFlowDemo"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>demo.forwardflow.kit</string>
  <key>CFBundleExecutable</key><string>ForwardFlowDemo</string>
  <key>CFBundleName</key><string>ForwardFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
  </dict>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --terminate-running-process "$DEVICE" demo.forwardflow.kit
