#!/bin/bash
set -euo pipefail

app="build/DerivedData/Build/Products/Release/Usagebar.app"
output="build/Artifact"
test -d "$app"
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/Usagebar")"
[[ " $architectures " == *" arm64 "* ]]
[[ " $architectures " == *" x86_64 "* ]]
codesign --verify --deep --strict "$app"
mkdir -p "$output"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Usagebar.zip"
{
    echo "commit=$(git rev-parse HEAD)"
    echo "run=${GITHUB_SERVER_URL:?}/${GITHUB_REPOSITORY:?}/actions/runs/${GITHUB_RUN_ID:?}"
    echo "architectures=$architectures"
    echo "version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    echo "build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
} > "$output/build-info.txt"
cd "$output"
shasum -a 256 Usagebar.zip build-info.txt > SHA256SUMS
