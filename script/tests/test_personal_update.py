import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("update", Path(__file__).parents[1] / "update_personal.py")
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)

SOURCE = "a" * 40
TREE = "b" * 40
URL = f"https://github.com/{update.REPO}/actions/runs/123"


def package(folder, tree=True):
    (folder / "Usagebar.zip").write_bytes(b"app fixture")
    info = f"commit={SOURCE}\nrun={URL}\narchitectures=arm64 x86_64\nversion=1.0\nbuild=1\n"
    if tree:
        info += f"tree={TREE}\n"
    (folder / "build-info.txt").write_text(info)
    (folder / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256((folder / name).read_bytes()).hexdigest()}  {name}\n"
        for name in ("Usagebar.zip", "build-info.txt")))


class ArtifactTests(unittest.TestCase):
    def test_checksums_and_old_manifest_compatibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            package(folder, tree=False)
            self.assertEqual(update.verify_artifact(folder, SOURCE, TREE, URL)["commit"], SOURCE)
            (folder / "Usagebar.zip").write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                update.verify_artifact(folder, SOURCE, TREE, URL)

    def test_wrong_source_tree_and_run_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            package(folder)
            for source, tree, url in (("c" * 40, TREE, URL), (SOURCE, "c" * 40, URL), (SOURCE, TREE, URL + "4")):
                with self.subTest(source=source, tree=tree, url=url), self.assertRaises(ValueError):
                    update.verify_artifact(folder, source, tree, url)

    def test_manifest_cannot_name_other_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            package(folder)
            with (folder / "SHA256SUMS").open("a") as handle:
                handle.write("a" * 64 + "  ../outside\n")
            with self.assertRaisesRegex(ValueError, "Invalid checksum"):
                update.verify_artifact(folder, SOURCE, TREE, URL)

    def test_selects_pr_merge_commit_instead_of_run_head(self):
        workflow = {"id": 123, "event": "pull_request", "head_sha": "different-pr-head",
                    "html_url": URL, "head_repository": {"full_name": update.REPO}}
        artifact = {"name": update.PREFIX + SOURCE, "expired": False}
        def fake_api(path):
            if path.startswith("actions/workflows/"):
                return {"workflow_runs": [workflow]}
            return {"artifacts": [artifact]}
        def download(*args, **kwargs):
            package(Path(args[args.index("--dir") + 1]))
        with tempfile.TemporaryDirectory() as tmp, patch.object(update, "api", side_effect=fake_api), \
                patch.object(update, "commit_info", return_value=(SOURCE, TREE)), \
                patch.object(update, "run", side_effect=download):
            output = Path(tmp) / "download"
            self.assertTrue(update.retrieve("d" * 40, TREE, output))
            self.assertEqual(json.loads((output / "selection.json").read_text())["source"], SOURCE)

    def test_fork_and_different_tree_are_not_reused(self):
        runs = [{"id": 123, "event": "pull_request", "html_url": URL,
                 "head_repository": {"full_name": "other/fork"}},
                {"id": 124, "event": "push", "html_url": URL,
                 "head_repository": {"full_name": update.REPO}}]
        def fake_api(path):
            if path.startswith("actions/workflows/"):
                return {"workflow_runs": runs}
            self.assertNotIn("/123/", path)
            return {"artifacts": [{"name": update.PREFIX + SOURCE, "expired": False}]}
        with tempfile.TemporaryDirectory() as tmp, patch.object(update, "api", side_effect=fake_api), \
                patch.object(update, "commit_info", return_value=(SOURCE, "c" * 40)), \
                patch.object(update, "run") as command:
            self.assertFalse(update.retrieve(SOURCE, TREE, Path(tmp)))
            command.assert_not_called()


class InstallTests(unittest.TestCase):
    def test_failed_launch_restores_previous_app_and_keeps_receipt_outside_bundle(self):
        self.check_rollback("launch failure")

    def test_missing_process_after_open_restores_previous_app(self):
        self.check_rollback("failed to start")

    def check_rollback(self, failure):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            destination = root / "Applications/Usagebar.app"
            destination.mkdir(parents=True)
            (destination / "old").write_text("previous app")
            folder = root / "download"
            folder.mkdir()
            package(folder)
            (folder / "selection.json").write_text("{}")
            launched = []
            def command(*args, **kwargs):
                if args[:3] == ("ditto", "-x", "-k"):
                    (Path(args[-1]) / "Usagebar.app").mkdir()
                elif args[:3] == ("ditto", "-c", "-k"):
                    Path(args[-1]).write_bytes(b"backup")
                elif args[0] == "open":
                    launched.append(Path(args[1]))
                    if len(launched) == 1 and failure == "launch failure":
                        raise RuntimeError("launch failure")
            real_exists = Path.exists
            def exists(path):
                # Isolate this test from the host's installed app and casks.
                if str(path).startswith(("/Applications/", "/opt/homebrew/Caskroom/", "/usr/local/Caskroom/")):
                    return False
                return real_exists(path)
            with patch.object(update.sys, "platform", "darwin"), patch.object(Path, "home", return_value=root), \
                    patch.object(Path, "exists", exists), patch.object(update, "run", side_effect=command), \
                    patch.object(update, "verify_app", return_value={"CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}), \
                    patch.object(update, "app_pids", side_effect=lambda app: [123] if not launched else []), \
                    patch.object(update.time, "sleep"), patch.object(update, "stop_app"):
                with self.assertRaisesRegex(RuntimeError, failure):
                    update.install(folder, destination)
            self.assertTrue((destination / "old").exists())
            self.assertFalse((destination / "build-info.txt").exists())
            self.assertEqual(launched, [destination, destination])
            self.assertTrue((root / "Library/Application Support/Usagebar/PersonalUpdates/previous-Usagebar.zip").exists())


class WaitTests(unittest.TestCase):
    def test_expired_successful_build_is_dispatched_again(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(update.sys, "argv", ["update", "--download-only", "--output", tmp]), \
                patch.object(update, "commit_info", return_value=(SOURCE, TREE)), \
                patch.object(update, "retrieve", side_effect=[False, True]), \
                patch.object(update, "api", return_value={"workflow_runs": [{"status": "completed", "conclusion": "success"}]}), \
                patch.object(update.time, "sleep"), patch.object(update, "run") as command:
            self.assertEqual(update.main(), 0)
            command.assert_called_once_with("gh", "workflow", "run", "ci.yml", "--repo", update.REPO, "--ref", "main")

    def test_failed_build_is_not_retried_automatically(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(update.sys, "argv", ["update", "--download-only", "--output", tmp]), \
                patch.object(update, "commit_info", return_value=(SOURCE, TREE)), \
                patch.object(update, "retrieve", return_value=False), \
                patch.object(update, "api", return_value={"workflow_runs": [{"status": "completed", "conclusion": "failure"}]}), \
                patch.object(update, "run") as command:
            with self.assertRaisesRegex(RuntimeError, "did not succeed"):
                update.main()
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
