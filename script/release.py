#!/usr/bin/env python3
"""Freeze a tested app, prepare its release, and prove published bytes.

No command compiles an app, changes Git refs, or publishes to a host.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

from build_provenance import source_files

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Codex Weekly Reset.app"
BUNDLE_ID = "com.macintog.codexweeklyreset"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PUBLIC_PATHS = ("Package.swift", "Package.resolved", "README.md", ".gitignore", "LICENSE",
                "SECURITY.md", "Sources", "Tests", "Resources", "script", "website", "docs/release-notes")
OPTIONAL_PUBLIC_PATHS = {"SECURITY.md"}


def run(*args):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args[0]} {args[1] if len(args)>1 else ''}\n{result.stdout}{result.stderr}")
    return result.stdout


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def files(root, ignore_git=False):
    """Hash regular files, modes, and symlink targets without following links."""
    result = {}
    for path in sorted(Path(root).rglob("*")):
        name = path.relative_to(root).as_posix()
        if ignore_git and (name == ".git" or name.startswith(".git/")):
            continue
        if path.is_symlink():
            resolved = path.resolve()
            if not resolved.is_relative_to(Path(root).resolve()):
                raise ValueError(f"Escaping symlink: {name}")
            result[name] = "link:" + os.readlink(path)
        elif path.is_file():
            result[name] = f"{path.stat().st_mode & 0o777:o}:" + sha(path)
    return result


def manifest_sha256(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    temporary.replace(path)


def identity(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleName") != "Codex Weekly Reset":
        raise ValueError("The selected app is not Codex Weekly Reset")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Release version must be x.y.z and build must be a positive integer")
    return {"version": version, "build": build, "bundle_id": BUNDLE_ID,
            "feed_url": info["SUFeedURL"], "public_key": info["SUPublicEDKey"]}


def copy_public(root, destination):
    destination.mkdir()
    for name in PUBLIC_PATHS:
        source, target = root / name, destination / name
        if not source.exists() and name in OPTIONAL_PUBLIC_PATHS:
            continue
        if not source.exists():
            raise ValueError(f"Required public input missing: {name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))
        else:
            shutil.copy2(source, target)
    readme = destination / "README.md"
    text = readme.read_text()
    text = re.sub(r"(?ms)^## Source Of Truth\n.*?(?=^## |\Z)", "", text)
    readme.write_text(text.rstrip() + "\n")
    files(destination)  # Reject links escaping the approved public tree.


def refresh_labels(public, version, summary):
    readme = public / "README.md"
    text = readme.read_text()
    if not re.search(r"Download Codex Weekly Reset \d+\.\d+\.\d+", text):
        raise ValueError("README download label changed; update the release renderer")
    text = re.sub(r"Download Codex Weekly Reset \d+\.\d+\.\d+", f"Download Codex Weekly Reset {version}", text)
    text = re.sub(r"\[\d+\.\d+\.\d+ release notes\]", f"[{version} release notes]", text)
    text = re.sub(r"releases/tag/v\d+\.\d+\.\d+", f"releases/tag/v{version}", text)
    text = re.sub(r"(?ms)(^## What’s New\n\n).*?(?=^## |\Z)",
                  lambda m: m[1] + f"- **{version}:** {summary}\n\n", text)
    readme.write_text(text)
    page = public / "website/index.html"
    text = page.read_text()
    if text.count('<dl class="feature-list">') != 1 or not re.search(r"Version \d+\.\d+\.\d+", text):
        raise ValueError("Website release template changed; update the release renderer")
    text = re.sub(r"Version \d+\.\d+\.\d+", f"Version {version}", text)
    text = re.sub(r"Download \d+\.\d+\.\d+", f"Download {version}", text)
    text = re.sub(r"releases/tag/v\d+\.\d+\.\d+", f"releases/tag/v{version}", text)
    row = (f'<div class="feature-row feature-row-primary">\n'
           f'            <dt><span class="feature-signal purple" aria-hidden="true"></span>{version}</dt>\n'
           f'            <dd>{html.escape(summary)}</dd>\n          </div>')
    current_row = r'<div class="feature-row[^"]*">\s*<dt>[^<]*(?:<span[^>]*></span>)?' + re.escape(version) + r'</dt>\s*<dd>.*?</dd>\s*</div>'
    if re.search(current_row, text, flags=re.S):
        text = re.sub(current_row, lambda m: row, text, count=1, flags=re.S)
    else:
        text = text.replace('class="feature-row feature-row-primary"', 'class="feature-row"')
        text = text.replace('<dl class="feature-list">', '<dl class="feature-list">\n          ' + row)
    page.write_text(text)



def public_input_files(root):
    result = {}
    for name in PUBLIC_PATHS:
        path = root / name
        if not path.exists() and name in OPTIONAL_PUBLIC_PATHS:
            continue
        if path.is_symlink():
            raise ValueError(f"Public input must not be a symlink: {name}")
        entries = files(path) if path.is_dir() else {"": f"{path.stat().st_mode & 0o777:o}:" + sha(path)}
        for child, value in entries.items():
            if "__pycache__" in Path(child).parts or child.endswith((".pyc", ".DS_Store")):
                continue
            result[name + ("/" + child if child else "")] = value
    return result


def validate_targets(config):
    required = {"website", "sparkle", "github_repository", "source_branch", "pages_branch", "development_keeper", "discussion"}
    if set(config) != required:
        raise ValueError("Unexpected release target configuration fields")
    if (config["website"] != "https://macintog.github.io/codex-weekly-reset/" or
        config["sparkle"] != config["website"] + "appcast.xml" or
        config["github_repository"] != "macintog/codex-weekly-reset" or
        config["source_branch"] != "master" or config["pages_branch"] != "gh-pages"):
        raise ValueError("Unexpected publication target, branch, or feed")
    keeper = urllib.parse.urlsplit(config["development_keeper"])
    if not keeper.path.endswith("/codex-weekly-reset-private.git") or not keeper.netloc:
        raise ValueError("Development keeper must identify the private repository")
    discussion = config["discussion"]
    if not isinstance(discussion, dict) or type(discussion.get("enabled")) is not bool:
        raise ValueError("Discussion requires an explicit enabled disposition")
    if discussion["enabled"] and not discussion.get("category_id"):
        raise ValueError("An enabled announcement needs an inspected GitHub discussion category ID")
    if not discussion["enabled"] and not discussion.get("reason"):
        raise ValueError("Explain the disabled announcement destination in the review packet")


def render_note_review(notes, version, summary):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Release version must be x.y.z")
    if not summary.strip() or "\n" in summary or "\r" in summary:
        raise ValueError("Customer summary must be one nonempty line")
    validate_notes(notes, version, summary)
    return (f"# Review customer note for Codex Weekly Reset {version}\n\n"
            "Record the explicit customer-wording choice before building the release candidate. "
            "The later final release review still binds the prepared artifact and every publication surface.\n\n"
            f"Customer benefit: {summary}\n\n"
            f"Release note SHA-256: {sha(notes)}\n\n"
            f"{notes.read_text()}\n")


def review_note(args):
    review_dir = args.review_dir.resolve()
    if review_dir.exists():
        raise ValueError("Note review directory already exists")
    text = render_note_review(args.notes, args.version, args.summary)
    review_dir.mkdir(parents=True)
    shutil.copy2(args.notes, review_dir / "release-note.html")
    (review_dir / "NOTE_REVIEW.md").write_text(text)
    receipt = {"schema": 1, "version": args.version, "summary": args.summary,
               "note_sha256": sha(args.notes),
               "review_sha256": hashlib.sha256(text.encode()).hexdigest()}
    write_json(review_dir / "receipt.json", receipt)
    return {"review": str(review_dir / "NOTE_REVIEW.md"),
            "review_sha256": receipt["review_sha256"]}


def load_note_review(review_dir):
    receipt = json.loads((review_dir / "receipt.json").read_text())
    required = {"schema", "version", "summary", "note_sha256", "review_sha256"}
    if set(receipt) - {"approval"} != required or receipt["schema"] != 1:
        raise ValueError("Unsupported customer-note review receipt")
    note = review_dir / "release-note.html"
    text = render_note_review(note, receipt["version"], receipt["summary"])
    digest = hashlib.sha256(text.encode()).hexdigest()
    if (sha(note) != receipt["note_sha256"] or digest != receipt["review_sha256"] or
            (review_dir / "NOTE_REVIEW.md").read_text() != text):
        raise ValueError("Customer-note review inputs changed")
    return receipt


def approve_note(args):
    receipt = load_note_review(args.review_dir)
    if args.review_sha256 != receipt["review_sha256"]:
        raise ValueError("The reviewed customer note changed; obtain a new operator review")
    receipt["approval"] = {"review_sha256": receipt["review_sha256"]}
    write_json(args.review_dir / "receipt.json", receipt)
    return {"approved": receipt["review_sha256"],
            "next": "Build and test the release candidate with this exact version and customer note"}


def require_note_approval(review_dir, notes, version, summary):
    receipt = load_note_review(review_dir.resolve())
    if (receipt.get("approval") != {"review_sha256": receipt["review_sha256"]} or
            receipt["version"] != version or receipt["summary"] != summary or
            receipt["note_sha256"] != sha(notes)):
        raise ValueError("Capture requires the exact operator-approved customer note")
    return receipt["review_sha256"]


def capture(args):
    app, release_dir = args.app.resolve(), args.release_dir.resolve()
    root = args.root.resolve()
    if release_dir.exists():
        raise ValueError("Release directory already exists; use status/prepare to resume it")
    if any(release_dir.is_relative_to((root / name).resolve()) for name in PUBLIC_PATHS) or release_dir.is_relative_to(app):
        raise ValueError("Release evidence must be outside public inputs and the selected app")
    for private_input in (args.editorial.resolve(), args.config.resolve()):
        if any(private_input.is_relative_to((root / name).resolve()) for name in PUBLIC_PATHS):
            raise ValueError("Private editorial/config inputs must be outside the public subset")
    if not args.summary.strip() or "\n" in args.summary or "\r" in args.summary:
        raise ValueError("Customer summary must be one nonempty line")
    selected = identity(app)
    config = json.loads(args.config.read_text())
    validate_targets(config)
    if selected["feed_url"] != config["website"] + "appcast.xml":
        raise ValueError("App feed and publication target disagree")
    notes = root / f'docs/release-notes/{selected["version"]}.html'
    if not notes.is_file():
        raise ValueError(f"Write customer release notes before capture: {notes}")
    note_review_sha256 = require_note_approval(args.note_review, notes, selected["version"], args.summary)
    prior = ET.parse(root / "website/appcast.xml")
    prior_items = prior.findall("./channel/item")
    if any(int(item.findtext(SPARKLE + "version")) >= int(selected["build"]) for item in prior_items):
        raise ValueError("Selected build is already released or older than the feed; choose an unreleased tested build")
    if any(tuple(map(int, item.findtext(SPARKLE + "shortVersionString").split("."))) >=
           tuple(map(int, selected["version"].split("."))) for item in prior_items):
        raise ValueError("Release version must advance beyond the existing feed")
    provenance_path = app / "Contents/Resources/BuildProvenance.json"
    if not provenance_path.is_file():
        raise ValueError("This older app has no build provenance. Build and test once with the updated build entrypoint before promotion")
    provenance = json.loads(provenance_path.read_text())
    if set(provenance) != {"schema", "source_commit", "source_files"} or provenance["schema"] != 1 or not re.fullmatch(r"[0-9a-f]{40}", provenance["source_commit"]):
        raise ValueError("Unsupported or unsafe build provenance")
    if provenance.get("source_files") != source_files(root):
        raise ValueError("Selected app was built from different source inputs; restore its source or select the matching app")
    validate_notes(notes, selected["version"], args.summary)
    source_snapshot = public_input_files(root)
    app_hashes = files(app)
    release_dir.mkdir(parents=True)
    try:
        frozen = release_dir / "tested" / APP_NAME
        frozen.parent.mkdir()
        run("/usr/bin/ditto", app, frozen)
        if files(frozen) != app_hashes or files(app) != app_hashes:
            raise ValueError("App changed during capture")
        public = release_dir / "public"
        copy_public(root, public)
        if public_input_files(root) != source_snapshot:
            raise ValueError("Public source changed during capture")
        if source_files(root) != provenance["source_files"]:
            raise ValueError("Source changed during capture")
        refresh_labels(public, selected["version"], args.summary)
        if source_files(public) != provenance["source_files"]:
            raise ValueError("Public source differs from the tested app inputs")
        editorial = release_dir / "editorial"
        shutil.copytree(args.editorial, editorial)
        validate_editorial(editorial, selected["version"], args.summary)
        receipt = {"schema": 1, "state": "captured", "identity": selected,
                   "source_commit": provenance["source_commit"], "targets": config,
                   "summary": args.summary, "tested_files": app_hashes,
                   "public_files": files(public), "editorial_files": files(editorial),
                   "note_review_sha256": note_review_sha256}
        write_json(release_dir / "receipt.json", receipt)
    except BaseException:
        # The directory was exclusively created by this capture; preserve evidence on failure.
        (release_dir / "CAPTURE_FAILED").write_text("Capture failed. Inspect this directory; do not publish it.\n")
        raise
    return status(release_dir)


@contextlib.contextmanager
def locked(release_dir):
    with (release_dir / ".release.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another release command owns this receipt")
        yield


def load(release_dir):
    if (release_dir / "pending-revision.json").exists():
        journal = json.loads((release_dir / "pending-revision.json").read_text())
        command = journal.get("operation", "revise-text")
        raise ValueError(f"Revision was interrupted; run {command} --resume for this release directory")
    receipt = json.loads((release_dir / "receipt.json").read_text())
    if receipt.get("schema") != 1 or (release_dir / "CAPTURE_FAILED").exists():
        raise ValueError("Unsupported or failed release capture")
    return receipt


def check_inputs(release_dir, receipt):
    if files(release_dir / "tested" / APP_NAME) != receipt["tested_files"]:
        raise ValueError("Frozen tested app changed")
    if files(release_dir / "editorial") != receipt["editorial_files"]:
        raise ValueError("Reviewed text changed; capture a new editorial revision")
    if files(release_dir / "public") != receipt["public_files"]:
        raise ValueError("Public release snapshot changed")


def status(release_dir):
    receipt = load(release_dir)
    check_inputs(release_dir, receipt)
    return {"state": receipt["state"], "identity": receipt["identity"],
            "targets": receipt["targets"], "receipt": str(release_dir / "receipt.json"),
            "notary_submission": receipt.get("notary_submission"),
            "functional_smoke": smoke_is_valid(release_dir, receipt),
            "approved": is_approved(release_dir, receipt)}


def sign(app, team, signing_identity):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    nested = ("Versions/B/Autoupdate", "Versions/B/XPCServices/Downloader.xpc",
              "Versions/B/XPCServices/Installer.xpc", "Versions/B/Updater.app")
    for name in nested:
        path = framework / name
        if not path.exists():
            raise ValueError(f"Missing Sparkle component: {name}")
    for path in [*(framework / name for name in nested), framework, app]:
        run("/usr/bin/codesign", "--force", "--sign", signing_identity,
            "--timestamp", "--options", "runtime", path)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True)
    if result.returncode or f"TeamIdentifier={team}\n" not in result.stderr or "Authority=Developer ID Application:" not in result.stderr:
        raise ValueError("The signed copy has the wrong Developer ID identity")


def prepare(args):
    release_dir = args.release_dir.resolve()
    with locked(release_dir):
        receipt = load(release_dir)
        check_inputs(release_dir, receipt)
        if receipt["state"] == "ready":
            ready(release_dir)
            return status(release_dir)
        if receipt["state"] == "submitting":
            raise ValueError("Notary upload outcome is uncertain. Recover its submission ID with attach-notary; do not submit again")
        tools_dir = args.tools_dir.resolve()
        for name in ("generate_appcast", "generate_keys", "sign_update"):
            if not (tools_dir / name).is_file():
                raise ValueError(f"Missing Sparkle tool: {tools_dir / name}; pass --tools-dir from the tested build")
        tool_hashes = {name: sha(tools_dir / name) for name in ("generate_keys", "generate_appcast", "sign_update")}
        if receipt.get("tool_hashes", tool_hashes) != tool_hashes:
            raise ValueError("Sparkle release tools changed since preparation")
        if run(tools_dir / "generate_keys", "--account", args.sparkle_account, "-p").strip() != receipt["identity"]["public_key"]:
            raise ValueError("Sparkle signing key does not match the tested app")
        app = release_dir / "signed" / APP_NAME
        if receipt["state"] == "captured":
            app.parent.mkdir(exist_ok=True)
            # Retry signing only from the frozen original, never a partly signed copy.
            if app.exists():
                shutil.rmtree(app)
            run("/usr/bin/ditto", release_dir / "tested" / APP_NAME, app)
            sign(app, args.team, args.signing_identity)
            archive = release_dir / f'CodexWeeklyReset-b{receipt["identity"]["build"]}-notary.zip'
            if archive.exists():
                archive.unlink()
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", app, archive)
            receipt.update(state="signed", tool_hashes=tool_hashes, notary_archive=archive.name, notary_sha256=sha(archive),
                           signed_files=files(app), team=args.team, sparkle_account=args.sparkle_account)
            write_json(release_dir / "receipt.json", receipt)
        if receipt["state"] == "signed":
            archive = release_dir / receipt["notary_archive"]
            if sha(archive) != receipt["notary_sha256"] or files(app) != receipt["signed_files"]:
                raise ValueError("Signed submission artifact changed")
            receipt.update(state="submitting", attempted_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
            write_json(release_dir / "receipt.json", receipt)
            # Persist intent before the external action. A lost response requires reconciliation.
            result = run("xcrun", "notarytool", "submit", archive, "--keychain-profile", args.notary_profile,
                         "--no-wait", "--output-format", "json")
            (release_dir / "notary-submit.json").write_text(result)
            receipt["notary_submission"] = json.loads(result)["id"]
            receipt["state"] = "submitted"
            write_json(release_dir / "receipt.json", receipt)
        if receipt["state"] == "submitted":
            if sha(release_dir / receipt["notary_archive"]) != receipt["notary_sha256"] or files(app) != receipt["signed_files"]:
                raise ValueError("Submitted artifact changed")
            result = run("xcrun", "notarytool", "info", receipt["notary_submission"],
                         "--keychain-profile", args.notary_profile, "--output-format", "json")
            (release_dir / "notary-info.json").write_text(result)
            notary = json.loads(result)
            if notary["status"] == "In Progress":
                return {"state": "submitted", "message": "Apple is processing this submission. Run prepare again; it will not upload again."}
            if notary["status"] != "Accepted":
                raise ValueError(f'Apple status: {notary["status"]}. Inspect notarytool log for this submission; do not publish.')
            log = json.loads(run("xcrun", "notarytool", "log", receipt["notary_submission"],
                                 "--keychain-profile", args.notary_profile))
            if log.get("sha256") != receipt["notary_sha256"] or log.get("jobId") != receipt["notary_submission"]:
                raise ValueError("Apple acceptance does not belong to this exact submitted archive")
            write_json(release_dir / "notary-log.json", log)
            receipt["state"] = "accepted"
            write_json(release_dir / "receipt.json", receipt)
        if receipt["state"] == "accepted":
            run("xcrun", "stapler", "staple", app)
            run("xcrun", "stapler", "validate", app)
            receipt["state"] = "stapled"
            receipt["stapled_files"] = files(app)
            write_json(release_dir / "receipt.json", receipt)
        if receipt["state"] == "stapled":
            if files(app) != receipt["stapled_files"] or identity(app) != receipt["identity"]:
                raise ValueError("Stapled artifact identity changed")
            # Finalizer works in a disposable copy. An interruption leaves the captured public tree intact.
            output = release_dir / "prepared-website"
            if output.exists():
                shutil.rmtree(output)
            shutil.copytree(release_dir / "public/website", output)
            env = os.environ.copy()
            env["CODEX_WEEKLY_RESET_APPLE_TEAM_ID"] = receipt["team"]
            env["CODEX_WEEKLY_RESET_SPARKLE_ACCOUNT"] = receipt["sparkle_account"]
            with tempfile.TemporaryDirectory(prefix="finalize-", dir=release_dir) as staging:
                env["TMPDIR"] = staging
                subprocess.run([str(release_dir / "public/script/finalize_sparkle_release.sh"), str(app),
                                "--website-dir", str(output), "--tools-dir", str(tools_dir),
                                "--staging-dir", str(Path(staging) / "stage")], check=True, env=env)
            receipt["prepared_files"] = files(output)
            receipt["state"] = "finalized"
            write_json(release_dir / "receipt.json", receipt)
        if receipt["state"] == "finalized":
            if files(release_dir / "prepared-website") != receipt["prepared_files"]:
                raise ValueError("Prepared website changed")
            # Keep the public snapshot immutable; publication source is assembled separately.
            publication = release_dir / "publication"
            if publication.exists():
                shutil.rmtree(publication)
            shutil.copytree(release_dir / "public", publication)
            shutil.rmtree(publication / "website")
            shutil.copytree(release_dir / "prepared-website", publication / "website")
            receipt["publication_files"] = files(publication)
            receipt["state"] = "ready"
            write_json(release_dir / "receipt.json", receipt)
        return status(release_dir)



def retry_upload(args):
    with locked(args.release_dir):
        receipt = load(args.release_dir)
        check_inputs(args.release_dir, receipt)
        if receipt["state"] != "submitting" or not args.confirmed_not_submitted:
            raise ValueError("Retry requires an uncertain upload and operator confirmation that no submission occurred")
        history = json.loads(run("xcrun", "notarytool", "history", "--keychain-profile", args.notary_profile, "--output-format", "json"))
        entries = history.get("history")
        if not isinstance(entries, list):
            raise ValueError("Apple submission history is unavailable")
        if any(item.get("name") == receipt["notary_archive"] for item in entries):
            raise ValueError("Apple has a matching archive name. Recover its ID and use attach-notary instead")
        write_json(args.release_dir / "notary-no-submission-history.json", history)
        receipt["state"] = "signed"
        write_json(args.release_dir / "receipt.json", receipt)
    return status(args.release_dir)


def attach_notary(args):
    with locked(args.release_dir):
        receipt = load(args.release_dir)
        check_inputs(args.release_dir, receipt)
        if receipt["state"] != "submitting":
            raise ValueError("Only an uncertain upload can attach a recovered submission ID")
        receipt["notary_submission"] = args.submission_id
        receipt["state"] = "submitted"
        write_json(args.release_dir / "receipt.json", receipt)
    return status(args.release_dir)


def ready(release_dir):
    receipt = load(release_dir)
    check_inputs(release_dir, receipt)
    if receipt["state"] != "ready":
        raise ValueError("Release is not prepared yet")
    if files(release_dir / "publication") != receipt["publication_files"]:
        raise ValueError("Publication bytes changed after preparation")
    return receipt


def artifact_digest(release_dir, receipt):
    archive = release_dir / "publication/website/downloads/CodexWeeklyReset.zip"
    selected = {"identity": receipt["identity"], "zip_sha256": sha(archive)}
    return hashlib.sha256(json.dumps(selected, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_smoke(release_dir, receipt):
    smoke = receipt.get("functional_smoke")
    if not isinstance(smoke, dict) or smoke.get("artifact_manifest") != artifact_digest(release_dir, receipt):
        raise ValueError("Record functional smoke evidence for this exact prepared customer ZIP")
    path = release_dir / "functional-smoke.json"
    if not path.is_file() or sha(path) != smoke.get("observed_sha256"):
        raise ValueError("Recorded functional smoke evidence changed")
    observed = json.loads(path.read_text())
    evidence = Path(observed.get("codex_usage", {}).get("evidence_path", ""))
    if (not evidence.is_absolute() or not evidence.is_file() or
            sha(evidence) != observed.get("codex_usage", {}).get("evidence_sha256")):
        raise ValueError("Recorded live usage-read evidence changed")
    return observed


def smoke_is_valid(release_dir, receipt):
    try:
        validate_smoke(release_dir, receipt)
        return True
    except (ValueError, KeyError, OSError, json.JSONDecodeError):
        return False


def record_smoke(args):
    with locked(args.release_dir):
        receipt = ready(args.release_dir)
        observed = json.loads(args.observed.read_text())
        required = {"schema", "artifact", "launch", "codex_usage", "visual"}
        if set(observed) != required or observed.get("schema") != 1:
            raise ValueError("Functional smoke evidence has an unsupported schema")
        expected_zip = sha(args.release_dir / "publication/website/downloads/CodexWeeklyReset.zip")
        identity_fields = {"version": receipt["identity"]["version"],
                           "build": receipt["identity"]["build"],
                           "zip_sha256": expected_zip}
        if observed.get("artifact") != identity_fields:
            raise ValueError("Functional smoke artifact identity differs from the prepared customer ZIP")
        launch = observed.get("launch")
        if not isinstance(launch, dict) or set(launch) != {"app_path", "bundle_id", "version", "build"}:
            raise ValueError("Functional smoke launch evidence is incomplete")
        app = Path(launch["app_path"])
        if not app.is_absolute() or app.name != APP_NAME or not app.is_dir():
            raise ValueError("Functional smoke app_path must identify the extracted customer app")
        actual_identity = identity(app)
        if ({key: launch[key] for key in ("bundle_id", "version", "build")} !=
                {key: actual_identity[key] for key in ("bundle_id", "version", "build")} or
                actual_identity != receipt["identity"]):
            raise ValueError("Launched extracted app identity differs from the prepared release")
        if files(app) != receipt["stapled_files"]:
            raise ValueError("Launched extracted app bytes differ from the prepared stapled app")
        usage = observed.get("codex_usage")
        if (not isinstance(usage, dict) or
                set(usage) != {"success", "helper_path", "evidence_path", "evidence_sha256"} or
                usage.get("success") is not True):
            raise ValueError("Functional smoke requires a successful live Codex usage read")
        helper = Path(usage.get("helper_path", ""))
        if not helper.is_absolute() or not helper.is_file():
            raise ValueError("Functional smoke helper_path must identify the live Codex helper used")
        evidence = Path(usage.get("evidence_path", ""))
        if (not evidence.is_absolute() or not evidence.is_file() or
                not re.fullmatch(r"[0-9a-f]{64}", usage.get("evidence_sha256", "")) or
                sha(evidence) != usage["evidence_sha256"]):
            raise ValueError("Functional smoke must bind the successful live usage-read evidence file")
        visual = observed.get("visual")
        if (not isinstance(visual, dict) or set(visual) != {"result", "notes"} or
                visual.get("result") != "pass" or not isinstance(visual.get("notes"), str) or
                not visual["notes"].strip()):
            raise ValueError("Functional smoke requires an explicit passing operator visual result")
        destination = args.release_dir / "functional-smoke.json"
        shutil.copy2(args.observed, destination)
        receipt["functional_smoke"] = {"artifact_manifest": artifact_digest(args.release_dir, receipt),
                                       "observed_sha256": sha(destination)}
        receipt.pop("approval", None)
        write_json(args.release_dir / "receipt.json", receipt)
    return {"recorded": str(destination), "zip_sha256": expected_zip,
            "version": receipt["identity"]["version"], "build": receipt["identity"]["build"]}


def plan(release_dir):
    receipt = ready(release_dir)
    validate_smoke(release_dir, receipt)
    if not is_approved(release_dir, receipt):
        raise ValueError("Review the prepared build and exact editorial packet, then record the operator approval")
    version = receipt["identity"]["version"]
    return {"release": f'v{version}', "build": receipt["identity"]["build"],
            "targets": receipt["targets"], "source": str(release_dir / "publication"),
            "pages": str(release_dir / "publication/website"),
            "release_asset": str(release_dir / "publication/website/downloads/CodexWeeklyReset.zip"),
            "release_notes": str(release_dir / f"publication/docs/release-notes/{version}.html"),
            "editorial": str(release_dir / "editorial"),
            "approval_sha256": receipt["approval"]["review_sha256"],
            "manifest_sha256": hashlib.sha256(json.dumps(receipt["publication_files"], sort_keys=True).encode()).hexdigest(),
            "approval": f'Ship Codex Weekly Reset {version} build {receipt["identity"]["build"]} everywhere from this receipt.',
            "order": ["Prepare source and Pages reviews from the frozen publication tree",
                      "Preserve private source through its development keeper; integrate the public source review",
                      "Create/reuse matching version tag and GitHub Release draft; upload the exact asset",
                      "Publish GitHub Release and integrate Pages; post only the approved announcement destination",
                      "Verify hosted bytes, approved text and source/Pages/tag refs before reporting complete"]}


def verify_copy(args):
    receipt = ready(args.release_dir)
    expected = receipt["publication_files"]
    root = args.checkout.resolve()
    if args.pages:
        expected = {k[len("website/"):]: v for k, v in expected.items() if k.startswith("website/")}
    actual = files(root, ignore_git=True)
    # Git-owned control files are not publication content.
    actual = {k: v for k, v in actual.items() if not k.startswith(".git/") and k != ".git"}
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])
        raise ValueError(json.dumps({"missing": missing, "extra": extra, "changed": changed}))
    return {"verified": "pages" if args.pages else "public-source", "files": len(expected)}


def verify_live(args):
    receipt = ready(args.release_dir)
    base = receipt["targets"]["website"]
    website = args.release_dir / "publication/website"
    urls = {base + urllib.parse.quote(p.relative_to(website).as_posix()): sha(p)
            for p in website.rglob("*") if p.is_file()}
    version = receipt["identity"]["version"]
    repo = receipt["targets"]["github_repository"]
    urls[f"https://github.com/{repo}/releases/download/v{version}/CodexWeeklyReset.zip"] = sha(website / "downloads/CodexWeeklyReset.zip")
    failures = []
    for url, expected in sorted(urls.items()):
        try:
            request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "CodexWeeklyReset-release-verifier"})
            with urllib.request.urlopen(request, timeout=45) as response:
                digest = hashlib.sha256()
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != expected:
                failures.append({"url": url, "error": "SHA-256 differs"})
        except (OSError, ValueError) as error:
            failures.append({"url": url, "error": str(error)})
    if failures:
        raise ValueError(json.dumps({"pending_or_failed": failures}))
    return {"verified_urls": len(urls), "build": receipt["identity"]["build"],
            "remaining": "Prove source, Pages and tag refs on GitHub and public Gitea through the publication lane."}




class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, data):
        if data.strip():
            self.parts.append(data.strip())


def visible_text(markup):
    parser = TextExtractor()
    parser.feed(markup)
    return " ".join(parser.parts)


def validate_notes(path, version, summary):
    expected = f"Codex Weekly Reset {version} {version}: {summary}"
    if visible_text(path.read_text()) != expected:
        raise ValueError("HTML release note and approved customer summary differ")


EDITORIAL = ("commit", "release", "source-pr", "pages-pr", "announcement")


def validate_editorial(directory, version, summary):
    for name in EDITORIAL:
        doc = json.loads((directory / (name + ".json")).read_text())
        if set(doc) != {"title", "body"} or not all(isinstance(v, str) and v.strip() for v in doc.values()):
            raise ValueError(f"{name} must contain nonempty title and body strings")
        if "\\n" in doc["body"] or "\\r" in doc["body"]:
            raise ValueError(f"{name} contains literal newline escapes; use real paragraphs")
        if "\n" in doc["title"] or "\r" in doc["title"]:
            raise ValueError(f"{name} headline must be a single line")
        if version not in doc["title"]:
            raise ValueError(f"{name} title must identify release {version}")
        if name == "release" and doc["body"].strip() != f"{version}: {summary}":
            raise ValueError("GitHub Release body must be the approved version-prefixed customer benefit")
    headline = json.loads((directory / "commit.json").read_text())["title"]
    if json.loads((directory / "source-pr.json").read_text())["title"] != headline:
        raise ValueError("Source PR and release commit must use the same reviewed headline")


def approval_digest(receipt):
    selected = {k: receipt.get(k) for k in ("identity", "targets", "summary", "tested_files", "public_files", "publication_files", "editorial_files", "note_review_sha256", "functional_smoke")}
    return hashlib.sha256(json.dumps(selected, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def render_review(release_dir, receipt):
    smoke = validate_smoke(release_dir, receipt)
    chunks = [f'# Review Codex Weekly Reset {receipt["identity"]["version"]} build {receipt["identity"]["build"]}',
              "This approval binds the tested app, prepared downloads, public source, destinations and exact text below.",
              "Destinations: " + json.dumps(receipt["targets"], sort_keys=True),
              "## Final customer ZIP functional smoke", json.dumps(smoke, sort_keys=True, indent=2)]
    for name in EDITORIAL:
        doc = json.loads((release_dir / "editorial" / (name + ".json")).read_text())
        chunks.extend([f"## {name}", "Title: " + doc["title"], doc["body"]])
    version = receipt["identity"]["version"]
    chunks.extend(["## Sparkle release note", (release_dir / f"publication/docs/release-notes/{version}.html").read_text(),
                   "## Website and README", (release_dir / "publication/README.md").read_text(),
                   visible_text((release_dir / "publication/website/index.html").read_text()),
                   "## Approval identity", approval_digest(receipt)])
    return "\n\n".join(chunks) + "\n"


def is_approved(release_dir, receipt):
    approval = receipt.get("approval", {})
    if not isinstance(approval, dict) or approval.get("manifest") != approval_digest(receipt):
        return False
    try:
        expected = render_review(release_dir, receipt)
    except (ValueError, KeyError, OSError, json.JSONDecodeError):
        return False
    path = release_dir / "REVIEW.md"
    return (path.is_file() and path.read_text() == expected and
            approval.get("review_sha256") == hashlib.sha256(expected.encode()).hexdigest())


def review(args):
    receipt = ready(args.release_dir)
    text = render_review(args.release_dir, receipt)
    path = args.release_dir / "REVIEW.md"
    path.write_text(text)
    return {"review": str(path), "review_sha256": hashlib.sha256(text.encode()).hexdigest()}


def approve(args):
    with locked(args.release_dir):
        receipt = ready(args.release_dir)
        text = render_review(args.release_dir, receipt)
        digest = hashlib.sha256(text.encode()).hexdigest()
        if args.review_sha256 != digest or not (args.release_dir / "REVIEW.md").is_file() or (args.release_dir / "REVIEW.md").read_text() != text:
            raise ValueError("The reviewed packet changed; obtain a new operator review")
        receipt["approval"] = {"manifest": approval_digest(receipt), "review_sha256": digest}
        write_json(args.release_dir / "receipt.json", receipt)
    return {"approved": digest, "publication": "Use plan to execute the already-authorized host operations"}



def verify_headlines(args):
    receipt = ready(args.release_dir)
    if not is_approved(args.release_dir, receipt):
        raise ValueError("No matching headline approval")
    if not re.fullmatch(r"[0-9a-f]{40}", args.base):
        raise ValueError("Headline verification requires the exact reviewed base commit")
    checkout = args.checkout.resolve()
    paths = run("git", "-C", checkout, "diff", "--name-only", "-z", args.base, "HEAD").split("\0")
    paths = [path for path in paths if path]
    if not paths:
        raise ValueError("No changed paths relative to the reviewed base")
    expected = json.loads((args.release_dir / "editorial/commit.json").read_text())["title"]
    mismatches = []
    for path in paths:
        title = run("git", "-C", checkout, "log", "-1", "--format=%s", "HEAD", "--", path).rstrip("\n")
        if title != expected:
            mismatches.append({"path": path, "title": title})
    if mismatches:
        raise ValueError(json.dumps({"headline_mismatches": mismatches}))
    return {"verified_paths": len(paths), "headline": expected,
            "head": run("git", "-C", checkout, "rev-parse", "HEAD").strip()}


def verify_text(args):
    receipt = ready(args.release_dir)
    if not is_approved(args.release_dir, receipt):
        raise ValueError("No matching editorial approval")
    observed = json.loads(args.observed.read_text())
    for name in EDITORIAL:
        expected = json.loads((args.release_dir / "editorial" / (name + ".json")).read_text())
        if name == "commit":
            # Every new source commit carrying released paths must use the reviewed headline.
            titles = observed.get(name, {}).get("titles", [])
            if not titles or any(title != expected["title"] for title in titles):
                raise ValueError("Published commit headlines differ from the approved release headline")
            continue
        if name == "announcement" and not receipt["targets"]["discussion"]["enabled"]:
            if observed.get(name) != {"status": "disabled"}:
                raise ValueError("Announcement destination is disabled; record that disposition explicitly")
            continue
        actual = observed.get(name, {})
        if actual.get("title") != expected["title"] or actual.get("body", "").replace("\r\n", "\n") != expected["body"].replace("\r\n", "\n"):
            raise ValueError(f"Published {name} differs from the approved title/body")
    return {"verified": "approved editorial text", "announcement": "published" if receipt["targets"]["discussion"]["enabled"] else "disabled"}



def finish_revision(release_dir, expected_operation=None):
    journal_path = release_dir / "pending-revision.json"
    journal = json.loads(journal_path.read_text())
    operation = journal.get("operation", "revise-text")
    if expected_operation is not None and operation != expected_operation:
        raise ValueError(f"Pending revision belongs to {operation}; resume it with that command")
    if not re.fullmatch(r"editorial-revision-[a-zA-Z0-9_-]+", journal["staging"]):
        raise ValueError("Invalid revision staging identity")
    staging = release_dir / journal["staging"]
    receipt = journal["receipt"]
    for name in ("public", "editorial"):
        if files(staging / name) != receipt[name + "_files"]:
            raise ValueError("Revision staging changed; retain the journal for inspection")
    removable = {"prepared-website", "publication", "functional-smoke.json", "REVIEW.md"}
    if any(name not in removable for name in journal.get("remove", [])):
        raise ValueError("Revision journal contains an unsafe removal target")
    # The journal owns these generated snapshot directories and keeps pristine
    # replacement copies until the new receipt is durably recorded.
    for name in ("public", "editorial"):
        target = release_dir / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(staging / name, target)
    for name in journal.get("remove", []):
        target = release_dir / name
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
    write_json(release_dir / "receipt.json", receipt)
    journal_path.unlink()
    shutil.rmtree(staging)


def revise_text(args):
    with locked(args.release_dir):
        if getattr(args, "resume", False):
            finish_revision(args.release_dir, "revise-text")
        else:
            if not args.editorial or not args.notes or not args.summary:
                raise ValueError("Text revision needs editorial, notes and summary inputs")
            receipt = load(args.release_dir)
            check_inputs(args.release_dir, receipt)
            if receipt["state"] not in ("captured", "signed", "submitted", "accepted", "stapled", "finalized", "ready"):
                raise ValueError("Reconcile the uncertain notary submission before revising text")
            version = receipt["identity"]["version"]
            validate_editorial(args.editorial, version, args.summary)
            validate_notes(args.notes, version, args.summary)
            temporary = Path(tempfile.mkdtemp(prefix="editorial-revision-", dir=args.release_dir))
            try:
                shutil.copytree(args.release_dir / "public", temporary / "public")
                shutil.copytree(args.editorial, temporary / "editorial")
                shutil.copy2(args.notes, temporary / f"public/docs/release-notes/{version}.html")
                refresh_labels(temporary / "public", version, args.summary)
                receipt.update(summary=args.summary, public_files=files(temporary / "public"), editorial_files=files(temporary / "editorial"))
                receipt.pop("approval", None)
                receipt.pop("publication_files", None)
                receipt.pop("prepared_files", None)
                if receipt["state"] in ("ready", "finalized"):
                    receipt["state"] = "stapled"
                write_json(args.release_dir / "pending-revision.json", {
                    "operation": "revise-text", "staging": temporary.name, "receipt": receipt})
            except BaseException:
                if not (args.release_dir / "pending-revision.json").exists():
                    shutil.rmtree(temporary)
                raise
            finish_revision(args.release_dir, "revise-text")
    return status(args.release_dir)


def refresh_source(args):
    release_dir = args.release_dir.resolve()
    with locked(release_dir):
        if getattr(args, "resume", False):
            finish_revision(release_dir, "refresh-source")
        else:
            receipt = load(release_dir)
            check_inputs(release_dir, receipt)
            if receipt["state"] == "ready":
                receipt = ready(release_dir)
            elif receipt["state"] != "stapled":
                raise ValueError("Source refresh requires a stapled or ready release")
            if "approval" in receipt:
                raise ValueError("Source refresh is blocked after final release approval")

            app = release_dir / "signed" / APP_NAME
            if (files(app) != receipt["stapled_files"] or identity(app) != receipt["identity"] or
                    sha(release_dir / receipt["notary_archive"]) != receipt["notary_sha256"]):
                raise ValueError("Signed, submitted, or stapled release evidence changed")

            root = args.root.resolve(strict=True)
            targets = json.loads((root / "docs/release/targets.json").read_text())
            validate_targets(targets)
            if targets != receipt["targets"]:
                raise ValueError("Publication targets changed after release capture")

            version = receipt["identity"]["version"]
            frozen_note = release_dir / f"public/docs/release-notes/{version}.html"
            current_note = root / f"docs/release-notes/{version}.html"
            validate_notes(current_note, version, receipt["summary"])
            if current_note.read_bytes() != frozen_note.read_bytes():
                raise ValueError("Approved release note changed after release capture")
            validate_editorial(release_dir / "editorial", version, receipt["summary"])

            provenance_path = release_dir / "tested" / APP_NAME / "Contents/Resources/BuildProvenance.json"
            provenance = json.loads(provenance_path.read_text())
            if (set(provenance) != {"schema", "source_commit", "source_files"} or
                    provenance.get("schema") != 1):
                raise ValueError("Unsupported tested build provenance")
            tested_runtime = provenance["source_files"]
            if source_files(release_dir / "public") != tested_runtime:
                raise ValueError("Frozen public runtime source differs from the tested app")
            if source_files(root) != tested_runtime:
                raise ValueError("Current runtime source differs from the tested app")

            root_snapshot = public_input_files(root)
            temporary = Path(tempfile.mkdtemp(prefix="editorial-revision-", dir=release_dir))
            try:
                copy_public(root, temporary / "public")
                if public_input_files(root) != root_snapshot:
                    raise ValueError("Public source changed during source refresh")
                refresh_labels(temporary / "public", version, receipt["summary"])
                if source_files(temporary / "public") != tested_runtime:
                    raise ValueError("Refreshed public runtime source differs from the tested app")
                shutil.copytree(release_dir / "editorial", temporary / "editorial")

                new_public_files = files(temporary / "public")
                changed_paths = sorted(
                    path for path in set(receipt["public_files"]) | set(new_public_files)
                    if receipt["public_files"].get(path) != new_public_files.get(path)
                )
                runtime_scripts = {"script/build_and_run.sh", "script/pack_icns.py"}
                def allowed_refresh_path(path):
                    release_tool = path.startswith("script/") and path not in runtime_scripts
                    optional_public = any(
                        path == name or path.startswith(name + "/") for name in OPTIONAL_PUBLIC_PATHS)
                    return release_tool or optional_public
                if any(not allowed_refresh_path(path) for path in changed_paths):
                    raise ValueError("Source refresh may change release tooling or optional public policy files only")

                revised = dict(receipt)
                revised["state"] = "stapled"
                revised["public_files"] = new_public_files
                revised["source_refresh"] = {
                    "prior_public_manifest_sha256": manifest_sha256(receipt["public_files"]),
                    "new_public_manifest_sha256": manifest_sha256(new_public_files),
                    "changed_paths": changed_paths,
                }
                for key in ("prepared_files", "publication_files", "functional_smoke"):
                    revised.pop(key, None)
                write_json(release_dir / "pending-revision.json", {
                    "operation": "refresh-source",
                    "staging": temporary.name,
                    "receipt": revised,
                    "remove": ["prepared-website", "publication", "functional-smoke.json", "REVIEW.md"],
                })
            except BaseException:
                if not (release_dir / "pending-revision.json").exists():
                    shutil.rmtree(temporary)
                raise
            finish_revision(release_dir, "refresh-source")
    return status(release_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    capture_parser = sub.add_parser("capture", help="Freeze the selected tested app and public source; no signing or upload")
    capture_parser.add_argument("--app", type=Path, required=True)
    capture_parser.add_argument("--release-dir", type=Path, required=True)
    capture_parser.add_argument("--root", type=Path, default=ROOT)
    capture_parser.add_argument("--config", type=Path, default=ROOT / "docs/release/targets.json")
    capture_parser.add_argument("--editorial", type=Path, required=True, help="Directory with commit.json, release.json, source-pr.json, pages-pr.json, announcement.json")
    capture_parser.add_argument("--note-review", type=Path, required=True, help="Approved pre-build customer-note review directory")
    capture_parser.add_argument("--summary", required=True, help="One customer-facing sentence for README and website")
    note_parser = sub.add_parser("review-note", help="Render the customer note for approval before building a release candidate")
    note_parser.add_argument("--notes", type=Path, required=True)
    note_parser.add_argument("--review-dir", type=Path, required=True)
    note_parser.add_argument("--version", required=True)
    note_parser.add_argument("--summary", required=True)
    approve_note_parser = sub.add_parser("approve-note", help="Record explicit approval of the pre-build customer note")
    approve_note_parser.add_argument("--review-dir", type=Path, required=True)
    approve_note_parser.add_argument("--review-sha256", required=True)
    for name in ("prepare", "status", "plan", "record-smoke", "verify-live", "verify-copy", "attach-notary", "review", "approve", "verify-text", "revise-text", "refresh-source", "retry-upload", "verify-headlines"):
        command = sub.add_parser(name)
        command.add_argument("--release-dir", type=Path, required=True)
        if name == "prepare":
            command.add_argument("--notary-profile", required=True)
            command.add_argument("--tools-dir", type=Path, default=ROOT / ".build/artifacts/sparkle/Sparkle/bin")
            command.add_argument("--team", default="A9FAXYYTNZ")
            command.add_argument("--signing-identity", default="Developer ID Application: R&D Solutions LLC (A9FAXYYTNZ)")
            command.add_argument("--sparkle-account", default="ed25519")
        elif name == "verify-headlines":
            command.add_argument("--checkout", type=Path, required=True)
            command.add_argument("--base", required=True)
        elif name == "verify-copy":
            command.add_argument("--checkout", type=Path, required=True)
            command.add_argument("--pages", action="store_true")
        elif name == "retry-upload":
            command.add_argument("--confirmed-not-submitted", action="store_true")
            command.add_argument("--notary-profile", required=True)
        elif name == "revise-text":
            command.add_argument("--resume", action="store_true")
            command.add_argument("--editorial", type=Path)
            command.add_argument("--notes", type=Path)
            command.add_argument("--summary")
        elif name == "refresh-source":
            command.add_argument("--resume", action="store_true")
            command.add_argument("--root", type=Path, default=ROOT)
        elif name == "approve":
            command.add_argument("--review-sha256", required=True)
        elif name == "verify-text":
            command.add_argument("--observed", type=Path, required=True, help="JSON containing fetched title/body objects for each editorial surface")
        elif name == "record-smoke":
            command.add_argument("--observed", type=Path, required=True, help="JSON containing observed launch, live usage-read and visual evidence")
        elif name == "attach-notary":
            command.add_argument("--submission-id", required=True)
    args = parser.parse_args()
    try:
        if args.command in ("status", "plan"):
            result = {"status": status, "plan": plan}[args.command](args.release_dir)
        else:
            result = {"review-note": review_note, "approve-note": approve_note,
                      "capture": capture, "prepare": prepare, "record-smoke": record_smoke, "verify-live": verify_live,
                      "verify-copy": verify_copy, "attach-notary": attach_notary,
                      "review": review, "approve": approve, "verify-text": verify_text, "revise-text": revise_text,
                      "refresh-source": refresh_source, "retry-upload": retry_upload,
                      "verify-headlines": verify_headlines}[args.command](args)
        print(json.dumps(result, separators=(",", ":")))
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.CalledProcessError, ET.ParseError) as error:
        print(f"Release blocked: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
