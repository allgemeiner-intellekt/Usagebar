#!/usr/bin/env python3
"""Retrieve a verified personal CI build, then optionally install it on macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

REPO = "allgemeiner-intellekt/Usagebar"
PREFIX = "Usagebar-macos-universal-"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def api(path):
    return json.loads(run("gh", "api", f"repos/{REPO}/{path}", capture_output=True).stdout)


def commit_info(ref):
    data = api(f"commits/{quote(ref, safe='')}")
    return data["sha"], data["commit"]["tree"]["sha"]


def verify_artifact(folder, source, tree, run_url):
    """Accept exactly the package's two checksums; never execute manifest text."""
    hashes = {}
    for line in (folder / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([a-f0-9]{64}) [ *](Usagebar\.zip|build-info\.txt)", line)
        if not match or match[2] in hashes:
            raise ValueError("Invalid checksum manifest")
        hashes[match[2]] = match[1]
    if set(hashes) != {"Usagebar.zip", "build-info.txt"}:
        raise ValueError("Incomplete checksum manifest")
    for name, expected in hashes.items():
        if hashlib.sha256((folder / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Checksum mismatch: {name}")
    info = dict(line.split("=", 1) for line in (folder / "build-info.txt").read_text().splitlines())
    if info.get("commit") != source or info.get("run") != run_url:
        raise ValueError("Artifact source/run mismatch")
    # Older builds predate the tree field. Their commit tree is checked via GitHub.
    if info.get("tree", tree) != tree:
        raise ValueError("Artifact source tree mismatch")
    if set(info.get("architectures", "").split()) != {"arm64", "x86_64"}:
        raise ValueError("Expected a universal app")
    return info


def retrieve(target, tree, output):
    # Bound the search to recent runs. Unmatched/expired builds fall back to a new build.
    runs = api("actions/workflows/ci.yml/runs?status=success&per_page=50")["workflow_runs"]
    commits = {}
    for workflow in runs:
        if workflow["event"] not in {"push", "pull_request", "workflow_dispatch"}:
            continue
        if (workflow.get("head_repository") or {}).get("full_name") != REPO:
            continue
        artifacts = api(f"actions/runs/{workflow['id']}/artifacts?per_page=100")["artifacts"]
        for artifact in artifacts:
            name = artifact["name"]
            if artifact["expired"] or not re.fullmatch(PREFIX + r"[a-f0-9]{40}", name):
                continue
            source = name[len(PREFIX):]
            if source not in commits:
                commits[source] = commit_info(source)[1]
            if commits[source] != tree:
                continue
            with tempfile.TemporaryDirectory(prefix="usagebar-artifact-") as tmp:
                folder = Path(tmp)
                run("gh", "run", "download", str(workflow["id"]), "--repo", REPO,
                    "--name", name, "--dir", tmp)
                info = verify_artifact(folder, source, tree, workflow["html_url"])
                output.mkdir(parents=True, exist_ok=True)
                for item in folder.iterdir():
                    if item.is_file():
                        shutil.copy2(item, output / item.name)
            receipt = {"target": target, "tree": tree, "source": source, "run": info["run"]}
            (output / "selection.json").write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt), flush=True)
            return True
    return False


def app_pids(app):
    expected = str(app / "Contents/MacOS/Usagebar")
    result = run("ps", "-ax", "-o", "pid=,comm=", capture_output=True)
    found = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == expected:
            found.append(int(parts[0]))
    return found


def stop_app(app):
    for pid in app_pids(app):
        os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        if not app_pids(app):
            return
        time.sleep(0.1)
    raise RuntimeError("Usagebar did not quit; installation cancelled")


def verify_app(app):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleExecutable") != "Usagebar":
        raise ValueError("Unexpected app executable")
    archs = run("lipo", "-archs", str(app / "Contents/MacOS/Usagebar"), capture_output=True).stdout
    if set(archs.split()) != {"arm64", "x86_64"}:
        raise ValueError("Installed app is not universal")
    return info


def install(folder, destination):
    if sys.platform != "darwin":
        raise RuntimeError("Installation requires macOS; use --download-only elsewhere")
    if destination.name != "Usagebar.app":
        raise ValueError("Destination must be named Usagebar.app")
    if destination.is_symlink():
        raise RuntimeError("Resolve the installed app symlink before updating")
    # Inspect only the relevant casks; unrelated untrusted taps must not block updates.
    for root in (Path("/opt/homebrew/Caskroom"), Path("/usr/local/Caskroom")):
        if any((root / name).exists() for name in ("usagebar", "justausagebar")):
            raise RuntimeError("Homebrew owns Usagebar. Resolve cask ownership first, preserving preferences.")
    alternate = Path.home() / "Applications/Usagebar.app"
    if alternate != destination and alternate.exists():
        raise RuntimeError(f"Another installed copy exists: {alternate}")
    if destination != Path("/Applications/Usagebar.app") and Path("/Applications/Usagebar.app").exists():
        raise RuntimeError("Another installed copy exists: /Applications/Usagebar.app")
    state = Path.home() / "Library/Application Support/Usagebar/PersonalUpdates"
    state.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".usagebar-update-", dir=destination.parent) as tmp:
        stage = Path(tmp)
        run("ditto", "-x", "-k", str(folder / "Usagebar.zip"), str(stage))
        fresh = stage / "Usagebar.app"
        info = verify_app(fresh)
        metadata = dict(line.split("=", 1) for line in (folder / "build-info.txt").read_text().splitlines())
        if str(info["CFBundleShortVersionString"]) != metadata["version"] or str(info["CFBundleVersion"]) != metadata["build"]:
            raise ValueError("App version differs from build metadata")
        existed = destination.exists()
        was_running = bool(app_pids(destination))
        if existed:
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(destination), str(stage / "previous.zip"))
            os.replace(stage / "previous.zip", state / "previous-Usagebar.zip")
        stop_app(destination)
        previous = stage / "previous.app"
        if existed:
            destination.rename(previous)
        try:
            fresh.rename(destination)
            verify_app(destination)
            run("open", str(destination))
            # Observe startup survival, rather than treating open's exit code as success.
            for _ in range(10):
                time.sleep(1)
                if app_pids(destination):
                    break
            else:
                raise RuntimeError("Updated Usagebar failed to start")
            for _ in range(5):
                time.sleep(1)
                if not app_pids(destination):
                    raise RuntimeError("Updated Usagebar exited during startup")
            for name in ("build-info.txt", "selection.json"):
                shutil.copy2(folder / name, state / name)
        except BaseException:
            stop_app(destination)
            if destination.exists():
                shutil.rmtree(destination)
            if existed:
                previous.rename(destination)
                if was_running:
                    run("open", str(destination))
            raise
    print(f"Installed {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) at {destination}")
    print(f"Source receipt and previous app archive: {state}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default="main", help="Target source ref, resolved once at startup")
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--no-wait", action="store_true", help="Exit 2 if no matching artifact exists")
    parser.add_argument("--output", type=Path, help="Keep downloaded artifact files here")
    parser.add_argument("--destination", type=Path, default=Path("/Applications/Usagebar.app"))
    args = parser.parse_args()
    target, tree = commit_info(args.commit)
    print(f"Target {target}, tree {tree}", flush=True)
    with tempfile.TemporaryDirectory(prefix="usagebar-update-") as tmp:
        output = args.output.resolve() if args.output else Path(tmp)
        if args.download_only and not args.output:
            parser.error("--download-only requires --output")
        deadline = time.monotonic() + 25 * 60
        dispatched = False
        while not retrieve(target, tree, output):
            if args.no_wait:
                print("No matching successful artifact", flush=True)
                return 2
            # Existing main CI is authoritative. For other refs, dispatch explicitly.
            runs = api(f"actions/workflows/ci.yml/runs?head_sha={target}&per_page=20")["workflow_runs"]
            active = [r for r in runs if r["status"] != "completed"]
            if not active:
                if runs:
                    raise RuntimeError("Target CI finished without a usable artifact. Inspect its result before retrying.")
                if not dispatched:
                    if commit_info(args.commit)[0] != target:
                        raise RuntimeError("Target ref moved before dispatch; rerun to select the new source.")
                    run("gh", "workflow", "run", "ci.yml", "--repo", REPO, "--ref", args.commit)
                    dispatched = True
                    print("Dispatched CI for the target ref", flush=True)
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out waiting for CI")
            if active:
                print(f"Waiting for {active[0]['html_url']}", flush=True)
            time.sleep(30)
        if not args.download_only:
            install(output, args.destination.expanduser().absolute())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Update failed: {error}", file=sys.stderr)
        sys.exit(1)
