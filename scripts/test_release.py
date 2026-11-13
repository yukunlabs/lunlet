#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.01, AC-27.03, AC-27.05; US-29, AC-29.03.
# Refs: US-35, AC-35.01, AC-35.03, AC-35.04.
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# A synthetic, well-formed EdDSA public key (32 bytes, base64). It belongs to no signing key.
SYNTHETIC_KEY = "B" * 43 + "="
SYNTHETIC_FEED = "https://example.invalid/lunlet/appcast.xml"
# What every installed copy since v0.1.0 carries and validates updates with; public values, recorded in docs/releases.md.
RELEASE_KEY = "EhftNv8sxDPjDmCQ+FELNAg9SlWVuHMTGpYU29qJwAg="
RELEASE_FEED = "https://github.com/yukunlabs/lunlet/releases/latest/download/appcast.xml"


def notice_mismatches(notice, resolved, license_headers=(), release_document=""):
    """Every place that names a bundled dependency's version, compared with the resolved pin: the notices' table row
    for the pin's repository, a license file's provenance header, and the release document's Sparkle tool version."""
    problems = []
    rows = {link.lower().removesuffix(".git").rstrip("/"): version
            for link, version in re.findall(r"(?m)^\| \[[^\]]+\]\((https://github\.com/[^)]+)\) \| ([^ |]+) \|", notice)}
    for pin in json.loads(resolved)["pins"]:
        location = pin["location"].lower().removesuffix(".git").rstrip("/")
        version, revision = pin["state"]["version"], pin["state"]["revision"]
        if rows.get(location) != version:
            problems.append("NOTICE.md names " + str(rows.get(location)) + " for " + pin["identity"] + ", resolved " + version)
        for header in license_headers:
            named = re.match(r"\S+ ([0-9][0-9A-Za-z.+-]*)\nSource: (https://github\.com/\S+)/tree/([0-9a-f]{40})\n", header)
            if named and named.group(2).lower() == location and (named.group(1), named.group(3)) != (version, revision):
                problems.append("A license header names " + named.group(1) + " at " + named.group(3) + " for " + pin["identity"])
        if pin["identity"] == "sparkle":
            for found in re.findall(r"Sparkle[- ]([0-9]+\.[0-9]+\.[0-9]+)", release_document):
                if found != version:
                    problems.append("docs/releases.md names Sparkle " + found + ", resolved " + version)
    return problems


def debug_entries(executable):
    """Symbol-table entries that exist only for debugging; they name the source and object paths of the build Mac.
    `strip` leaves one such entry of its own in a Swift executable, a fixed marker that names nothing."""
    listing = subprocess.run(["/usr/bin/nm", "-a", str(executable)], capture_output=True, text=True, check=True).stdout
    return [line for line in listing.splitlines() if " - " in line[:20] and not line.endswith(" OPT radr://5614542")]


def search_paths(executable):
    commands = subprocess.run(["/usr/bin/otool", "-l", str(executable)], capture_output=True, text=True, check=True).stdout
    return [line.split()[1] for line in commands.splitlines() if line.strip().startswith("path ") and "(offset" in line]


def build_identifiers(path):
    listing = subprocess.run(["/usr/bin/dwarfdump", "--uuid", str(path)], capture_output=True, text=True, check=True).stdout
    return sorted(" ".join(line.split()[1:3]) for line in listing.splitlines() if line.startswith("UUID: "))


class SyntheticRelease:
    """A throwaway repository holding the real release scripts with an earlier tag and a candidate tag, and a small
    candidate app built with the C compiler and signed by the real signing script. Nothing of Lunlet is built."""

    def __init__(self, directory, *, version="0.2.0", build="2", earlier_build="1", feed=RELEASE_FEED, key=RELEASE_KEY):
        self.directory = Path(directory).resolve()
        self.repository = self.directory / "repository"
        self.tag = "v" + version
        self.feed, self.key = feed, key
        # Git state of whoever runs the tests (a hook, another worktree) never reaches the throwaway repository.
        self.environment = {name: value for name, value in os.environ.items()
                            if not name.startswith("GIT_") and not name.startswith("LUNLET_")}
        self.environment["LUNLET_RELEASE_UNSIGNED"] = "1"
        (self.repository / "scripts").mkdir(parents=True)
        (self.repository / "Resources/third-party").mkdir(parents=True)
        for name in ["package-release.sh", "build-app.sh", "sign-app.sh", "swift-common.sh"]:
            shutil.copy(ROOT / "scripts" / name, self.repository / "scripts" / name)
        (self.repository / ".gitignore").write_text(".tmp/\n")
        for name in ["LICENSE", "NOTICE.md", "Resources/Lunlet.icns", "Resources/third-party/swift-protobuf-license.txt",
                     "Resources/third-party/sparkle-license.txt"]:
            (self.repository / name).write_text("Synthetic text for " + name + "\n")
        self.git("init", "--quiet", "--initial-branch", "main")
        self.commit_source("0.1.0", earlier_build, "v0.1.0")
        self.commit_source(version, build, self.tag)
        self.app = self.directory / "candidate/Lunlet.app"
        self.version, self.build_number = version, build

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repository), "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                               "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *arguments],
                              env=self.environment, capture_output=True, text=True, check=True).stdout

    def commit_source(self, version, build, tag):
        with (ROOT / "Resources/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
        with (self.repository / "Resources/Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        self.git("add", "--all")
        self.git("commit", "--quiet", "--message", "Synthetic " + version)
        self.git("tag", tag)

    def compile(self, compiler, output, *, search=()):
        """One small executable with debug information, as the Swift build leaves its products."""
        source, unit = self.directory / "main.c", self.directory / "main.o"
        if not unit.exists():
            source.write_text("static int helper(void) { return 0; }\nint main(void) { return helper(); }\n")
            subprocess.run([compiler, "-g", "-c", str(source), "-o", str(unit)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([compiler, str(unit), "-o", str(output), *["-Wl,-rpath," + path for path in search]], check=True)

    def build(self, compiler, *, strip=True, symbols=True, search=("@executable_path/../Frameworks", "/usr/lib/swift"),
              swift_compiler=None):
        """The candidate as a release build leaves it: two stripped executables (the app and its hook helper) with
        their debug symbols kept beside the bundle, the notices, the plist and an ad hoc signature. With a Swift
        compiler the app's executable is a small Swift program, which `strip` treats as it treats Lunlet's."""
        notices = self.app / "Contents/Resources/third-party"
        notices.mkdir(parents=True)
        shutil.copy(self.repository / "LICENSE", notices / "lunlet-license.txt")
        for name in ["NOTICE.md", "Resources/third-party/swift-protobuf-license.txt", "Resources/third-party/sparkle-license.txt"]:
            shutil.copy(self.repository / name, notices / Path(name).name)
        for name in ["Lunlet", "lunlet-hook"]:
            executable = self.app / "Contents/MacOS" / name
            if swift_compiler is not None and name == "Lunlet":
                (self.directory / "main.swift").write_text('print("synthetic")\n')
                executable.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run([swift_compiler, "-g", str(self.directory / "main.swift"), "-o", str(executable)],
                               cwd=self.directory, capture_output=True, check=True)
            else:
                self.compile(compiler, executable, search=search)
            if symbols:
                subprocess.run(["/usr/bin/dsymutil", str(executable), "-o", str(self.symbols / (name + ".dSYM"))], check=True)
            if strip:
                subprocess.run(["/usr/bin/strip", "-S", "-x", str(executable)], check=True)
        info = {"CFBundleIdentifier": "com.lunlet", "CFBundleExecutable": "Lunlet", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": self.version, "CFBundleVersion": self.build_number, "LSMinimumSystemVersion": "14.0",
                "LunletDevelopmentPreview": False, "LunletSourceRevision": self.git("rev-parse", "HEAD").strip(),
                "LunletSourceDirty": False, "LunletBuildConfiguration": "release"}
        if self.feed is not None:
            info["SUFeedURL"] = self.feed
        if self.key is not None:
            info["SUPublicEDKey"] = self.key
        with (self.app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        subprocess.run([str(ROOT / "scripts/sign-app.sh"), "--unsigned", "-", str(self.app)], capture_output=True, text=True, check=True)

    @property
    def symbols(self):
        return self.app.parent / (self.app.stem + ".dSYMs")

    def products(self, compiler, *, helper=True):
        """What `swift build` would leave: both executables with search paths into the checkout and the toolchain, a
        framework with Sparkle's layout and the resource bundle."""
        products = self.directory / "products"
        if products.exists():
            shutil.rmtree(products)
        search = [str(self.repository / ".build/release"), "/Library/Developer/Synthetic/usr/lib/swift-6.2/macosx",
                  "/usr/lib/swift", "@loader_path"]
        for name in ["Lunlet"] + (["lunlet-hook"] if helper else []):
            self.compile(compiler, products / name, search=search)
        (products / "SwiftProtobuf_SwiftProtobuf.bundle").mkdir()
        (products / "SwiftProtobuf_SwiftProtobuf.bundle/PrivacyInfo.xcprivacy").write_text("synthetic\n")
        version = products / "Sparkle.framework/Versions/B"
        self.compile(compiler, version / "Autoupdate")
        for bundle, executable in [("XPCServices/Installer.xpc", "Installer"), ("XPCServices/Downloader.xpc", "Downloader"),
                                   ("Updater.app", "Updater")]:
            self.compile(compiler, version / bundle / "Contents/MacOS" / executable)
            with (version / bundle / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "com.lunlet.tests." + executable.lower(), "CFBundleExecutable": executable,
                               "CFBundlePackageType": "XPC!" if bundle.endswith(".xpc") else "APPL"}, file)
        (self.directory / "library.c").write_text("int synthetic(void) { return 0; }\n")
        subprocess.run([compiler, "-dynamiclib", "-install_name", "@rpath/Sparkle.framework/Versions/B/Sparkle",
                        "-o", str(version / "Sparkle"), str(self.directory / "library.c")], check=True)
        (version / "Resources").mkdir()
        with (version / "Resources/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.lunlet.tests.sparkle", "CFBundleExecutable": "Sparkle",
                           "CFBundlePackageType": "FMWK"}, file)
        os.symlink("B", version.parent / "Current")
        for name in ["Sparkle", "Resources"]:
            os.symlink("Versions/Current/" + name, version.parent.parent / name)
        return products

    def run_build(self, compiler, arguments=(), *, helper=True, **variables):
        """Runs the real build script in the throwaway repository with a `swift` that only reports those products."""
        products = self.products(compiler, helper=helper)
        tools = self.directory / "tools"
        tools.mkdir(exist_ok=True)
        swift = tools / "swift"
        swift.write_text('#!/bin/sh\ncase " $* " in *" --show-bin-path "*) printf \'%s\\n\' "$LUNLET_TEST_PRODUCTS" ;; esac\n')
        swift.chmod(0o700)
        environment = dict(self.environment, PATH=str(tools) + os.pathsep + os.environ["PATH"], LUNLET_TEST_PRODUCTS=str(products),
                           **variables)
        result = subprocess.run([str(self.repository / "scripts/build-app.sh"), *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        self.app = self.repository / ".tmp/Lunlet.app"
        return result

    def run_release_build(self, compiler, **variables):
        return self.run_build(compiler, LUNLET_CODE_SIGN_IDENTITY="-", LUNLET_UPDATE_FEED_URL=self.feed,
                              LUNLET_UPDATE_PUBLIC_KEY=self.key, **variables)

    def package(self):
        return subprocess.run([str(self.repository / "scripts/package-release.sh"), str(self.app), self.tag],
                              env=self.environment, capture_output=True, text=True, timeout=120)


def run_build_with_stub_swift(arguments, **variables):
    """Runs build-app.sh with a swift stub that only records being called; returns the result and that fact."""
    with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
        directory = Path(temporary)
        marker = directory / "swift-called"
        swift = directory / "swift"
        swift.write_text('#!/bin/sh\ntouch "$LUNLET_TEST_MARKER"\nexit 97\n')
        swift.chmod(0o700)
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"LUNLET_UPDATE_FEED_URL", "LUNLET_UPDATE_PUBLIC_KEY", "LUNLET_CODE_SIGN_IDENTITY"}}
        environment.update(PATH=str(directory) + os.pathsep + os.environ["PATH"], LUNLET_TEST_MARKER=str(marker), **variables)
        result = subprocess.run([str(ROOT / "scripts/build-app.sh"), *arguments], env=environment,
                                capture_output=True, text=True, timeout=10)
        return result, marker.exists()


class ReleaseBoundaryTests(unittest.TestCase):
    def test_build_rejects_source_and_short_circuit_overrides_before_running_swift(self):
        for arguments in [["--package-path", "/another/checkout"], ["--package-path=/another/checkout"],
                          ["--show-bin-path"], ["--product", "Other"]]:
            with self.subTest(arguments=arguments):
                result, swift_called = run_build_with_stub_swift(["--preview", *arguments])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsupported build option", result.stderr)
                self.assertFalse(swift_called)

    def test_development_preview_cannot_pass_the_public_release_gate(self):
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            app = Path(temporary) / "Lunlet.app"
            (app / "Contents").mkdir(parents=True)
            with (app / "Contents/Info.plist").open('wb') as file:
                plistlib.dump({'LunletDevelopmentPreview': True}, file)
            result = subprocess.run([str(ROOT / 'scripts/package-release.sh'), str(app), 'v0.1.0'],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Development previews cannot become public release artifacts', result.stderr)

    def test_candidate_must_carry_the_update_feed_and_key_installed_copies_already_trust(self):
        # Installed copies validate an update with the key in their own bundle and read the feed in their own bundle,
        # so a release with any other key or feed, however well formed, could never be updated again (AC-35.02).
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        cases = [({"key": SYNTHETIC_KEY}, "update key"), ({"feed": SYNTHETIC_FEED}, "update feed"),
                 ({"feed": None, "key": None}, "update feed"), ({"key": None}, "update key")]
        for overrides, message in cases:
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
                release = SyntheticRelease(temporary, **overrides)
                release.build(compiler)
                result = release.package()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertIn("could never update", result.stderr)
                self.assertFalse((release.repository / ".tmp/releases").exists())

    def test_candidate_build_number_must_exceed_every_earlier_release(self):
        # The appcast offers an update by build number: one that did not increase is never offered to anyone, and
        # the tag is spent (AC-35.02).
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        for build, earlier in [("1", "1"), ("2", "7"), ("2.0", "1"), ("two", "1")]:
            with self.subTest(build=build, earlier=earlier), tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
                release = SyntheticRelease(temporary, build=build, earlier_build=earlier)
                release.build(compiler)
                result = release.package()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("build number", result.stderr)
                self.assertFalse((release.repository / ".tmp/releases").exists())

    def test_the_documented_update_feed_and_key_are_the_ones_the_packager_requires(self):
        script = (ROOT / "scripts/package-release.sh").read_text()
        document = (ROOT / "docs/releases.md").read_text()
        for value in [RELEASE_KEY, RELEASE_FEED]:
            self.assertIn(value, script)
            self.assertIn(value, document)

    def test_a_clean_candidate_with_the_release_feed_key_and_a_higher_build_is_packaged(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            release.build(compiler)
            result = release.package()
            self.assertEqual(result.returncode, 0, result.stderr)
            output = Path(result.stdout.splitlines()[0])
            self.assertEqual(output.parent, release.repository / ".tmp/releases")
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual((manifest["tag"], manifest["version"], manifest["build"]), ("v0.2.0", "0.2.0", "2"))
            self.assertEqual(manifest["updateFeed"], RELEASE_FEED)
            self.assertEqual(manifest["signing"], "ad hoc (unsigned preview)")
            names = {path.name for path in output.iterdir()}
            self.assertLessEqual({manifest["download"], manifest["updateArchive"], "SHA256SUMS", "LICENSE", "NOTICE.md"}, names)
            # Nothing is left behind in the repository's staging area.
            self.assertEqual([path.name for path in (release.repository / ".tmp").iterdir()], ["releases"])

    def test_release_build_strips_its_executables_keeps_their_symbols_and_passes_the_packager(self):
        # The first release shipped with its debug map, which names the build Mac's account and checkout, and with a
        # search path into the build Mac's toolchain; no symbols were kept to read a crash report with (AC-27.03).
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            built = release.run_release_build(compiler)
            self.assertEqual(built.returncode, 0, built.stderr)
            self.assertEqual(built.stdout.splitlines()[-1], str(release.app))
            for name in ["Lunlet", "lunlet-hook"]:
                executable = release.app / "Contents/MacOS" / name
                self.assertEqual(debug_entries(executable), [], name)
                for path in search_paths(executable):
                    self.assertTrue(path.startswith("@") or path == "/usr/lib/swift", path)
                self.assertEqual(build_identifiers(release.symbols / (name + ".dSYM")), build_identifiers(executable))
            self.assertIn("@executable_path/../Frameworks", search_paths(release.app / "Contents/MacOS/Lunlet"))
            verified = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(release.app)], capture_output=True, text=True)
            self.assertEqual(verified.returncode, 0, verified.stderr)
            packaged = release.package()
            self.assertEqual(packaged.returncode, 0, packaged.stderr)
            output = Path(packaged.stdout.splitlines()[0])
            # The symbols stay with the candidate on the release Mac; they are not among the files to publish.
            self.assertEqual(sorted(path.name for path in (output / "dSYMs").iterdir()), ["Lunlet.dSYM", "lunlet-hook.dSYM"])
            self.assertNotIn("dSYM", (output / "SHA256SUMS").read_text())
            self.assertIn("dSYMs", packaged.stdout)

    def test_preview_build_keeps_its_debug_symbols_in_place(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            built = release.run_build(compiler, ["--preview"])
            self.assertEqual(built.returncode, 0, built.stderr)
            self.assertNotEqual(debug_entries(release.app / "Contents/MacOS/Lunlet"), [])
            self.assertFalse(release.symbols.exists())
            # A preview still loads its frameworks from the bundle and never from this checkout's build directory.
            paths = search_paths(release.app / "Contents/MacOS/Lunlet")
            self.assertIn("@executable_path/../Frameworks", paths)
            self.assertFalse([path for path in paths if path.startswith(str(release.repository))])

    def test_packager_refuses_executables_that_name_the_build_mac(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        cases = [({"strip": False}, "debug symbols"),
                 ({"search": ("@executable_path/../Frameworks", "/Users/synthetic/checkout/.build/release")}, "search path"),
                 ({"symbols": False}, "dSYM")]
        for options, message in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
                release = SyntheticRelease(temporary)
                release.build(compiler, **options)
                result = release.package()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse((release.repository / ".tmp/releases").exists())

    def test_packager_accepts_a_stripped_swift_executable(self):
        # Stripping a Swift executable leaves one debug-style entry, a fixed marker of `strip` itself. The first real
        # candidate built with stripping was refused for it.
        compiler, swift_compiler = shutil.which("cc"), shutil.which("swiftc")
        if compiler is None or swift_compiler is None:
            self.skipTest("no C or Swift compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            release.build(compiler, swift_compiler=swift_compiler)
            listing = subprocess.run(["/usr/bin/nm", "-a", str(release.app / "Contents/MacOS/Lunlet")],
                                     capture_output=True, text=True, check=True).stdout
            self.assertIn("OPT radr://5614542", listing)
            result = release.package()
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_packager_refuses_symbols_from_another_build(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            release.build(compiler)
            # Symbols of a different link do not describe this executable.
            other = release.directory / "other"
            (release.directory / "other.c").write_text("int main(void) { return 1; }\n")
            subprocess.run([compiler, "-g", str(release.directory / "other.c"), "-o", str(other)], check=True)
            shutil.rmtree(release.symbols / "Lunlet.dSYM")
            subprocess.run(["/usr/bin/dsymutil", str(other), "-o", str(release.symbols / "Lunlet.dSYM")], capture_output=True, check=True)
            result = release.package()
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("dSYM", result.stderr)

    def test_build_rejects_an_unusable_output_path_before_running_swift(self):
        # A relative output used to fail only at signing, after the whole build.
        for output, message in [("relative/Lunlet.app", "absolute path"), ("/tmp/lunlet-release-test/Lunlet", "application bundle"),
                                ("/tmp/lunlet-release-test/.app", "application bundle")]:
            with self.subTest(output=output):
                result, swift_called = run_build_with_stub_swift(["--preview"], LUNLET_APP_OUTPUT=output)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertFalse(swift_called)

    def test_a_failed_build_leaves_the_earlier_bundle_as_it_was(self):
        # Assembled in place, a build that failed halfway left its new executable under the earlier build's signature.
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            built = release.run_build(compiler, ["--preview"])
            self.assertEqual(built.returncode, 0, built.stderr)
            verify = ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(release.app)]
            self.assertEqual(subprocess.run(verify, capture_output=True).returncode, 0)
            # The next build's products lack the hook helper, so assembly fails after the app's own executable.
            failed = release.run_build(compiler, ["--preview"], helper=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(subprocess.run(verify, capture_output=True, text=True).returncode, 0)
            self.assertTrue((release.app / "Contents/MacOS/lunlet-hook").exists())
            # Nothing of the failed attempt stays beside it.
            self.assertEqual([path.name for path in (release.repository / ".tmp").iterdir()], ["Lunlet.app"])

    def test_a_build_replaces_the_earlier_bundle_and_leaves_no_staging_directory(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            release = SyntheticRelease(temporary)
            output = release.directory / "elsewhere/Custom.app"
            for _ in range(2):
                built = release.run_build(compiler, ["--preview"], LUNLET_APP_OUTPUT=str(output))
                self.assertEqual(built.returncode, 0, built.stderr)
                self.assertEqual(built.stdout.splitlines()[-1], str(output))
                self.assertEqual(subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(output)],
                                                capture_output=True).returncode, 0)
                self.assertEqual([path.name for path in output.parent.iterdir()], ["Custom.app"])

    def test_notices_and_documents_name_the_resolved_dependency_versions(self):
        # AC-29.03: the inventory shipped in the bundle names what is actually built in. The packager only compares
        # the bundle's notices with the repository's, so a dependency bump could ship under the old version's name.
        resolved = (ROOT / "Package.resolved").read_text()
        headers = [path.read_text() for path in sorted((ROOT / "Resources/third-party").glob("*.txt"))]
        self.assertEqual(notice_mismatches((ROOT / "NOTICE.md").read_text(), resolved, headers,
                                           (ROOT / "docs/releases.md").read_text()), [])
        # The comparison notices each kind of drift.
        pins = json.dumps({"pins": [{"identity": "sparkle", "location": "https://github.com/example/Sparkle",
                                     "state": {"version": "2.11.0", "revision": "a" * 40}},
                                    {"identity": "other", "location": "https://github.com/example/other.git",
                                     "state": {"version": "1.0.0", "revision": "b" * 40}}]})
        notice = "| [Sparkle](https://github.com/example/Sparkle) | 2.10.1 | MIT | x |\n"
        header = "Other 0.9.0\nSource: https://github.com/example/other/tree/" + "c" * 40 + "\n"
        problems = notice_mismatches(notice, pins, [header], "Use Sparkle 2.10.1 and Sparkle-2.10.1.tar.xz")
        self.assertEqual(len(problems), 5, problems)
        self.assertEqual(notice_mismatches(
            "| [Sparkle](https://github.com/example/Sparkle) | 2.11.0 | MIT | x |\n| [Other](https://github.com/example/other) | 1.0.0 | MIT | x |\n",
            pins, ["Other 1.0.0\nSource: https://github.com/example/other/tree/" + "b" * 40 + "\n"], "Sparkle 2.11.0"), [])

    def test_validate_checks_whitespace_in_the_committed_tree(self):
        # A clean checkout has no working-tree changes, so a bare whitespace check of the diff could never fail.
        workflow = (ROOT / ".github/workflows/validate.yml").read_text()
        checks = [line.strip() for line in workflow.splitlines() if "diff --check" in line]
        self.assertEqual(len(checks), 1, checks)
        self.assertIn("hash-object -t tree /dev/null", checks[0])
        self.assertIn(" HEAD ", checks[0])

    def test_an_unsigned_release_build_is_an_explicit_choice(self):
        # Without the flag an ad hoc identity is refused for a normal build; with it the build proceeds and says what
        # the release notes must state (AC-27.05).
        result, swift_called = run_build_with_stub_swift([], LUNLET_CODE_SIGN_IDENTITY="-")
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires a certificate signing identity", result.stderr)
        self.assertFalse(swift_called)
        result, swift_called = run_build_with_stub_swift([], LUNLET_CODE_SIGN_IDENTITY="-", LUNLET_RELEASE_UNSIGNED="1")
        self.assertIn("unsigned preview release", result.stderr)
        self.assertIn("first-open steps", result.stderr)
        self.assertNotIn("requires a certificate signing identity", result.stderr)
        # A normal build still needs a clean checkout; on one, the stub stops the build after being called.
        if swift_called:
            self.assertEqual(result.returncode, 97)
        else:
            self.assertIn("clean source checkout", result.stderr)

    def test_unsigned_release_mode_still_rejects_previews_and_names_its_signature_rule(self):
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            app = Path(temporary) / "Lunlet.app"
            (app / "Contents").mkdir(parents=True)
            with (app / "Contents/Info.plist").open('wb') as file:
                plistlib.dump({'LunletDevelopmentPreview': True}, file)
            result = subprocess.run([str(ROOT / 'scripts/package-release.sh'), str(app), 'v0.1.0'],
                                    env={**os.environ, "LUNLET_RELEASE_UNSIGNED": "1"}, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Development previews cannot become public release artifacts', result.stderr)
        script = (ROOT / "scripts/package-release.sh").read_text()
        # The unsigned mode accepts only an ad hoc signature without a certificate and records it as such; an ad hoc
        # candidate with the hardened runtime could not load its own frameworks, so it is refused, while a
        # certificate-signed candidate still needs the runtime for notarization.
        self.assertIn("'^Signature=adhoc$'", script)
        self.assertIn("ad hoc (unsigned preview)", script)
        self.assertIn("none (unsigned preview", script)
        self.assertIn("must not use the hardened runtime", script)
        self.assertIn("The candidate requires hardened runtime", script)

    def test_ad_hoc_signed_app_can_load_its_embedded_framework(self):
        # An ad hoc signature carries no team identifier, so the hardened runtime's library validation refuses the
        # app's own embedded framework at launch (dyld: different Team IDs). Found on 2026-11-01 when the first
        # unsigned candidate crashed at launch on the owner's Mac. Previews and the unsigned preview release sign
        # without the runtime; this launches a synthetic app signed by the real signing script (AC-27.03, AC-27.05).
        cc = shutil.which("cc")
        if cc is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory(prefix="lunlet-release-test-") as temporary:
            directory = Path(temporary)
            app = directory / "Lunlet.app"
            version = app / "Contents/Frameworks/Helper.framework/Versions/A"
            (version / "Resources").mkdir(parents=True)
            (app / "Contents/MacOS").mkdir(parents=True)
            (directory / "helper.c").write_text("int helper(void) { return 0; }\n")
            (directory / "main.c").write_text("int helper(void);\nint main(void) { return helper(); }\n")
            subprocess.run([cc, "-dynamiclib", "-install_name", "@rpath/Helper.framework/Versions/A/Helper",
                            "-o", str(version / "Helper"), str(directory / "helper.c")], check=True)
            subprocess.run([cc, "-o", str(app / "Contents/MacOS/Lunlet"), str(directory / "main.c"), str(version / "Helper"),
                            "-Wl,-rpath,@executable_path/../Frameworks"], check=True)
            with (version / "Resources/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "com.lunlet.tests.helper", "CFBundleExecutable": "Helper",
                               "CFBundlePackageType": "FMWK"}, file)
            os.symlink("A", version.parent / "Current")
            os.symlink("Versions/Current/Helper", version.parent.parent / "Helper")
            with (app / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "com.lunlet.tests.signing", "CFBundleExecutable": "Lunlet",
                               "CFBundlePackageType": "APPL"}, file)
            for mode in ["--unsigned", "--preview"]:
                with self.subTest(mode=mode):
                    signed = subprocess.run([str(ROOT / "scripts/sign-app.sh"), mode, "-", str(app)],
                                            capture_output=True, text=True, timeout=60)
                    self.assertEqual(signed.returncode, 0, signed.stderr)
                    launched = subprocess.run([str(app / "Contents/MacOS/Lunlet")], capture_output=True, text=True, timeout=10)
                    self.assertEqual(launched.returncode, 0, launched.stderr)

    def test_normal_build_needs_both_update_settings_well_formed_before_running_swift(self):
        identity = {"LUNLET_CODE_SIGN_IDENTITY": "Synthetic Identity"}
        cases = [
            ({"LUNLET_UPDATE_FEED_URL": SYNTHETIC_FEED}, "or neither"),
            ({"LUNLET_UPDATE_PUBLIC_KEY": SYNTHETIC_KEY}, "or neither"),
            ({"LUNLET_UPDATE_FEED_URL": "http://example.invalid/appcast.xml", "LUNLET_UPDATE_PUBLIC_KEY": SYNTHETIC_KEY},
             "must be an https URL"),
            ({"LUNLET_UPDATE_FEED_URL": SYNTHETIC_FEED + " extra", "LUNLET_UPDATE_PUBLIC_KEY": SYNTHETIC_KEY},
             "must be an https URL"),
            ({"LUNLET_UPDATE_FEED_URL": SYNTHETIC_FEED, "LUNLET_UPDATE_PUBLIC_KEY": "not-a-key"}, "generate_keys"),
        ]
        for variables, message in cases:
            with self.subTest(variables=variables):
                result, swift_called = run_build_with_stub_swift([], **identity, **variables)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertFalse(swift_called)

    def test_preview_build_ignores_update_settings(self):
        result, swift_called = run_build_with_stub_swift(
            ["--preview"], LUNLET_UPDATE_FEED_URL=SYNTHETIC_FEED, LUNLET_UPDATE_PUBLIC_KEY=SYNTHETIC_KEY)
        self.assertIn("Preview builds never check for updates", result.stderr)
        # The preview proceeds to build (the stub then stops it) without either value (AC-35.04).
        self.assertTrue(swift_called)
        self.assertEqual(result.returncode, 97)

    def test_source_info_plist_has_no_feed_or_key_and_installs_only_after_a_click(self):
        with (ROOT / "Resources/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        # Only a normal build adds the feed and key, so every other build stays without update checks (AC-35.04).
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)
        # Daily checks are on by default; nothing downloads or installs on its own; no system profile (AC-35.01, AC-35.03).
        self.assertIs(info["SUEnableAutomaticChecks"], True)
        self.assertIs(info["SUAllowsAutomaticUpdates"], False)
        self.assertIs(info["SUEnableSystemProfiling"], False)
        self.assertNotIn("SUAutomaticallyUpdate", info)


if __name__ == '__main__':
    unittest.main()
