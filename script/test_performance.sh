#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usagebar-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/UsagebarPerformanceTests.app"
mkdir -p "$TEST_APP/Contents/MacOS"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.usagebar.performance-tests</string>
<key>CFBundleExecutable</key><string>UsagebarPerformanceTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
# Join controller/test extensions for private fixture state without shipped test APIs.
cat "$ROOT_DIR/JustaUsageBar/ViewModels/UsageViewModel.swift" \
  "$ROOT_DIR/Tests/PerformanceRegressionTests.swift" > "$TEST_DIR/RefreshTests.swift"
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -O \
  "$ROOT_DIR/JustaUsageBar/Models/DisplayProvider.swift" \
  "$ROOT_DIR/JustaUsageBar/Models/UsageData.swift" \
  "$ROOT_DIR/JustaUsageBar/Models/UsageRefreshPolicy.swift" \
  "$ROOT_DIR/JustaUsageBar/Services/KeychainTool.swift" \
  "$ROOT_DIR/JustaUsageBar/Services/ProviderActor.swift" \
  "$ROOT_DIR/JustaUsageBar/Services/ProviderHTTP.swift" \
  "$ROOT_DIR/JustaUsageBar/Services/RepeatingTimer.swift" \
  "$ROOT_DIR/Tests/ProviderFixtures.swift" \
  "$TEST_DIR/RefreshTests.swift" \
  -o "$TEST_APP/Contents/MacOS/UsagebarPerformanceTests"
"$TEST_APP/Contents/MacOS/UsagebarPerformanceTests"

# Compile the real renderers and services. Join controller/test extensions in one
# source file for private-state assertions; no production code is rewritten.
cat "$ROOT_DIR/JustaUsageBar/ViewModels/UsageViewModel.swift" \
  "$ROOT_DIR/JustaUsageBar/Views/AppDelegate.swift" \
  "$ROOT_DIR/Tests/StatusRenderingTests.swift" > "$TEST_DIR/RenderingTests.swift"
# Use the built asset catalog when CI has compiled the app, so previews include
# the same provider marks as the shipped panel.
assets="$ROOT_DIR/build/DerivedData/Build/Products/Release/Usagebar.app/Contents/Resources/Assets.car"
if [[ -f "$assets" ]]; then
  mkdir -p "$TEST_APP/Contents/Resources"
  cp "$assets" "$TEST_APP/Contents/Resources/Assets.car"
fi
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -O \
  "$ROOT_DIR"/JustaUsageBar/Models/*.swift \
  "$ROOT_DIR"/JustaUsageBar/Services/*.swift \
  "$ROOT_DIR/JustaUsageBar/Views/AuthWebView.swift" \
  "$ROOT_DIR/JustaUsageBar/Views/PopoverView.swift" \
  "$ROOT_DIR/JustaUsageBar/Views/SettingsView.swift" \
  "$ROOT_DIR/JustaUsageBar/Views/UsagePanelView.swift" \
  "$TEST_DIR/RenderingTests.swift" \
  -o "$TEST_APP/Contents/MacOS/UsagebarPerformanceTests"
"$TEST_APP/Contents/MacOS/UsagebarPerformanceTests"
