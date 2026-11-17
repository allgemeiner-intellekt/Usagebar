import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("scope", SCRIPT / "ci_scope.py")
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def test_infrastructure_changes_skip_app_build(self):
        self.assertFalse(scope.needs_app_build([
            ".github/workflows/ci.yml", "script/update_personal.py", "script/package_artifact.sh",
            "script/tests/test_ci_and_packaging.py", "docs/RELEASING.md", ".agents/skills/cloud-build/SKILL.md",
        ]))

    def test_app_tests_project_and_unknown_inputs_require_build(self):
        for path in ("JustaUsageBar/Views/AppDelegate.swift", "JustaUsageBar.xcodeproj/project.pbxproj",
                     "Tests/StatusRenderingTests.swift", "script/test_performance.sh", "new-build-config"):
            with self.subTest(path=path):
                self.assertTrue(scope.needs_app_build(["README.md", path]))


class PackagingTests(unittest.TestCase):
    def package(self, archs="arm64 x86_64", signature_status="0"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            contents = root / "build/DerivedData/Build/Products/Release/Usagebar.app/Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "MacOS/Usagebar").write_bytes(b"fixture executable")
            with (contents / "Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"}, handle)
            binaries = root / "bin"
            binaries.mkdir()
            fixtures = {
                "xcrun": '#!/bin/sh\necho "$FIXTURE_ARCHS"\n',
                "codesign": '#!/bin/sh\nexit "$FIXTURE_SIGNATURE_STATUS"\n',
                "git": '#!/bin/sh\nif [ "$2" = HEAD ]; then printf "%s\\n" ' + "a" * 40 + '; else printf "%s\\n" ' + "b" * 40 + '; fi\n',
                "ditto": '#!/usr/bin/env python3\nimport pathlib, sys\npathlib.Path(sys.argv[-1]).write_bytes(b"fixture zip")\n',
            }
            for name, text in fixtures.items():
                tool = binaries / name
                tool.write_text(text)
                tool.chmod(0o755)
            summary = root / "summary.md"
            env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                       FIXTURE_ARCHS=archs, FIXTURE_SIGNATURE_STATUS=signature_status,
                       GITHUB_SERVER_URL="https://github.com", GITHUB_REPOSITORY="allgemeiner-intellekt/Usagebar",
                       GITHUB_RUN_ID="123", GITHUB_STEP_SUMMARY=str(summary))
            result = subprocess.run(["bash", str(SCRIPT / "package_artifact.sh")], cwd=root, env=env,
                                    capture_output=True, text=True)
            artifact = root / "build/Artifact"
            if result.returncode == 0:
                subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=artifact, check=True, capture_output=True)
                return result.returncode, (artifact / "build-info.txt").read_text(), summary.read_text()
            self.assertFalse((artifact / "Usagebar.zip").exists())
            return result.returncode, "", ""

    def test_metadata_checksums_and_summary(self):
        status, info, summary = self.package()
        self.assertEqual(status, 0)
        for expected in ("commit=" + "a" * 40, "tree=" + "b" * 40, "version=1.2.3", "build=45"):
            self.assertIn(expected, info)
        self.assertIn("/actions/runs/123#artifacts", summary)

    def test_invalid_signature_and_missing_architecture_stop_packaging(self):
        self.assertNotEqual(self.package(signature_status="1")[0], 0)
        self.assertNotEqual(self.package(archs="arm64")[0], 0)


if __name__ == "__main__":
    unittest.main()
