#!/usr/bin/env python3
# Tests for scripts/panel-disk-collect on a fake filesystem with the real `du`:
#   - the categories never overlap and, with "other", add up exactly to the used space
#   - a file hard-linked into a library is counted once, as a download
#   - a library folder inside a download folder counts as a library, app settings inside a home folder as
#     apps, each once
#   - a config pointing at / or a symlinked config can't make it count the wrong thing
#   - history keeps one sample per ~2 hours and drops samples older than 90 days
# Run: python3 .github/scripts/test-disk-collect.py   (no root needed)
import importlib.machinery
import importlib.util
import json
import os
import shutil
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "scripts", "panel-disk-collect")


def load(fs, base):
    os.environ["SWZ_FS"] = fs
    os.environ["SWZ_DISK_DIR"] = base
    loader = importlib.machinery.SourceFileLoader("panel_disk_collect", SCRIPT)
    spec = importlib.util.spec_from_loader("panel_disk_collect", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def put(path, kib):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(os.urandom(kib * 1024))


def alloc(paths):
    """Bytes in use by the files under paths, each inode once (what du counts)."""
    seen, total = set(), 0
    for top in paths:
        if not os.path.isdir(top):
            st = os.lstat(top)
            if (st.st_dev, st.st_ino) not in seen:
                seen.add((st.st_dev, st.st_ino))
                total += st.st_blocks * 512
            continue
        for root, dirs, files in os.walk(top):
            for name in dirs + files:
                st = os.lstat(os.path.join(root, name))
                if (st.st_dev, st.st_ino) in seen:
                    continue
                seen.add((st.st_dev, st.st_ino))
                total += st.st_blocks * 512
            if root == top:
                st = os.lstat(root)
                if (st.st_dev, st.st_ino) not in seen:
                    seen.add((st.st_dev, st.st_ino))
                    total += st.st_blocks * 512
    return total


class Collect(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="swz-disk-")
        self.fs = os.path.join(self.tmp, "fs")
        self.base = os.path.join(self.tmp, "out")
        F = lambda x: self.fs + x  # noqa: E731
        self.F = F
        put(F("/home/u/torrents/qbittorrent/show/ep1.mkv"), 300)
        put(F("/home/u/torrents/qbittorrent/movie.mkv"), 500)
        put(F("/home/u/dl2/extra.bin"), 64)                                  # from qBittorrent's config
        os.makedirs(F("/home/u/media/tv"))
        os.link(F("/home/u/torrents/qbittorrent/show/ep1.mkv"), F("/home/u/media/tv/ep1.mkv"))   # *arr hard link
        put(F("/home/u/media/tv/copied.mkv"), 200)                           # a real copy: library space
        put(F("/home/u/torrents/qbittorrent/lib/inside.mkv"), 40)           # a library inside downloads
        put(F("/home/u/.config/qBittorrent/qBittorrent.conf"), 0)
        with open(F("/home/u/.config/qBittorrent/qBittorrent.conf"), "w") as f:
            f.write("[BitTorrent]\nSession\\DefaultSavePath=/home/u/dl2\nDownloads\\SavePath=/\n")
        put(F("/home/u/.config/autobrr/autobrr.db"), 24)
        put(F("/home/u/notes/big.iso"), 128)
        put(F("/var/log/syslog"), 32)
        put(F("/var/lib/jellyfin/metadata/x.jpg"), 48)
        put(F("/var/lib/dpkg/status"), 16)
        put(F("/usr/bin/tool"), 80)
        put(F("/opt/Sonarr/Sonarr.dll"), 56)
        put(F("/swapfile"), 100)                                             # outside every folder: "other"
        self.lib = load(self.fs, self.base)
        self.lib.users = lambda: ["u"]
        self.lib.media_dirs = lambda: ["/home/u/media", "/home/u/torrents/qbittorrent/lib"]
        self.lib.mounts = lambda: ["/"]
        self.counted = alloc([F("/home"), F("/var"), F("/usr"), F("/opt")])
        self.overhead = 7 * 1024 * 1024
        self.used = self.counted + alloc([F("/swapfile")]) + self.overhead
        self.lib.usage = lambda m: (10 * self.used, self.used, 9 * self.used)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cats(self, out):
        return {c["key"]: c for c in out["mounts"]["/"]["cats"]}

    def test_categories_add_up_and_never_overlap(self):
        out = self.lib.scan(["/"])
        m = out["mounts"]["/"]
        c = self.cats(out)
        total = sum(x["bytes"] for x in m["cats"])
        self.assertEqual(total, self.counted, "every file under the scanned folders counted exactly once")
        self.assertEqual(total + m["other"], m["used"])
        self.assertFalse(m["over"])
        F = self.F
        lib = alloc([F("/home/u/torrents/qbittorrent/lib")])
        # downloads: torrents + dl2 from the config, minus the folder inside it that a library uses
        self.assertEqual(c["downloads"]["bytes"], alloc([F("/home/u/torrents"), F("/home/u/dl2")]) - lib)
        # libraries: the real copy and the library folder inside downloads; the hard-linked episode is a download
        self.assertEqual(c["media"]["bytes"], alloc([F("/home/u/media")]) - alloc([F("/home/u/media/tv/ep1.mkv")]) + lib)
        self.assertEqual(c["mediadata"]["bytes"], alloc([F("/var/lib/jellyfin")]))
        self.assertEqual(c["apps"]["bytes"], alloc([F("/opt"), F("/home/u/.config")]))
        self.assertEqual(c["logs"]["bytes"], alloc([F("/var/log")]))
        self.assertGreaterEqual(c["homes"]["bytes"], alloc([F("/home/u/notes")]))
        self.assertGreaterEqual(c["system"]["bytes"], alloc([F("/usr"), F("/var/lib/dpkg")]))
        # "/" from the config was refused (it would have claimed everything)
        self.assertNotIn("/", [x["path"] for x in c["downloads"]["paths"]])
        # paths shown as on the server, not the test root
        self.assertTrue(all(x["path"].startswith("/home/u/") for x in c["downloads"]["top"]))
        self.assertEqual(c["downloads"]["top"][0]["path"], "/home/u/torrents/qbittorrent")
        st = os.stat(os.path.join(self.base, "disk-usage.json"))
        self.assertEqual(st.st_mode & 0o777, 0o640)

    def test_symlinked_config_is_not_read(self):
        secret = os.path.join(self.tmp, "secret.conf")
        with open(secret, "w") as f:
            f.write("Session\\DefaultSavePath=/var/lib/jellyfin\n")
        conf = self.F("/home/u/.config/qBittorrent/qBittorrent.conf")
        os.unlink(conf)
        os.symlink(secret, conf)
        c = self.cats(self.lib.scan(["/"]))
        self.assertNotIn("/var/lib/jellyfin", [x["path"] for x in c["downloads"]["paths"]])
        self.assertIn("/var/lib/jellyfin", [x["path"] for x in c["mediadata"]["paths"]])

    def test_order_puts_inner_folders_first(self):
        order = self.lib.du_order([("downloads", "/a/t"), ("media", "/a/t/lib"), ("homes", "/a"), ("apps", "/a/.config"),
                                   ("system", "/v"), ("logs", "/v/log")])
        pos = {path: i for i, (_, path) in enumerate(order)}
        self.assertLess(pos["/a/t/lib"], pos["/a/t"])
        self.assertLess(pos["/a/.config"], pos["/a"])
        self.assertLess(pos["/a/t"], pos["/a"])
        self.assertLess(pos["/v/log"], pos["/v"])

    def test_history_spacing_and_age(self):
        t = int(time.time())
        hist = os.path.join(self.base, "disk-history.json")
        os.makedirs(self.base, exist_ok=True)
        with open(hist, "w") as f:
            json.dump({"mounts": {"/": [[t - 100 * 86400, 1, 2, 1], [t - 3 * 3600, 5, 10, 5]]}}, f)
        pts = self.lib.record_history(["/"], t)["/"]
        self.assertEqual([p[0] for p in pts], [t - 3 * 3600, t])          # 100-day-old sample dropped
        pts = self.lib.record_history(["/"], t + 600)["/"]
        self.assertEqual(len(pts), 2)                                      # too soon for another sample
        pts = self.lib.record_history(["/"], t + 2 * 3600)["/"]
        self.assertEqual(len(pts), 3)
        self.assertEqual(pts[-1][1:], [self.used, 10 * self.used, 9 * self.used])


if __name__ == "__main__":
    unittest.main(verbosity=2)
