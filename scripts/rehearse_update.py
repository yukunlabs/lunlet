#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-35, AC-35.01, AC-35.02; US-27, AC-27.05.
"""Rehearses an update on this Mac before the release is published.

The copy of Lunlet installed here, an earlier release, is pointed at a feed served from this Mac that offers the
packaged candidate, and updates to it through its own updater: the notice, the window, the download, the signature
check, the replacement and the relaunch are the ones a reader of the published feed will get. Nothing is uploaded.

Afterwards it compares what must hold: the installed bundle equals the candidate's archive file for file, its
signature verifies, and the saved settings and the credential files are byte for byte what they were. The feed
override is removed whatever happens.

usage: rehearse_update.py <release directory> <appcast.xml> [--installed /Applications/Lunlet.app] [--minutes 15]

The appcast is the signed one made for publication (docs/releases.md). Only the address of its archive changes for
the rehearsal, so the signature the installed copy checks is the published one.
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from check_appcast import audit

ROOT = Path(__file__).resolve().parent.parent
DOMAIN = "com.lunlet"
CREDENTIALS = Path.home() / "Library/Application Support" / DOMAIN / "credentials"


def local_feed(appcast, address, archive):
    """The appcast with its one archive served from `address`; everything else as signed."""
    pattern = re.compile(r'(<enclosure\b[^>]*\burl=")[^"]*/' + re.escape(archive) + '"')
    if len(pattern.findall(appcast)) != 1:
        raise ValueError("the appcast does not name the archive " + archive + " exactly once")
    return pattern.sub(lambda match: match.group(1) + address + "/" + archive + '"', appcast)


def refusal(installed, manifest):
    """Why this installed copy cannot rehearse the candidate, or None."""
    if installed["preview"] or not installed["feed"]:
        return "the installed copy is a preview and has no updater"
    if int(installed["build"]) >= int(manifest["build"]):
        return (f"the installed copy is build {installed['build']}; the candidate is build {manifest['build']} "
                "and would not be offered to it")
    return None


def differences(first, second):
    """The paths, relative to both bundles, whose file, link or presence differs."""
    def entries(root):
        found = {}
        for directory, names, files in os.walk(root):
            for name in names + files:
                path = Path(directory) / name
                if path.is_symlink():
                    found[path.relative_to(root).as_posix()] = "link " + os.readlink(path)
                elif path.is_file():
                    found[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        return found
    one, two = entries(first), entries(second)
    return sorted(path for path in one.keys() | two.keys() if one.get(path) != two.get(path))


def bundle(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    return {"version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion", "0"),
            "feed": info.get("SUFeedURL"), "preview": info.get("LunletDevelopmentPreview") is not False}


def saved_state():
    """Hashes of what an update must leave alone: the saved settings and the credential files."""
    exported = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True).stdout
    settings = plistlib.loads(exported) if exported else {}
    state = {key: hashlib.sha256(settings[key]).hexdigest() for key in ("preferences.current",) if key in settings}
    if CREDENTIALS.is_dir():
        for path in sorted(CREDENTIALS.iterdir()):
            if path.is_file():
                state["credentials/" + path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return state


def running(app):
    return subprocess.run(["pgrep", "-f", "^" + re.escape(str(app / "Contents/MacOS")) + "/"],
                          capture_output=True).returncode == 0


def quit_lunlet():
    subprocess.run(["osascript", "-e", f'tell application id "{DOMAIN}" to quit'], capture_output=True)
    for _ in range(40):
        if subprocess.run(["pgrep", "-f", "Lunlet.app/Contents/MacOS/Lunlet$"], capture_output=True).returncode != 0:
            return
        time.sleep(0.5)


def main(arguments):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("release", type=Path, help="the directory package-release.sh made")
    parser.add_argument("appcast", type=Path, help="the signed appcast.xml made for publication")
    parser.add_argument("--installed", type=Path, default=Path("/Applications/Lunlet.app"))
    parser.add_argument("--minutes", type=int, default=15, help="how long to wait for the update to be installed")
    options = parser.parse_args(arguments)

    manifest = json.loads((options.release / "manifest.json").read_text(encoding="utf-8"))
    archive = options.release / manifest["updateArchive"]
    appcast = options.appcast.read_text(encoding="utf-8")
    notes = (ROOT / "docs/release-notes" / (manifest["tag"] + ".md")).read_text(encoding="utf-8")
    issues = audit(appcast, manifest, archive.stat().st_size, notes)
    reason = refusal(bundle(options.installed), manifest)
    for issue in issues + ([reason] if reason else []):
        print(issue, file=sys.stderr)
    if issues or reason:
        return 2

    before = saved_state()
    served = Path(tempfile.mkdtemp(prefix="lunlet-rehearsal-"))
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(served))
    handler.log_message = lambda *_: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    address = f"http://127.0.0.1:{server.server_address[1]}"
    shutil.copyfile(archive, served / archive.name)
    (served / "appcast.xml").write_text(local_feed(appcast, address, archive.name), encoding="utf-8")
    threading.Thread(target=server.serve_forever, daemon=True).start()

    installed = False
    try:
        quit_lunlet()
        subprocess.run(["defaults", "write", DOMAIN, "SUFeedURL", address + "/appcast.xml"], check=True)
        subprocess.run(["open", str(options.installed)], check=True)
        print(f"Lunlet {bundle(options.installed)['version']} is running and reads the rehearsal feed.\n"
              "Choose Update available in the panel's footer, or Settings › About › Check for Updates…, "
              f"then Install Update. Waiting up to {options.minutes} minutes.")
        deadline = time.monotonic() + options.minutes * 60
        while time.monotonic() < deadline:
            if bundle(options.installed)["build"] == manifest["build"] and running(options.installed):
                installed = True
                break
            time.sleep(2)
    finally:
        subprocess.run(["defaults", "delete", DOMAIN, "SUFeedURL"], capture_output=True)
        server.shutdown()

    if not installed:
        shutil.rmtree(served, ignore_errors=True)
        print("The update was not installed in time. The feed override is removed.", file=sys.stderr)
        return 1

    time.sleep(8)  # The new version reads its settings and credentials as it starts.
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(served / "expected")], check=True)
    changed = differences(served / "expected" / options.installed.name, options.installed)
    signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(options.installed)],
                               capture_output=True).returncode == 0
    after = saved_state()
    shutil.rmtree(served, ignore_errors=True)
    results = [("the installed bundle equals the candidate's archive", not changed),
               ("its signature verifies", signature),
               ("the saved settings are unchanged", before.get("preferences.current") == after.get("preferences.current")),
               ("the credential files are unchanged",
                {k: v for k, v in before.items() if k.startswith("credentials/")}
                == {k: v for k, v in after.items() if k.startswith("credentials/")}),
               ("the new version is running", running(options.installed))]
    for claim, holds in results:
        print(("ok   " if holds else "FAIL ") + claim)
    for path in changed[:10]:
        print("     differs: " + path)
    print("By eye: the update window opened in front of the other windows, and showed the version and the notes.")
    return 0 if all(holds for _, holds in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
