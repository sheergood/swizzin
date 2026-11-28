#!/usr/bin/env python3
# Tests for scripts/panel-updates-check with every outside source faked (no network, no root).
# Run: python3 .github/scripts/test-panel-updates.py
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "scripts", "panel-updates-check")
loader = importlib.machinery.SourceFileLoader("panel_updates_check", SCRIPT)
spec = importlib.util.spec_from_loader("panel_updates_check", loader)
puc = importlib.util.module_from_spec(spec)
loader.exec_module(puc)


class Fake:
    def __init__(self):
        self.installed = set()
        self.runs = {}
        self.gh = {}
        self.http = {}

    def run(self, cmd, timeout=20):
        for key, val in self.runs.items():
            if key in " ".join(cmd):
                return val
        return 0, ""

    def gh_get(self, path):
        v = self.gh.get(path)
        if isinstance(v, Exception):
            raise v
        if v is None:
            raise RuntimeError("couldn't reach GitHub (test)")
        return v

    def http_json(self, url, headers=None, timeout=15, data=None):
        for key, val in self.http.items():
            if url.endswith(key):
                if isinstance(val, Exception):
                    raise val
                return val
        raise puc.urllib.error.URLError("refused")


class UpdatesCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fake()
        self.saved = {k: getattr(puc, k) for k in ("OUT", "ARR", "installed", "run", "gh", "http_json", "master_user", "PANEL_GROUP")}
        puc.OUT = os.path.join(self.tmp.name, "updates.json")
        puc.ARR = os.path.join(self.tmp.name, "arr.json")
        puc.PANEL_GROUP = "no-such-group-for-tests"
        puc.installed = lambda app: app in self.f.installed
        puc.run = self.f.run
        puc.gh = self.f.gh_get
        puc.http_json = self.f.http_json
        puc.master_user = lambda: "alice"
        self.exists = os.path.exists
        puc.os.path.exists = lambda p: True if p.startswith(("/usr/bin/", "/home/alice/bin/filebrowser", "/opt/fbquantum")) else self.exists(p)
        self.which = puc.shutil.which
        puc.shutil.which = lambda name: "/usr/bin/" + name

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(puc, k, v)
        puc.os.path.exists = self.exists
        puc.shutil.which = self.which
        self.tmp.cleanup()

    def result(self):
        self.assertEqual(puc.main(), 0)
        with open(puc.OUT) as fh:
            return json.load(fh)["apps"]

    def test_autobrr_update_available_with_notes(self):
        self.f.installed = {"autobrr"}
        self.f.runs["autobrrctl version"] = (0, "Version: v1.48.0\nCommit: abc\nLatest release: v1.50.0\n")
        self.f.gh["repos/autobrr/autobrr/releases/latest"] = {"tag_name": "v1.50.0", "body": "## Changes\n- fix", "html_url": "https://x/1.50"}
        a = self.result()["autobrr"]
        self.assertEqual((a["installed"], a["latest"], a["available"], a["method"]), ("1.48.0", "1.50.0", True, "box"))
        self.assertIn("fix", a["notes"])

    def test_up_to_date(self):
        self.f.installed = {"filebrowser"}
        self.f.runs["filebrowser version"] = (0, "File Browser v2.27.0/aabbcc")
        self.f.gh["repos/filebrowser/filebrowser/releases/latest"] = {"tag_name": "v2.27.0", "body": ""}
        self.assertFalse(self.result()["filebrowser"]["available"])

    def test_failed_check_keeps_previous_answer(self):
        self.f.installed = {"autobrr"}
        with open(puc.OUT, "w") as fh:
            json.dump({"apps": {"autobrr": {"installed": "1.0.0", "latest": "1.1.0", "available": True}}}, fh)
        self.f.gh["repos/autobrr/autobrr/releases/latest"] = RuntimeError("GitHub is limiting release checks (HTTP 403)")
        a = self.result()["autobrr"]
        self.assertEqual((a["latest"], a["available"]), ("1.1.0", True))
        self.assertIn("403", a["error"])

    def test_not_installed_apps_are_skipped(self):
        self.assertEqual(self.result(), {})

    def test_qbittorrent_picks_newest_stable_tag(self):
        self.f.installed = {"qbittorrent"}
        self.f.runs["qbittorrent-nox --version"] = (0, "qBittorrent v4.6.7")
        self.f.gh["repos/qbittorrent/qBittorrent/tags?per_page=100"] = [
            {"name": "release-5.1.0rc1"}, {"name": "release-5.0.4"}, {"name": "release-5.0.10"}, {"name": "release-4.6.7"}, {"name": "v3"}]
        q = self.result()["qbittorrent"]
        self.assertEqual((q["latest"], q["available"], q["method"]), ("5.0.10", True, "user"))

    def test_plex_uses_dpkg_comparison(self):
        self.f.installed = {"plex"}
        self.f.runs["dpkg-query"] = (0, "1.41.2.9200-c6bbc1b53")
        self.f.runs["apt-cache policy"] = (0, "plexmediaserver:\n  Installed: 1.41.2.9200-c6bbc1b53\n  Candidate: 1.41.3.9314-a0bfb8370\n")
        self.f.runs["dpkg --compare-versions"] = (0, "")
        p = self.result()["plex"]
        self.assertEqual((p["installed"], p["latest"], p["available"], p["method"]), ("1.41.2.9200", "1.41.3.9314", True, "apt"))

    def test_arr_self_update_with_changes(self):
        self.f.installed = {"sonarr", "prowlarr"}
        with open(puc.ARR, "w") as fh:
            json.dump({"sonarr": {"url": "http://127.0.0.1:8989", "key": "k" * 32},
                       "prowlarr": {"url": "http://127.0.0.1:9696", "key": "p" * 32}}, fh)
        self.f.http["/api/v3/system/status"] = {"version": "4.0.10.2544"}
        self.f.http["/api/v3/update"] = [
            {"version": "4.0.11.2680", "installable": True, "branch": "main", "changes": {"new": ["Thing"], "fixed": ["Bug"]}},
            {"version": "4.0.10.2544", "installed": True}]
        self.f.http["/api/v1/system/status"] = {"version": "1.20.0.4590"}
        self.f.http["/api/v1/update"] = [{"version": "1.20.0.4590", "installed": True}]
        r = self.result()
        self.assertTrue(r["sonarr"]["available"])
        self.assertEqual(r["sonarr"]["method"], "self")
        self.assertIn("4.0.11.2680 · New: Thing", r["sonarr"]["notes"])
        self.assertFalse(r["prowlarr"]["available"])

    def test_arr_down_is_an_error_not_a_crash(self):
        self.f.installed = {"radarr"}
        with open(puc.ARR, "w") as fh:
            json.dump({"radarr": {"url": "http://127.0.0.1:7878", "key": "r" * 32}}, fh)
        self.assertIn("isn't answering", self.result()["radarr"]["error"])

    def test_long_notes_are_trimmed(self):
        t = puc.trim_notes(("line of notes\n" * 2000) + "<!-- hidden -->")
        self.assertLessEqual(len(t), puc.NOTES_MAX + 2)
        self.assertTrue(t.endswith("…"))
        self.assertNotIn("hidden", puc.trim_notes("a <!-- hidden --> b"))

    def test_output_is_not_world_readable(self):
        self.result()
        self.assertEqual(stat.S_IMODE(os.stat(puc.OUT).st_mode), 0o640)

    def test_unreadable_installed_version_is_an_error(self):
        self.f.installed = {"navidrome"}
        self.f.gh["repos/navidrome/navidrome/releases/latest"] = {"tag_name": "v0.64.2", "body": ""}
        n = self.result()["navidrome"]                     # /opt/navidrome/navidrome isn't there in CI
        self.assertIn("installed version", n["error"])
        self.assertFalse(n.get("available", False))

    def test_torrent_app_with_unreadable_version_is_left_off(self):
        self.f.installed = {"qbittorrent", "transmission"}
        self.f.runs["qbittorrent-nox --version"] = (127, "")
        self.f.gh["repos/qbittorrent/qBittorrent/tags?per_page=100"] = [{"name": "release-5.0.4"}]
        self.f.gh["repos/transmission/transmission/releases/latest"] = {"tag_name": "4.1.4", "body": ""}
        self.assertEqual(self.result(), {})

    def test_more_github_apps(self):
        self.f.installed = {"netronome", "lounge", "transmission"}
        self.f.runs["netronome version"] = (0, "netronome v0.16.0 (abc)")
        self.f.runs["thelounge --version"] = (0, "v4.5.2")
        self.f.runs["transmission-daemon -V"] = (0, "transmission-daemon 4.0.5 (a6fe2a64aa)")
        self.f.gh["repos/autobrr/netronome/releases/latest"] = {"tag_name": "v0.17.0", "body": "- faster"}
        self.f.gh["repos/thelounge/thelounge/releases/latest"] = {"tag_name": "v4.5.2", "body": ""}
        self.f.gh["repos/transmission/transmission/releases/latest"] = {"tag_name": "4.1.4", "body": ""}
        r = self.result()
        self.assertEqual((r["netronome"]["available"], r["netronome"]["method"]), (True, "box"))
        self.assertFalse(r["lounge"]["available"])
        self.assertEqual((r["transmission"]["installed"], r["transmission"]["available"], r["transmission"]["method"]), ("4.0.5", True, "user"))

    def test_apt_apps_versions(self):
        self.f.installed = {"jellyfin", "ombi"}
        self.f.runs["dpkg-query -W -f=${Version} jellyfin-server"] = (0, "10.10.6+deb12")
        self.f.runs["apt-cache policy jellyfin-server"] = (0, "  Installed: 10.10.6+deb12\n  Candidate: 10.10.7+deb12\n")
        self.f.runs["dpkg-query -W -f=${Version} ombi"] = (0, "4.47.1")
        self.f.runs["apt-cache policy ombi"] = (0, "  Installed: 4.47.1\n  Candidate: 4.47.1\n")
        self.f.runs["dpkg --compare-versions 10.10.6+deb12"] = (0, "")
        self.f.runs["dpkg --compare-versions 4.47.1"] = (1, "")
        r = self.result()
        self.assertEqual((r["jellyfin"]["installed"], r["jellyfin"]["latest"], r["jellyfin"]["available"]), ("10.10.6", "10.10.7", True))
        self.assertFalse(r["ombi"]["available"])

    def test_lidarr_uses_api_v1(self):
        self.f.installed = {"lidarr"}
        with open(puc.ARR, "w") as fh:
            json.dump({"lidarr": {"url": "http://127.0.0.1:8686/lidarr", "key": "l" * 32}}, fh)
        self.f.http["/api/v1/system/status"] = {"version": "3.1.0.4875"}
        self.f.http["/api/v1/update"] = [{"version": "3.2.1.5196", "installable": True, "changes": {"fixed": ["x"]}}]
        self.assertTrue(self.result()["lidarr"]["available"])

    def test_version_parsing(self):
        self.assertEqual(puc.first_version("File Browser v2.27.0/abc"), "2.27.0")
        self.assertGreater(puc.vtuple("5.0.10"), puc.vtuple("5.0.4"))
        self.assertGreater(puc.vtuple("1.50.0"), puc.vtuple("1.48.0"))


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=1))
