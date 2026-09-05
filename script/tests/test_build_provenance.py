import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER_PATH = Path(__file__).resolve().parents[1] / "build_provenance.py"
SPEC = importlib.util.spec_from_file_location("build_provenance", HELPER_PATH)
assert SPEC and SPEC.loader
build_provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_provenance)


class BuildProvenanceTests(unittest.TestCase):
    def make_root(self, parent: Path) -> Path:
        root = parent / "repo"
        (root / "Sources/App").mkdir(parents=True)
        (root / "Resources/Assets").mkdir(parents=True)
        (root / "script").mkdir()
        (root / "docs").mkdir()
        (root / "Package.swift").write_text("package", encoding="utf-8")
        (root / "Package.resolved").write_text("pins", encoding="utf-8")
        (root / "Sources/App/main.swift").write_text("source", encoding="utf-8")
        (root / "Resources/Assets/icon.txt").write_text("resource", encoding="utf-8")
        (root / "script/build_and_run.sh").write_text("build", encoding="utf-8")
        (root / "script/pack_icns.py").write_text("pack", encoding="utf-8")
        (root / "script/release.py").write_text("release", encoding="utf-8")
        (root / "docs/notes.md").write_text("docs", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "test"],
            check=True,
        )
        return root

    def test_runtime_sources_and_only_runtime_sources_change_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(Path(temporary))
            baseline = build_provenance.source_files(root)

            expected_paths = {
                "Package.swift",
                "Package.resolved",
                "Resources/Assets/icon.txt",
                "Sources/App/main.swift",
                "script/build_and_run.sh",
                "script/pack_icns.py",
            }
            self.assertEqual(set(baseline), expected_paths)

            for relative in expected_paths:
                path = root / relative
                original = path.read_text(encoding="utf-8")
                path.write_text(original + " changed", encoding="utf-8")
                self.assertNotEqual(baseline, build_provenance.source_files(root), relative)
                path.write_text(original, encoding="utf-8")

            (root / "docs/notes.md").write_text("changed docs", encoding="utf-8")
            (root / "script/release.py").write_text("changed release", encoding="utf-8")
            self.assertEqual(baseline, build_provenance.source_files(root))

    def test_snapshot_is_compact_sorted_and_verify_detects_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(Path(temporary))
            snapshot = Path(temporary) / "snapshot.json"
            build_provenance.write_snapshot(root, snapshot)
            raw = snapshot.read_text(encoding="utf-8")
            self.assertEqual(raw, json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":")) + "\n")
            self.assertNotIn(str(root), raw)
            build_provenance.verify_snapshot(root, snapshot)
            (root / "Sources/App/main.swift").write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "changed during the build"):
                build_provenance.verify_snapshot(root, snapshot)

    def test_missing_and_symlinked_runtime_inputs_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(Path(temporary))
            (root / "Package.resolved").unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                build_provenance.source_files(root)
            (root / "Package.resolved").write_text("pins", encoding="utf-8")
            target = root / "outside.swift"
            target.write_text("outside", encoding="utf-8")
            (root / "Sources/App/main.swift").unlink()
            (root / "Sources/App/main.swift").symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symlink"):
                build_provenance.source_files(root)

    def test_counter_preserves_legacy_floor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "current").write_text("7\n", encoding="utf-8")
            (directory / "legacy").write_text("41\n", encoding="utf-8")
            self.assertEqual(build_provenance.allocate_counter(directory, "current", "legacy"), 42)
            self.assertEqual((directory / "current").read_text(encoding="utf-8"), "42\n")

    def test_concurrent_counter_allocations_are_unique(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            command = [
                sys.executable,
                str(HELPER_PATH),
                "counter",
                "--directory",
                temporary,
                "--bundle-id",
                "current",
                "--legacy-id",
                "legacy",
            ]

            def allocate(_: int) -> int:
                return int(subprocess.check_output(command, text=True).strip())

            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                values = list(executor.map(allocate, range(24)))
            self.assertEqual(sorted(values), list(range(1, 25)))

    def test_help_and_invalid_mode_have_no_counter_side_effect(self) -> None:
        script = HELPER_PATH.parent / "build_and_run.sh"
        with tempfile.TemporaryDirectory() as temporary:
            counter_directory = Path(temporary) / "counter"
            environment = dict(os.environ, CODEX_WEEKLY_RESET_BUILD_COUNTER_DIR=str(counter_directory))
            help_result = subprocess.run(
                [str(script), "--help"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
            )
            invalid_result = subprocess.run(
                [str(script), "--not-a-mode"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
            )
            self.assertEqual(help_result.returncode, 0)
            self.assertIn("usage:", help_result.stdout)
            self.assertEqual(invalid_result.returncode, 2)
            self.assertIn("usage:", invalid_result.stderr)
            self.assertFalse(counter_directory.exists())


if __name__ == "__main__":
    unittest.main()
