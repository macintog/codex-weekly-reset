from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "release_feed.py"
SPEC = importlib.util.spec_from_file_location("release_feed", MODULE_PATH)
assert SPEC and SPEC.loader
release_feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_feed)

PREFIX = "https://example.test/downloads/"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def item(build: int, version: str, archive: str, length: int, notes: str = "notes") -> str:
    return f"""
    <item>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <description>{notes}</description>
      <enclosure url="{PREFIX}{archive}" length="{length}"
        sparkle:edSignature="signed" />
    </item>"""


def feed(*items: str) -> str:
    return f'<rss xmlns:sparkle="{SPARKLE}"><channel>{"".join(items)}</channel></rss>'


class ReleaseFeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.assets = self.root / "downloads"
        self.assets.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_asset(self, name: str, content: bytes = b"zip") -> None:
        (self.assets / name).write_bytes(content)

    def write_feed(self, name: str, content: str) -> Path:
        path = self.root / name
        path.write_text(content)
        return path

    def validate(
        self,
        current: str,
        prior: str | None = None,
        expected_notes: str | None = None,
    ) -> None:
        current_path = self.write_feed("current.xml", current)
        prior_path = self.write_feed("prior.xml", prior) if prior else None
        notes_path = (
            self.write_feed("notes.html", expected_notes)
            if expected_notes is not None
            else None
        )
        release_feed.validate_feed(
            current_path,
            self.assets,
            "11",
            "1.1",
            "App-v1.1-b11.zip",
            PREFIX,
            prior_path,
            expected_notes_path=notes_path,
        )

    def test_rejects_archive_associated_with_wrong_item(self) -> None:
        self.write_asset("App-v1.1-b11.zip")
        wrong = feed(
            item(11, "1.1", "other.zip", 3),
            item(10, "1.0", "App-v1.1-b11.zip", 3),
        )
        self.write_asset("other.zip")
        with self.assertRaisesRegex(release_feed.FeedValidationError, "wrong item"):
            self.validate(wrong)

    def test_rejects_missing_asset_and_signature(self) -> None:
        missing = feed(item(11, "1.1", "App-v1.1-b11.zip", 3))
        with self.assertRaisesRegex(release_feed.FeedValidationError, "missing"):
            self.validate(missing)

        self.write_asset("App-v1.1-b11.zip")
        unsigned = missing.replace(' sparkle:edSignature="signed"', "")
        with self.assertRaisesRegex(release_feed.FeedValidationError, "edSignature"):
            self.validate(unsigned)

    def test_rejects_wrong_length_and_path_traversal(self) -> None:
        self.write_asset("App-v1.1-b11.zip")
        wrong_length = feed(item(11, "1.1", "App-v1.1-b11.zip", 99))
        with self.assertRaisesRegex(release_feed.FeedValidationError, "length does not match"):
            self.validate(wrong_length)

        traversal = feed(item(11, "1.1", "App-v1.1-b11.zip", 3)).replace(
            "</item>",
            f'<sparkle:deltas><enclosure url="{PREFIX}%2e%2e%2fevil.delta" '
            'length="3" sparkle:edSignature="signed" /></sparkle:deltas></item>',
        )
        with self.assertRaisesRegex(release_feed.FeedValidationError, "unsafe enclosure"):
            self.validate(traversal)

    def test_rejects_build_and_version_rollback(self) -> None:
        self.write_asset("App-v1.1-b11.zip")
        self.write_asset("App-v1.2-b12.zip")
        prior = feed(item(12, "1.2", "App-v1.2-b12.zip", 3, "old notes"))
        with self.assertRaisesRegex(release_feed.FeedValidationError, "build must be newer"):
            self.validate(feed(item(11, "1.1", "App-v1.1-b11.zip", 3)), prior)

    def test_rejects_version_rollback_with_newer_build(self) -> None:
        self.write_asset("App-v1.1-b11.zip")
        self.write_asset("App-v1.2-b10.zip")
        prior = feed(item(10, "1.2", "App-v1.2-b10.zip", 3, "old notes"))
        with self.assertRaisesRegex(release_feed.FeedValidationError, "version must be newer"):
            self.validate(feed(item(11, "1.1", "App-v1.1-b11.zip", 3)), prior)

    def test_rejects_dropped_or_changed_retained_notes(self) -> None:
        self.write_asset("App-v1.0-b10.zip")
        self.write_asset("App-v1.1-b11.zip")
        prior = feed(item(10, "1.0", "App-v1.0-b10.zip", 3, "keep me"))
        changed = feed(
            item(11, "1.1", "App-v1.1-b11.zip", 3),
            item(10, "1.0", "App-v1.0-b10.zip", 3, "changed"),
        )
        with self.assertRaisesRegex(release_feed.FeedValidationError, "release notes"):
            self.validate(changed, prior)

    def test_recreates_retained_note_sidecar_and_preserves_description(self) -> None:
        notes = "<h1>Release 1.0</h1>\n<p>Keep this exact note.</p>\n"
        prior = feed(
            item(
                10,
                "1.0",
                "CodexWeeklyReset-v1.0-b10.zip",
                3,
                f"<![CDATA[{notes}]]>",
            )
        )
        prior_path = self.write_feed("prior.xml", prior)
        self.assertEqual(
            release_feed.main(
                [
                    "--prior-feed",
                    str(prior_path),
                    "--download-url-prefix",
                    PREFIX,
                    "--recreate-retained-notes",
                    str(self.root),
                ]
            ),
            0,
        )
        sidecars = [self.root.resolve() / "CodexWeeklyReset-v1.0-b10.html"]
        self.assertTrue(sidecars[0].is_file())
        self.assertEqual(
            sidecars[0].read_text(),
            notes,
        )

        self.write_asset("App-v1.0-b10.zip")
        self.write_asset("App-v1.1-b11.zip")
        current = feed(
            item(11, "1.1", "App-v1.1-b11.zip", 3),
            item(10, "1.0", "App-v1.0-b10.zip", 3, f"<![CDATA[{sidecars[0].read_text()}]]>"),
        )
        comparison_prior = feed(
            item(10, "1.0", "App-v1.0-b10.zip", 3, f"<![CDATA[{sidecars[0].read_text()}]]>")
        )
        self.validate(current, comparison_prior)

    def test_retained_note_recreation_rejects_unsafe_or_duplicate_sidecars(self) -> None:
        traversal = feed(
            item(10, "1.0", "%2e%2e%2foutside.zip", 3, "notes")
        )
        prior_path = self.write_feed("prior.xml", traversal)
        with self.assertRaisesRegex(release_feed.FeedValidationError, "unsafe enclosure"):
            release_feed.recreate_retained_note_sidecars(prior_path, self.root, PREFIX)
        self.assertFalse((self.root.parent / "outside.html").exists())

        safe = feed(item(10, "1.0", "App-v1.0-b10.zip", 3, "notes"))
        prior_path.write_text(safe)
        (self.root / "App-v1.0-b10.html").write_text("unowned")
        with self.assertRaisesRegex(release_feed.FeedValidationError, "duplicate"):
            release_feed.recreate_retained_note_sidecars(prior_path, self.root, PREFIX)

    def test_rejects_current_description_that_differs_from_expected_notes(self) -> None:
        self.write_asset("App-v1.1-b11.zip")
        current = feed(item(11, "1.1", "App-v1.1-b11.zip", 3, "generated copy"))
        with self.assertRaisesRegex(release_feed.FeedValidationError, "expected release notes"):
            self.validate(current, expected_notes="reviewed copy")

        self.validate(current, expected_notes="\n generated copy \n")

    def test_accepts_new_release_with_retained_history(self) -> None:
        self.write_asset("App-v0.9-b9.zip")
        self.write_asset("App-v1.0-b10.zip")
        self.write_asset("App-v1.1-b11.zip")
        prior = feed(
            item(10, "1.0", "App-v1.0-b10.zip", 3, "keep me"),
            item(9, "0.9", "App-v0.9-b9.zip", 3, "old bounded item"),
        )
        current = feed(
            item(11, "1.1", "App-v1.1-b11.zip", 3),
            item(10, "1.0", "App-v1.0-b10.zip", 3, "keep me"),
        )
        self.validate(current, prior)


if __name__ == "__main__":
    unittest.main()
