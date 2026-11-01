#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.01, AC-28.02, AC-28.03, AC-28.04; US-30, AC-30.01, AC-30.02, AC-30.03; US-27, AC-27.04.
"""Build a dependency-free, local-only product page from reviewed project assets.

The page is assembled from three sources that must agree, so the published page cannot lag the product: the
confirmed stories in docs/requirements.md (a section may only present confirmed stories, and a confirmed story that
declares its section must appear there), facts read from the Swift sources (the agents, messengers and skins the app
offers and its macOS target), and the stills rendered from the real interface. A build fails when they drift.
"""
import argparse
import json
import re
import shutil
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
FIELDS = {"schemaVersion", "repositoryURL", "releaseURL", "supportURL"}
RELEASE_TAG = re.compile(r"v[0-9A-Za-z.+-]+")


def load_config(path, release_tag=None):
    """The owner-approved destinations; `release_tag` names a published GitHub Release whose page becomes the download."""
    data = json.loads(path.read_text())
    if release_tag is not None:
        if not isinstance(data, dict) or not isinstance(data.get("repositoryURL"), str):
            raise ValueError("A release link needs the repository destination")
        if not RELEASE_TAG.fullmatch(release_tag):
            raise ValueError("Invalid release tag: " + release_tag)
        derived = data["repositoryURL"].rstrip("/") + "/releases/tag/" + release_tag
        if data.get("releaseURL") not in (None, derived):
            raise ValueError("The configured release destination differs from the published release")
        data["releaseURL"] = derived
    return validate_config(data)


def validate_config(data):
    if not isinstance(data, dict) or data.get("schemaVersion") != 1 or set(data) - FIELDS:
        raise ValueError("Unsupported website configuration")
    result = {}
    for key in FIELDS - {"schemaVersion"}:
        value = data.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or len(value) > 2048 or any(ord(char) < 33 for char in value):
            raise ValueError("Invalid website destination: " + key)
        url = urlsplit(value)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.port not in (None, 443):
            raise ValueError("Website destinations require HTTPS without credentials")
        if key in {"repositoryURL", "releaseURL"}:
            pattern = r"/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"
            if key == "releaseURL":
                pattern += r"/releases(?:/latest|/tag/v[0-9A-Za-z.+-]+)?"
            match = re.fullmatch(pattern + r"/?", url.path)
            if url.hostname != "github.com" or match is None or any(not part.strip(".") for part in match.groups()):
                raise ValueError("Use the actual GitHub repository or release destination")
        result[key] = value
    if "repositoryURL" in result and "releaseURL" in result:
        source = urlsplit(result["repositoryURL"]).path.strip("/").split("/")[:2]
        release = urlsplit(result["releaseURL"]).path.strip("/").split("/")[:2]
        if [part.lower() for part in source] != [part.lower() for part in release]:
            raise ValueError("Source and download destinations must use the same GitHub repository")
    return result


def swift_titles(source, enum=None, marker=None):
    """The `title` switch of one Swift enum, as (case, title) pairs in source order: the enum named `enum`, or the
    one whose body contains `marker`."""
    for found in re.finditer(r"(?ms)^(?:public )?enum (\w+)\b[^\n]*\{\n(.*?)^\}", source):
        name, body = found.groups()
        if (enum is not None and name != enum) or (marker is not None and marker not in body):
            continue
        switch = re.search(r"var title: String \{\s*switch self \{(.*?)\}\s*\}", body, re.S)
        pairs = re.findall(r'case \.([a-z][A-Za-z0-9]*): "([^"]+)"', switch.group(1)) if switch else []
        if pairs:
            return pairs
    raise ValueError("Native fact format changed: " + (enum or marker or "enum"))


def native_facts():
    """What the app offers, read from the sources that define it, in the order the app lists them."""
    preferences = (ROOT / "Sources/LunletDesktop/PreferencesStore.swift").read_text()
    skins = (ROOT / "Sources/LunletDesktop/SkinCatalog.swift").read_text()
    builtins = re.search(r"builtins: \[SkinDefinition\] = \[(.*?)\]\n", skins, re.S)
    pairs = re.findall(r'\.init\(id: "([a-z0-9-]+)", title: "([^"]+)", kind:', builtins.group(1)) if builtins else []
    if not pairs:
        raise ValueError("Native fact format changed: SkinCatalog.builtins")
    target = re.search(r"\.macOS\(\.v(\d+)\)", (ROOT / "Package.swift").read_text())
    if target is None:
        raise ValueError("Native fact format changed: Package.swift platforms")
    return {"agents": swift_titles(preferences, marker="var sessionProvider: SessionProvider"),
            "channels": swift_titles(preferences, enum="CommunicationChannel"),
            "skins": pairs, "macOS": target.group(1)}


def screenshots(facts):
    """The stills the page shows, named after the sources' own identifiers; scripts/render-site-assets.sh produces them."""
    return (("hero-overview.jpg", "panel-overview.jpg", "cue-island.jpg")
            + tuple("panel-" + agent + ".jpg" for agent, _ in facts["agents"])
            + tuple("notch-" + skin + ".png" for skin, _ in facts["skins"])
            + tuple("phone-" + channel + "-" + state + ".png"
                    for channel, _ in facts["channels"] for state in ("notice", "replied", "delivered")))


def join_words(items, conjunction):
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " " + conjunction + " " + items[-1]


def render_page(page, facts):
    """The page markup with its facts filled in. Hand-written blocks that exist once per agent, messenger or skin must
    cover exactly the set the sources define, so adding one in code fails the build until the page presents it."""
    agents = [title for _, title in facts["agents"]]
    channels = facts["channels"]
    tabs = "".join('<button type="button" role="tab" id="tab-{0}" aria-selected="{1}"{2} aria-controls="panel-{0}">{3}</button>'
                   .format(channel, "true" if index == 0 else "false", "" if index == 0 else ' tabindex="-1"', title)
                   for index, (channel, title) in enumerate(channels))
    values = {
        "agents": join_words(agents, "and"),
        "agentsLead": {1: "One agent", 2: "Both agents", 3: "All three agents"}.get(len(agents), "Every agent"),
        "channels": join_words((title for _, title in channels), "or"),
        "skins": join_words((title for _, title in facts["skins"]), "or"),
        "macos": facts["macOS"],
        "tabs": tabs,
    }

    def replace(match):
        if match.group(1) not in values:
            raise ValueError("Unknown page fact: " + match.group(1))
        return values[match.group(1)]
    rendered = re.sub(r"\{\{(\w+)\}\}", replace, page)
    if "{{" in rendered:
        raise ValueError("A page fact was left unrendered")
    expectations = [
        ("messenger panel", r'<div class="panel" role="tabpanel" id="panel-([a-z0-9-]+)"', channels),
        ("agent page figure", r'<figure data-agent="([a-z0-9-]+)"', facts["agents"]),
        ("skin figure", r'<figure data-skin="([a-z0-9-]+)"', facts["skins"]),
    ]
    for kind, pattern, items in expectations:
        found = re.findall(pattern, rendered)
        if sorted(found) != sorted(identifier for identifier, _ in items):
            raise ValueError("The page's " + kind + "s do not match the sources: page has "
                             + ", ".join(sorted(found)) + "; sources define " + ", ".join(identifier for identifier, _ in items))
    for skin, title in facts["skins"]:
        figure = re.search(r'<figure data-skin="' + skin + r'">.*?</figure>', rendered, re.S)
        if "<figcaption>" + title + "</figcaption>" not in figure.group(0):
            raise ValueError("The skin figure for " + skin + " must be captioned " + title)
    return rendered


def story_index(requirements):
    """Each story's status, and the page section a story declares with `Product page: #section.`"""
    statuses, declared = {}, {}
    parts = re.split(r"(?m)^### (US-\d+):[^\n]*\n", requirements)
    for index in range(1, len(parts), 2):
        story, body = parts[index:index + 2]
        status = re.search(r"(?m)^Status: (\w+)\.", body)
        statuses[story] = status.group(1) if status else "Unknown"
        section = re.search(r"(?m)^Product page: #([a-z][a-z0-9-]*)\.", body)
        if section:
            declared[story] = section.group(1)
    return statuses, declared


def check_stories(page, requirements):
    """A section presents only confirmed stories, and a confirmed story that declares a section is presented there."""
    statuses, declared = story_index(requirements)
    sections, issues = {}, []
    for attributes in re.findall(r"<section\b([^>]*)>", page):
        identifier = re.search(r'\bid="([^"]+)"', attributes)
        listed = re.search(r'\bdata-stories="([^"]*)"', attributes)
        stories = listed.group(1).split() if listed else []
        if identifier is None or not stories:
            issues.append("A page section needs an id and the stories it presents in data-stories: <section" + attributes + ">")
            continue
        sections[identifier.group(1)] = stories
        for story in stories:
            if statuses.get(story) != "Confirmed":
                issues.append("Section #" + identifier.group(1) + " presents a story that is not confirmed: " + story)
    for story, section in sorted(declared.items()):
        if statuses.get(story) != "Confirmed":
            continue
        if section not in sections:
            issues.append(story + " declares product page section #" + section + ", which the page does not have")
        elif story not in sections[section]:
            issues.append(story + " is confirmed, but section #" + section + " does not present it")
    if issues:
        raise ValueError("The product page and the stories disagree:\n" + "\n".join(issues))


def referenced_files(page):
    """Local pictures, video and tracks the page markup references, as paths relative to the page."""
    return set(re.findall(r'(?:src|poster|href)="((?:assets|video)/[^"]+)"', page))


def build(output, config_path=None, release_tag=None):
    config = load_config(config_path or ROOT / "website/config.json", release_tag)
    facts = native_facts()
    page = render_page((ROOT / "website/index.html").read_text(), facts)
    check_stories(page, (ROOT / "docs/requirements.md").read_text())
    # Build into a new directory, so no unrelated files can enter the deployment.
    output.mkdir(parents=True, exist_ok=False)
    (output / "index.html").write_text(page)
    for name in ("style.css", "app.js"):
        shutil.copyfile(ROOT / "website" / name, output / name)
    (output / "video").mkdir()
    for name in ("lunlet-walkthrough.mp4", "lunlet-poster.jpg", "lunlet-captions.vtt"):
        shutil.copyfile(ROOT / "website/video" / name, output / "video" / name)
    (output / "assets").mkdir()
    shutil.copyfile(ROOT / "docs/assets/branding/lunlet-app-icon.png", output / "assets/lunlet-app-icon.png")
    # The product pictures: stills of the real interface with synthetic data, regenerated by scripts/render-site-assets.sh
    # and shared with the README; scripts/check_site_assets.py verifies they match the current sources.
    for name in screenshots(facts):
        shutil.copyfile(ROOT / "docs/assets/screenshots" / name, output / "assets" / name)
    missing = sorted(path for path in referenced_files(page) if not (output / path).is_file())
    if missing:
        raise ValueError("The page references files the build does not ship: " + ", ".join(missing))
    encoded = json.dumps(config, ensure_ascii=True, sort_keys=True).replace("<", "\\u003c")
    (output / "site-config.js").write_text("window.LUNLET_SITE_CONFIG = " + encoded + ";\n")
    (output / ".nojekyll").touch()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".tmp/site", help="A new, empty output directory")
    parser.add_argument("--release-tag", help="The tag of the latest published GitHub Release, whose page becomes the download link")
    options = parser.parse_args()
    try:
        build(options.output, release_tag=options.release_tag)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + "\n")
    print(options.output.resolve())
