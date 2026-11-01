#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.01, AC-27.03, AC-27.05; US-29, AC-29.03.
# Refs: US-35, AC-35.01, AC-35.03, AC-35.04.
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# A synthetic, well-formed EdDSA public key (32 bytes, base64). It belongs to no signing key.
SYNTHETIC_KEY = "B" * 43 + "="
SYNTHETIC_FEED = "https://example.invalid/lunlet/appcast.xml"


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
