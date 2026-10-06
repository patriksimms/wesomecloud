"""Release contracts using real local Git repositories and an in-memory GitHub boundary."""
import contextlib
import base64
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "release"
loader = importlib.machinery.SourceFileLoader("release", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
release = importlib.util.module_from_spec(spec)
loader.exec_module(release)


def feed(version="0.1.3", build=5):
    return f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:version>{build}</sparkle:version>
</item></channel></rss>'''.encode()


@contextlib.contextmanager
def working_directory(path):
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


class Versions(unittest.TestCase):
    def test_semver_bumps_and_invalid_versions(self):
        for bump, expected in (("patch", "1.2.4"), ("minor", "1.3.0"), ("major", "2.0.0"), ("3.2.1", "3.2.1")):
            with self.subTest(bump=bump):
                self.assertEqual(release.next_version("1.2.3", bump), expected)
        for invalid in ("1.2.3", "1.2.2", "01.3.0", "2.0", "2.0.0-beta.1"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                release.next_version("1.2.3", invalid)

    def test_both_plists_change_together_and_keep_unrelated_metadata(self):
        with tempfile.TemporaryDirectory() as directory, working_directory(directory):
            Path("AppHost").mkdir()
            for path in release.PLISTS:
                Path(path).write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.3", "CFBundleVersion": "5", "Keep": "unchanged"}))
            release.bump_plists("0.2.0", 6)
            self.assertEqual(release.metadata(), ("0.2.0", 6))
            for path in release.PLISTS:
                self.assertEqual(plistlib.loads(Path(path).read_bytes())["Keep"], "unchanged")
            data = plistlib.loads(Path(release.PLISTS[1]).read_bytes())
            data["CFBundleVersion"] = "7"
            Path(release.PLISTS[1]).write_bytes(plistlib.dumps(data))
            with self.assertRaisesRegex(ValueError, "must match"):
                release.metadata()

    def test_public_feed_cannot_be_downgraded(self):
        for data in (feed("0.1.5", 7), feed("0.1.4", 9)):
            with self.assertRaisesRegex(ValueError, "newer release"):
                release.check_feed(data, "0.1.4", 6)


class Publication(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cwd = os.getcwd()
        os.chdir(self.temp.name)
        self.addCleanup(os.chdir, self.cwd)
        self.real_run = release.run
        self.original_lookup = release.release_info
        subprocess.run(["git", "init", "-q", "--bare", "remote.git"], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", "work"], check=True)
        os.chdir("work")
        for key, value in (("user.name", "Release Test"), ("user.email", "release@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false")):
            release.git("config", key, value)
        release.git("remote", "add", "origin", "../remote.git")
        Path("source.txt").write_text("release source\n")
        release.git("add", "source.txt")
        release.git("commit", "-qm", "release source")
        release.git("tag", "-a", "v0.1.4", "-m", "release")
        self.revision = release.git("rev-parse", "HEAD")
        self.folder = Path("build/releases/v0.1.4")
        (self.folder / "updates").mkdir(parents=True)
        (self.folder / "updates/appcast.xml").write_bytes(feed("0.1.4", 6))
        (self.folder / "notes.md").write_text("Test notes")
        self.assets = {name: content for name, content in (("WesomeCloud-0.1.4.zip", b"zip bytes"), ("WesomeCloud-0.1.4.dmg", b"dmg bytes"))}
        for name, content in self.assets.items():
            (self.folder / name).write_bytes(content)
        self.manifest = {"repo": "test/repo", "branch": "main", "version": "0.1.4", "build": 6, "revision": self.revision, "stable": False,
                         "assets": {name: hashlib.sha256(content).hexdigest() for name, content in self.assets.items()},
                         "feed_sha256": hashlib.sha256(feed("0.1.4", 6)).hexdigest(),
                         "feed_url": "https://example.invalid/appcast.xml", "page_url": "https://example.invalid/"}
        (self.folder / "manifest.json").write_text(json.dumps(self.manifest))
        self.expected_asset_names = set(self.assets)
        self.hosted = None
        self.remote_assets = {}
        self.published_feed = feed()
        self.published_page = b"old page"
        self.tree = {}
        self.fail_upload = False
        self.corrupt_download = False
        self.downgrade_race = False
        self.addCleanup(patch.stopall)
        patch.object(release, "run", side_effect=self.command).start()
        patch.object(release, "api", side_effect=self.api).start()
        patch.object(release, "release_info", side_effect=lambda repo, tag: self.hosted).start()
        patch.object(release, "fetch", side_effect=self.fetch).start()

    def command(self, *args, **kwargs):
        if args[:2] == ("gh", "api"):
            return self.real_run(*args, **kwargs)
        if args[0] != "gh":
            return self.real_run(*args, **kwargs)
        operation = args[2]
        if operation == "create":
            if self.hosted is not None:
                raise subprocess.CalledProcessError(422, args)
            self.hosted = {"tag_name": "v0.1.4", "draft": True, "assets": []}
        elif operation == "upload":
            for filename in args[6:]:
                name = Path(filename).name
                self.remote_assets[name] = Path(filename).read_bytes()
                if name not in {asset["name"] for asset in self.hosted["assets"]}:
                    self.hosted["assets"].append({"name": name})
                    if self.fail_upload:
                        self.fail_upload = False
                        raise subprocess.CalledProcessError(1, args)
        elif operation == "download":
            destination = Path(args[args.index("--dir") + 1])
            for name, content in self.remote_assets.items():
                (destination / name).write_bytes(b"corrupt" if self.corrupt_download else content)
        elif operation == "edit":
            self.hosted["draft"] = False
            if self.downgrade_race:
                self.published_feed = feed("0.1.5", 7)
        else:
            raise AssertionError(f"Unexpected GitHub command: {args}")

    def api(self, repo, path, payload=None, method="POST"):
        if path == "pages":
            return {"source": {"branch": "gh-pages", "path": "/"}, "html_url": self.manifest["page_url"]}
        if path.startswith("contents/appcast.xml?ref="):
            return {"content": base64.b64encode(self.published_feed).decode()}
        if path == "releases/tags/v0.1.4":
            if self.hosted and self.hosted["draft"]:
                raise subprocess.CalledProcessError(404, ["gh", "api", path])
            return self.hosted
        if path == "git/ref/heads/gh-pages":
            return {"object": {"sha": "parent"}}
        if path == "git/commits/parent":
            return {"tree": {"sha": "base"}}
        if path == "git/trees":
            self.tree = {entry["path"]: entry["content"].encode() for entry in payload["tree"]}
            return {"sha": "tree"}
        if path == "git/commits":
            return {"sha": "new-pages"}
        if path == "git/refs/heads/gh-pages":
            self.assertFalse(self.hosted["draft"])
            self.assertEqual({item["name"] for item in self.hosted["assets"]}, self.expected_asset_names)
            self.published_feed = self.tree["appcast.xml"]
            self.published_page = self.tree["index.html"]
            return {}
        raise AssertionError(f"Unexpected API request: {path}")

    def fetch(self, url):
        if url == self.manifest["feed_url"]:
            return self.published_feed
        if url == self.manifest["page_url"]:
            return self.published_page
        self.assertFalse(self.hosted["draft"])
        return self.remote_assets[url.rsplit("/", 1)[1]]

    def publish(self):
        release.publish("test/repo", "main", "0.1.4", 6, self.folder, False)

    def test_existing_draft_resumes_when_tag_endpoint_returns_404(self):
        self.hosted = {"tag_name": "v0.1.4", "draft": True, "assets": []}
        original_subprocess_run = subprocess.run
        def github_request(args, **kwargs):
            if tuple(args[:2]) == ("gh", "api"):
                if "/releases/tags/" in args[2]:
                    return subprocess.CompletedProcess(args, 1, "", "gh: Not Found (HTTP 404)")
                if args[2].split("?")[0].endswith("/releases"):
                    return subprocess.CompletedProcess(args, 0, json.dumps([[self.hosted]]), "")
                raise AssertionError(f"Unexpected GitHub API request: {args}")
            return original_subprocess_run(args, **kwargs)
        with patch.object(release, "release_info", self.original_lookup), \
             patch.object(subprocess, "run", side_effect=github_request):
            self.publish()
        self.assertFalse(self.hosted["draft"])
        self.assertEqual(self.published_feed, feed("0.1.4", 6))
        self.assertEqual({item["name"] for item in self.hosted["assets"]}, self.expected_asset_names)

    def test_partial_upload_keeps_feed_and_can_resume_same_tag(self):
        self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.hosted["draft"])
        self.assertEqual(self.published_feed, feed())
        self.publish()
        self.assertEqual(self.published_feed, feed("0.1.4", 6))
        self.assertIn(b"Download WesomeCloud 0.1.4", self.published_page)
        self.assertEqual(release.git("--git-dir=../remote.git", "rev-parse", "v0.1.4^{commit}"), self.revision)
        self.assertEqual(release.git("tag", "--list"), "v0.1.4")

    def test_corrupt_uploaded_asset_keeps_release_draft_and_feed_unchanged(self):
        self.corrupt_download = True
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.publish()
        self.assertTrue(self.hosted["draft"])
        self.assertEqual(self.published_feed, feed())

    def test_release_published_by_another_run_prevents_feed_downgrade(self):
        self.downgrade_race = True
        with self.assertRaisesRegex(ValueError, "newer release"):
            self.publish()
        self.assertEqual(self.published_feed, feed("0.1.5", 7))

    def test_changed_local_artifact_is_rejected_before_push_or_publication(self):
        (self.folder / "WesomeCloud-0.1.4.zip").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "artifact changed"):
            self.publish()
        self.assertIsNone(self.hosted)
        result = subprocess.run(["git", "--git-dir=../remote.git", "show-ref"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_complete_release_tags_and_publishes_the_bumped_source(self):
        release.git("tag", "-d", "v0.1.4")
        Path("AppHost").mkdir()
        for path in release.PLISTS:
            Path(path).write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.3", "CFBundleVersion": "5"}))
        Path("docs").mkdir()
        for path in ("LICENSE", "NOTICE", "docs/Sparkle-LICENSE.txt"):
            Path(path).write_text("license notice")
        Path(".gitignore").write_text("build/\n.envrc\n")
        Path(".envrc").write_text("private local settings")
        release.git("add", "AppHost", "docs", "LICENSE", "NOTICE", ".gitignore")
        release.git("commit", "-qm", "app source")
        # Publication fixtures are separate from the fresh preparation directory.
        import shutil
        shutil.rmtree(self.folder)
        self.expected_asset_names = {"WesomeCloud-0.1.4.zip", "WesomeCloud-0.1.4.dmg", "WesomeCloud-0.1.4-source.tar.gz", "LICENSE", "NOTICE", "Sparkle-LICENSE.txt", "SHA256SUMS.txt"}
        def builder(*args, **kwargs):
            if args[0] == "scripts/validate-release-signing.sh":
                if "--archive" in args:
                    env = kwargs["env"]
                    updates = Path(env["WESOME_CLOUD_UPDATES_PATH"])
                    updates.mkdir()
                    Path(env["WESOME_CLOUD_ZIP_PATH"]).write_bytes(b"zip bytes")
                    Path(env["WESOME_CLOUD_DMG_PATH"]).write_bytes(b"dmg bytes")
                    version, build = release.metadata()
                    (updates / "appcast.xml").write_bytes(feed(version, build))
                return None
            if args[0] in ("swift", "scripts/generate-xcode-project.sh", "scripts/validate-packaging.sh"):
                return None
            return self.command(*args, **kwargs)
        with patch.object(release, "__file__", str(Path("scripts/release").resolve())), \
             patch.object(release, "repository", return_value="test/repo"), \
             patch.object(release.shutil, "which", return_value="available"), \
             patch.dict(os.environ, {"WESOME_CLOUD_APPCAST_URL": self.manifest["feed_url"], "WESOME_CLOUD_DOWNLOAD_URL_PREFIX": ""}), \
             patch.object(release, "run", side_effect=builder), \
             patch("sys.argv", ["release", "patch"]):
            release.main()
        self.assertEqual(release.metadata(), ("0.1.4", 6))
        self.assertEqual(release.git("status", "--porcelain"), "")
        self.assertEqual(release.git("rev-parse", "v0.1.4^{commit}"), release.git("rev-parse", "HEAD"))
        self.assertEqual(self.published_feed, feed("0.1.4", 6))
        with tarfile.open(self.folder / "WesomeCloud-0.1.4-source.tar.gz") as archive:
            info = plistlib.loads(archive.extractfile("WesomeCloud-0.1.4/AppHost/Info.plist").read())
            self.assertEqual((info["CFBundleShortVersionString"], info["CFBundleVersion"]), ("0.1.4", "6"))
            self.assertNotIn("WesomeCloud-0.1.4/.envrc", archive.getnames())

    def test_dry_run_is_offline_and_leaves_versions_and_git_unchanged(self):
        Path("AppHost").mkdir()
        for path in release.PLISTS:
            Path(path).write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.3", "CFBundleVersion": "5"}))
        release.git("remote", "set-url", "origin", "git@github.com:test/repo.git")
        before = {path: Path(path).read_bytes() for path in release.PLISTS}
        status = release.git("status", "--porcelain")
        output = io.StringIO()
        with patch.object(release, "__file__", str(Path("scripts/release").resolve())), \
             patch.object(release, "api", side_effect=AssertionError("Dry run contacted GitHub")), \
             patch.object(release, "fetch", side_effect=AssertionError("Dry run downloaded files")), \
             patch("sys.argv", ["release", "patch", "--dry-run"]), contextlib.redirect_stdout(output):
            release.main()
        self.assertIn("0.1.3 (5) -> 0.1.4 (6)", output.getvalue())
        self.assertEqual({path: Path(path).read_bytes() for path in release.PLISTS}, before)
        self.assertEqual(release.git("status", "--porcelain"), status)
        self.assertEqual(release.git("tag", "--list"), "v0.1.4")

    def test_preparation_failure_restores_both_versions_and_creates_no_tag(self):
        Path("AppHost").mkdir()
        for path in release.PLISTS:
            Path(path).write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.3", "CFBundleVersion": "5"}))
        Path(".gitignore").write_text("build/\n")
        release.git("add", "AppHost", ".gitignore")
        release.git("commit", "-qm", "app metadata")
        before = {path: Path(path).read_bytes() for path in release.PLISTS}
        self.published_feed = feed("0.1.3", 10)
        def failing_builder(*args, **kwargs):
            if args[0] == "scripts/validate-release-signing.sh":
                return None
            if args[0] == "swift":
                self.assertEqual(release.metadata(), ("0.2.0", 11))
                raise subprocess.CalledProcessError(1, args)
            return self.command(*args, **kwargs)
        with patch.object(release, "__file__", str(Path("scripts/release").resolve())), \
             patch.object(release, "repository", return_value="test/repo"), \
             patch.object(release.shutil, "which", return_value="available"), \
             patch.dict(os.environ, {"WESOME_CLOUD_APPCAST_URL": self.manifest["feed_url"], "WESOME_CLOUD_DOWNLOAD_URL_PREFIX": ""}), \
             patch.object(release, "run", side_effect=failing_builder), \
             patch("sys.argv", ["release", "minor"]):
            with self.assertRaises(subprocess.CalledProcessError):
                release.main()
        self.assertEqual({path: Path(path).read_bytes() for path in release.PLISTS}, before)
        self.assertEqual(release.git("status", "--porcelain"), "")
        self.assertEqual(release.git("tag", "--list", "v0.2.0"), "")


if __name__ == "__main__":
    unittest.main()
