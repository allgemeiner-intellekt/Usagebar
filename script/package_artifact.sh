#!/bin/bash
set -euo pipefail

app="build/DerivedData/Build/Products/Release/Usagebar.app"
output="build/Artifact"
test -d "$app"
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/Usagebar")"
case " $architectures " in *" arm64 "*) ;; *) echo 'Missing arm64 architecture' >&2; exit 1 ;; esac
case " $architectures " in *" x86_64 "*) ;; *) echo 'Missing x86_64 architecture' >&2; exit 1 ;; esac
codesign --verify --deep --strict "$app"
mkdir -p "$output"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Usagebar.zip"
{
    echo "commit=$(git rev-parse HEAD)"
    echo "tree=$(git rev-parse 'HEAD^{tree}')"
    echo "run=${GITHUB_SERVER_URL:?}/${GITHUB_REPOSITORY:?}/actions/runs/${GITHUB_RUN_ID:?}"
    echo "architectures=$architectures"
    python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as handle:
    info = plistlib.load(handle)
print(f"version={info['CFBundleShortVersionString']}")
print(f"build={info['CFBundleVersion']}")
PY
} > "$output/build-info.txt"
cd "$output"
shasum -a 256 Usagebar.zip build-info.txt > SHA256SUMS
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo '## Personal build'
        echo '```text'
        cat build-info.txt
        echo '```'
        echo "[Download artifacts](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}#artifacts)"
    } >> "$GITHUB_STEP_SUMMARY"
fi
