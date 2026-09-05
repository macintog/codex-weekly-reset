#!/usr/bin/env python3
"""Build provenance and project-global build counter helpers."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA_VERSION = 1
SOURCE_FILES = ("Package.swift", "Package.resolved", "script/build_and_run.sh", "script/pack_icns.py")
SOURCE_DIRECTORIES = ("Sources", "Resources")


def _regular_file(path: Path, root: Path) -> None:
    if path.is_symlink():
        raise ValueError(f"runtime source input must not be a symlink: {path.relative_to(root)}")
    if not path.is_file():
        raise ValueError(f"runtime source input is missing or not a regular file: {path.relative_to(root)}")


def _source_paths(root: Path) -> list[Path]:
    root = root.resolve(strict=True)
    paths: list[Path] = []
    for relative in SOURCE_FILES:
        path = root / relative
        _regular_file(path, root)
        paths.append(path)

    for relative in SOURCE_DIRECTORIES:
        directory = root / relative
        if directory.is_symlink():
            raise ValueError(f"runtime source directory must not be a symlink: {relative}")
        if not directory.is_dir():
            raise ValueError(f"runtime source directory is missing: {relative}")
        for path in sorted(directory.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"runtime source input must not be a symlink: {path.relative_to(root)}")
            if path.is_file():
                paths.append(path)
            elif not path.is_dir():
                raise ValueError(f"runtime source input has unsupported type: {path.relative_to(root)}")
    return paths


def source_files(root: str | os.PathLike[str]) -> dict[str, str]:
    """Return runtime source paths mapped to SHA-256 digests."""
    resolved_root = Path(root).resolve(strict=True)
    result: dict[str, str] = {}
    for path in _source_paths(resolved_root):
        relative = path.relative_to(resolved_root).as_posix()
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def source_commit(root: str | os.PathLike[str]) -> str:
    completed = subprocess.run(
        ["git", "-C", os.fspath(root), "rev-parse", "HEAD"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    commit = completed.stdout.strip()
    if len(commit) != 40 or any(character not in "0123456789abcdefABCDEF" for character in commit):
        raise ValueError("git returned an invalid source commit")
    return commit.lower()


def provenance(root: str | os.PathLike[str]) -> dict[str, Any]:
    return {
        "schema": SCHEMA_VERSION,
        "source_commit": source_commit(root),
        "source_files": source_files(root),
    }


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def write_snapshot(root: str | os.PathLike[str], output: str | os.PathLike[str]) -> None:
    _write_json(Path(output), provenance(root))


def verify_snapshot(root: str | os.PathLike[str], snapshot: str | os.PathLike[str]) -> None:
    with Path(snapshot).open(encoding="utf-8") as handle:
        expected = json.load(handle)
    actual = provenance(root)
    if expected != actual:
        raise ValueError("runtime source inputs changed during the build")


def _counter_value(path: Path) -> int:
    if not path.exists():
        return 0
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"build counter is not a regular file: {path}")
    digits = "".join(character for character in path.read_text(encoding="utf-8") if character.isdigit())
    return int(digits) if digits else 0


def allocate_counter(directory: str | os.PathLike[str], bundle_id: str, legacy_id: str) -> int:
    counter_directory = Path(directory)
    counter_directory.mkdir(parents=True, exist_ok=True)
    if counter_directory.is_symlink() or not counter_directory.is_dir():
        raise ValueError(f"build counter directory is unsafe: {counter_directory}")
    if "/" in bundle_id or "/" in legacy_id or bundle_id in ("", ".", "..") or legacy_id in ("", ".", ".."):
        raise ValueError("build counter identifiers must be file names")

    lock_path = counter_directory / ".build-counter.lock"
    with lock_path.open("a+") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        counter_path = counter_directory / bundle_id
        legacy_path = counter_directory / legacy_id
        value = max(_counter_value(counter_path), _counter_value(legacy_path)) + 1
        temporary_fd, temporary_name = tempfile.mkstemp(prefix=f".{bundle_id}.", dir=counter_directory)
        try:
            with os.fdopen(temporary_fd, "w", encoding="utf-8") as handle:
                handle.write(f"{value}\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, counter_path)
        except BaseException:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            raise
        return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--root", required=True)
    snapshot_parser.add_argument("--output", required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--root", required=True)
    verify_parser.add_argument("--snapshot", required=True)

    counter_parser = subparsers.add_parser("counter")
    counter_parser.add_argument("--directory", required=True)
    counter_parser.add_argument("--bundle-id", required=True)
    counter_parser.add_argument("--legacy-id", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "snapshot":
            write_snapshot(args.root, args.output)
        elif args.command == "verify":
            verify_snapshot(args.root, args.snapshot)
        elif args.command == "counter":
            print(allocate_counter(args.directory, args.bundle_id, args.legacy_id))
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"build provenance error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
