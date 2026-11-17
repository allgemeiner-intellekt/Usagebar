#!/usr/bin/env python3
"""Choose a full app build for app inputs and conservatively for unknown paths."""

from pathlib import PurePosixPath
import subprocess
import sys


def needs_app_build(paths):
    for path in paths:
        if path.startswith(("JustaUsageBar/", "JustaUsageBar.xcodeproj/", "Tests/")):
            return True
        if path.startswith((".github/", ".agents/", "docs/", "script/tests/")):
            continue
        if path in {".gitignore", "script/update_personal.py", "script/ci_scope.py", "script/package_artifact.sh"}:
            continue
        if len(PurePosixPath(path).parts) == 1 and path.endswith(".md"):
            continue
        return True
    return False


if __name__ == "__main__":
    changed = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", "-z", sys.argv[1], sys.argv[2]])
    print("true" if needs_app_build([p for p in changed.decode().split("\0") if p]) else "false")
