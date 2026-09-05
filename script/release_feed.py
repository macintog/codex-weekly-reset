#!/usr/bin/env python3
"""Validate a locally staged Sparkle appcast before it is promoted."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import urllib.parse
import xml.etree.ElementTree as ET


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION = f"{{{SPARKLE_NS}}}version"
SHORT_VERSION = f"{{{SPARKLE_NS}}}shortVersionString"
SIGNATURE = f"{{{SPARKLE_NS}}}edSignature"


class FeedValidationError(ValueError):
    pass


def _parse_feed(path: Path) -> ET.Element:
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise FeedValidationError(f"cannot parse appcast {path}: {error}") from error


def _items(root: ET.Element) -> list[ET.Element]:
    return root.findall("./channel/item")


def _required_text(item: ET.Element, tag: str, label: str) -> str:
    value = item.findtext(tag)
    if value is None or not value.strip():
        raise FeedValidationError(f"feed item is missing {label}")
    return value.strip()


def _numeric_version(value: str) -> tuple[int, ...]:
    parts = value.split(".")
    if not parts or any(not part.isdigit() for part in parts):
        raise FeedValidationError(
            f"release version must contain only dot-separated integers: {value}"
        )
    return tuple(int(part) for part in parts)


def _asset_name(url: str, prefix: str) -> str:
    if not url.startswith(prefix):
        raise FeedValidationError(f"enclosure URL is outside the pinned prefix: {url}")
    parsed = urllib.parse.urlsplit(url)
    parsed_prefix = urllib.parse.urlsplit(prefix)
    if parsed.query or parsed.fragment:
        raise FeedValidationError(f"enclosure URL must not contain a query or fragment: {url}")
    if (parsed.scheme, parsed.netloc) != (parsed_prefix.scheme, parsed_prefix.netloc):
        raise FeedValidationError(f"enclosure URL is outside the pinned origin: {url}")

    encoded_name = url[len(prefix) :]
    name = urllib.parse.unquote(encoded_name)
    if (
        not encoded_name
        or not name
        or name in {".", ".."}
        or "/" in name
        or "\\" in name
        or any(ord(character) < 32 for character in name)
        or os.path.basename(name) != name
    ):
        raise FeedValidationError(f"unsafe enclosure URL path: {url}")
    return name


def _item_identity(item: ET.Element) -> tuple[str, str]:
    return (
        _required_text(item, VERSION, "sparkle:version"),
        _required_text(item, SHORT_VERSION, "sparkle:shortVersionString"),
    )


def recreate_retained_note_sidecars(
    prior_feed_path: Path,
    output_dir: Path,
    download_url_prefix: str,
) -> list[Path]:
    """Recreate generator sidecars for descriptions already signed into a feed."""
    root = _parse_feed(prior_feed_path)
    output_root = output_dir.resolve()
    if output_dir.is_symlink() or not output_root.is_dir():
        raise FeedValidationError("retained-notes output must be an existing real directory")
    written: list[Path] = []
    for item in _items(root):
        description = item.findtext("description")
        if description is None:
            continue
        primary = item.findall("enclosure")
        if len(primary) != 1:
            build, _ = _item_identity(item)
            raise FeedValidationError(
                f"retained feed item {build} must have exactly one primary enclosure"
            )
        archive_name = _asset_name(primary[0].get("url", ""), download_url_prefix)
        if not archive_name.endswith(".zip"):
            raise FeedValidationError(
                f"retained release notes require a ZIP primary enclosure: {archive_name}"
            )
        sidecar = output_root / (archive_name[:-4] + ".html")
        if sidecar.parent != output_root or sidecar.exists() or sidecar.is_symlink():
            raise FeedValidationError(f"unsafe or duplicate retained-notes sidecar: {sidecar.name}")
        sidecar.write_text(description)
        written.append(sidecar)
    return written


def validate_feed(
    feed_path: Path,
    assets_dir: Path,
    expected_build: str,
    expected_version: str,
    expected_archive: str,
    download_url_prefix: str,
    prior_feed_path: Path | None = None,
    allow_existing_build: bool = False,
    expected_notes_path: Path | None = None,
) -> str:
    root = _parse_feed(feed_path)
    items = _items(root)
    expected_url = download_url_prefix + urllib.parse.quote(expected_archive)

    matching_items: list[ET.Element] = []
    archive_enclosures: list[tuple[ET.Element, ET.Element]] = []
    seen_builds: set[str] = set()
    for item in items:
        build, version = _item_identity(item)
        if build in seen_builds:
            raise FeedValidationError(f"feed contains duplicate build {build}")
        seen_builds.add(build)
        if build == expected_build and version == expected_version:
            matching_items.append(item)
        for enclosure in item.findall(".//enclosure"):
            if enclosure.get("url") == expected_url:
                archive_enclosures.append((item, enclosure))

    if len(matching_items) != 1:
        raise FeedValidationError(
            f"expected exactly one item for version {expected_version} build {expected_build}; "
            f"found {len(matching_items)}"
        )
    if len(archive_enclosures) != 1 or archive_enclosures[0][0] is not matching_items[0]:
        raise FeedValidationError(
            "expected archive enclosure is missing, duplicated, or associated with the wrong item"
        )
    primary_enclosures = matching_items[0].findall("enclosure")
    if len(primary_enclosures) != 1 or archive_enclosures[0][1] not in primary_enclosures:
        raise FeedValidationError("expected archive must be the item's primary enclosure")

    if expected_notes_path is not None:
        try:
            expected_notes = expected_notes_path.read_text().strip()
        except OSError as error:
            raise FeedValidationError(
                f"cannot read expected release notes {expected_notes_path}: {error}"
            ) from error
        actual_notes = matching_items[0].findtext("description")
        if actual_notes is None or actual_notes.strip() != expected_notes:
            raise FeedValidationError(
                "current feed item description does not match the expected release notes"
            )

    assets_root = assets_dir.resolve()
    for enclosure in root.findall("./channel/item//enclosure"):
        url = enclosure.get("url", "")
        name = _asset_name(url, download_url_prefix)
        signature = enclosure.get(SIGNATURE, "").strip()
        if not signature:
            raise FeedValidationError(f"enclosure is missing sparkle:edSignature: {url}")
        length_text = enclosure.get("length", "")
        if not length_text.isdigit():
            raise FeedValidationError(f"enclosure has an invalid length: {url}")
        asset = assets_root / name
        if asset.parent != assets_root or asset.is_symlink() or not asset.is_file():
            raise FeedValidationError(f"referenced local asset is missing: {name}")
        if asset.stat().st_size != int(length_text):
            raise FeedValidationError(
                f"referenced asset length does not match for {name}: "
                f"feed={length_text} file={asset.stat().st_size}"
            )

    expected_signature = archive_enclosures[0][1].get(SIGNATURE, "").strip()
    if prior_feed_path is None:
        return expected_signature

    prior_root = _parse_feed(prior_feed_path)
    prior_items = _items(prior_root)
    prior_by_build = {_item_identity(item)[0]: item for item in prior_items}
    if len(prior_by_build) != len(prior_items):
        raise FeedValidationError("prior feed contains duplicate builds")

    prior_expected = prior_by_build.get(expected_build)
    if prior_expected is not None:
        if not allow_existing_build:
            raise FeedValidationError(f"build {expected_build} already exists in the prior feed")
        if _item_identity(prior_expected)[1] != expected_version:
            raise FeedValidationError(
                f"build {expected_build} already exists with a different release version"
            )
    elif prior_items:
        prior_builds = [_item_identity(item)[0] for item in prior_items]
        if any(not build.isdigit() for build in prior_builds) or not expected_build.isdigit():
            raise FeedValidationError("release builds must be numeric")
        if int(expected_build) <= max(int(build) for build in prior_builds):
            raise FeedValidationError("new release build must be newer than the prior feed")
        prior_versions = [_numeric_version(_item_identity(item)[1]) for item in prior_items]
        if _numeric_version(expected_version) <= max(prior_versions):
            raise FeedValidationError("new release version must be newer than the prior feed")

    current_by_build = {_item_identity(item)[0]: item for item in items}
    for build, prior_item in prior_by_build.items():
        current_item = current_by_build.get(build)
        if current_item is None:
            # Sparkle keeps a bounded number of old items. Only history retained
            # in the generated feed must remain byte-for-byte intact.
            continue
        prior_description = prior_item.findtext("description")
        if prior_description is not None and current_item.findtext("description") != prior_description:
            raise FeedValidationError(f"generated feed changed retained release notes for build {build}")
    return expected_signature


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", type=Path)
    parser.add_argument("--assets-dir", type=Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-archive")
    parser.add_argument("--download-url-prefix")
    parser.add_argument("--prior-feed", type=Path)
    parser.add_argument("--expected-notes", type=Path)
    parser.add_argument("--recreate-retained-notes", type=Path)
    parser.add_argument("--allow-existing-build", action="store_true")
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument("--print-expected-signature", action="store_true")
    output_group.add_argument("--print-enclosure-signatures", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.recreate_retained_notes is not None:
            if args.prior_feed is None or args.download_url_prefix is None:
                parser.error(
                    "--recreate-retained-notes requires --prior-feed and --download-url-prefix"
                )
            recreate_retained_note_sidecars(
                args.prior_feed, args.recreate_retained_notes, args.download_url_prefix
            )
            return 0
        required = {
            "--feed": args.feed,
            "--assets-dir": args.assets_dir,
            "--expected-build": args.expected_build,
            "--expected-version": args.expected_version,
            "--expected-archive": args.expected_archive,
            "--download-url-prefix": args.download_url_prefix,
        }
        missing = [name for name, value in required.items() if value is None]
        if missing:
            parser.error("validation requires " + ", ".join(missing))
        signature = validate_feed(
            args.feed,
            args.assets_dir,
            args.expected_build,
            args.expected_version,
            args.expected_archive,
            args.download_url_prefix,
            args.prior_feed,
            args.allow_existing_build,
            args.expected_notes,
        )
    except FeedValidationError as error:
        print(f"Invalid Sparkle feed: {error}", file=sys.stderr)
        return 1
    if args.print_expected_signature:
        print(signature)
    elif args.print_enclosure_signatures:
        root = _parse_feed(args.feed)
        for enclosure in root.findall("./channel/item//enclosure"):
            name = _asset_name(enclosure.get("url", ""), args.download_url_prefix)
            print(f"{name}\t{enclosure.get(SIGNATURE, '').strip()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
