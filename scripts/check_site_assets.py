#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.02, AC-28.04.
"""Verify that the product stills and the film were rendered from the current sources.

Each render records a manifest of its inputs (the Swift sources, the render scenery, the icon, the render script) and
its outputs. Any later change to an input makes the pictures stale until the render runs again: stale stills fail
this check, so a pull request that changes the interface also carries the pictures the page shows. A stale film is
reported as a warning, because re-rendering a minute of film is a longer owner decision.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_site import native_facts, screenshots  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RENDER_INPUTS = (
    "Package.swift", "Sources/**/*.swift", "Resources/Info.plist", "docs/assets/branding/lunlet-app-icon.png",
    "Tests/LunletDesktopTests/PanelPageRenderTests.swift", "Tests/LunletDesktopTests/ProductFilmCompositor.swift",
    "Tests/LunletDesktopTests/ProductFilmRenderTests.swift", "Tests/LunletDesktopTests/ProductFilmScenery.swift",
)
STILLS = {
    "name": "stills", "manifest": "docs/assets/screenshots/manifest.json",
    "inputs": RENDER_INPUTS + ("Tests/LunletDesktopTests/ChannelChatScenery.swift",
                               "Tests/LunletDesktopTests/SiteAssetRenderTests.swift", "scripts/render-site-assets.sh"),
    "render": "scripts/render-site-assets.sh",
}
FILM = {
    "name": "film", "manifest": "website/video/manifest.json",
    "inputs": RENDER_INPUTS + ("scripts/render-film.sh",),
    "outputs": ("website/video/lunlet-walkthrough.mp4", "website/video/lunlet-poster.jpg", "website/video/lunlet-captions.vtt"),
    "render": "scripts/render-film.sh",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(root, patterns):
    """Each matching file's digest, keyed by its path relative to `root`; a missing file is simply absent."""
    result = {}
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.is_file():
                result[path.relative_to(root).as_posix()] = digest(path)
    return result


def compare(recorded, current):
    """What changed since the manifest was written, as readable lines."""
    changes = []
    for path in sorted(set(recorded) | set(current)):
        if path not in current:
            changes.append("removed: " + path)
        elif path not in recorded:
            changes.append("added: " + path)
        elif recorded[path] != current[path]:
            changes.append("changed: " + path)
    return changes


def outputs(kind, root):
    if kind is STILLS or kind.get("name") == "stills":
        return tuple("docs/assets/screenshots/" + name for name in screenshots(native_facts()))
    return kind["outputs"]


def state(kind, root):
    return {"schemaVersion": 1, "inputs": fingerprint(root, kind["inputs"]), "outputs": fingerprint(root, outputs(kind, root))}


def staleness(kind, root):
    """Lines describing why the render is stale, or an empty list when it matches the manifest."""
    manifest = root / kind["manifest"]
    if not manifest.is_file():
        return ["no manifest: " + kind["manifest"]]
    try:
        recorded = json.loads(manifest.read_text())
    except ValueError:
        return ["unreadable manifest: " + kind["manifest"]]
    if recorded.get("schemaVersion") != 1:
        return ["unsupported manifest: " + kind["manifest"]]
    current = state(kind, root)
    missing = [path for path in outputs(kind, root) if path not in current["outputs"]]
    return ([ "missing output: " + path for path in missing]
            + compare(recorded.get("inputs", {}), current["inputs"])
            + compare(recorded.get("outputs", {}), current["outputs"]))


def write_manifest(kind, root):
    current = state(kind, root)
    missing = [path for path in outputs(kind, root) if path not in current["outputs"]]
    if missing:
        raise ValueError("Cannot record a render that lacks " + ", ".join(missing))
    (root / kind["manifest"]).write_text(json.dumps(current, indent=1, sort_keys=True) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stills", action="store_true", help="check or record only the product stills")
    parser.add_argument("--film", action="store_true", help="check or record only the film")
    parser.add_argument("--write", action="store_true", help="record the current inputs and outputs as the render's manifest")
    parser.add_argument("--strict-film", action="store_true", help="treat a stale film as a failure rather than a warning")
    parser.add_argument("--quiet", action="store_true", help="print nothing; the exit status says whether a render is stale")
    options = parser.parse_args(argv)
    kinds = [kind for kind, selected in ((STILLS, options.stills), (FILM, options.film)) if selected] or [STILLS, FILM]
    failed = False
    for kind in kinds:
        if options.write:
            write_manifest(kind, ROOT)
            if not options.quiet:
                print("Recorded the " + kind["name"] + " manifest: " + kind["manifest"])
            continue
        stale = staleness(kind, ROOT)
        if not stale:
            if not options.quiet:
                print("The " + kind["name"] + (" match" if kind is STILLS else " matches") + " the current sources.")
            continue
        severity = "error" if kind is STILLS or options.strict_film else "warning"
        failed = failed or severity == "error"
        if not options.quiet:
            # The GitHub Actions annotation form is also a plain readable line locally.
            print("::" + severity + " file=" + kind["manifest"] + "::The " + kind["name"] + (" were" if kind is STILLS else " was")
                  + " rendered from other sources; run "
                  + kind["render"] + " and commit the result. " + "; ".join(stale[:12])
                  + (" (and " + str(len(stale) - 12) + " more)" if len(stale) > 12 else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        sys.exit(str(error))
