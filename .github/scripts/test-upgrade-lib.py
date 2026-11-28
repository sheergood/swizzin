#!/usr/bin/env python3
# Tests for scripts/panel-upgrade-lib: rollback copies (program + data, read and written as the files'
# owner), the symlink and ownership tricks a user on a shared box could try, the update history,
# holds, and the *arr update flow against a fake Servarr API.
# Needs root (it creates two throwaway users); run on a throwaway machine:  sudo python3 test-upgrade-lib.py
import http.server
import importlib.machinery
import importlib.util
import json
import os
import pwd
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# kept where the test users can't read it: what runs as a file's owner must not need this file
# (on a dev install /etc/swizzin points into /root)
_SRC = os.path.join(HERE, "..", "..", "scripts", "panel-upgrade-lib")
_LIBDIR = tempfile.mkdtemp(prefix="swz-lib-")
os.chmod(_LIBDIR, 0o700)
LIB = os.path.join(_LIBDIR, "panel-upgrade-lib")
shutil.copy(_SRC, LIB)
os.chmod(LIB, 0o755)
U1, U2 = "swzlibtest1", "swzlibtest2"


def load(fs, base):
    os.environ["SWZ_FS"] = fs
    os.environ["SWZ_UPG_DIR"] = base
    os.environ["SWZ_UPDATES_FILE"] = os.path.join(base, "updates.json")
    os.environ["SWZ_ARR_FILE"] = os.path.join(base, "arr.json")
    os.environ["SWZ_ARR_POLL"] = "0.05"
    os.environ["SWZ_ARR_TIMEOUT"] = "20"
    loader = importlib.machinery.SourceFileLoader("panel_upgrade_lib", LIB)
    spec = importlib.util.spec_from_loader("panel_upgrade_lib", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def user(name):
    try:
        return pwd.getpwnam(name)
    except KeyError:
        subprocess.run(["useradd", "-M", "-s", "/usr/sbin/nologin", name], check=True)
        return pwd.getpwnam(name)


def put(path, text, owner=None, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)
    if owner:
        os.chown(path, owner.pw_uid, owner.pw_gid)


def read(path):
    with open(path) as f:
        return f.read()


def own_tree(path, owner):
    for root, dirs, files in os.walk(path):
        os.chown(root, owner.pw_uid, owner.pw_gid)
        for f in files:
            os.lchown(os.path.join(root, f), owner.pw_uid, owner.pw_gid)


@unittest.skipUnless(os.geteuid() == 0, "needs root")
class Base(unittest.TestCase):
    def setUp(self):
        self.u1, self.u2 = user(U1), user(U2)
        self.tmp = tempfile.mkdtemp(prefix="swz-libtest-")
        os.chmod(self.tmp, 0o755)
        self.fs = os.path.join(self.tmp, "fs")
        self.base = os.path.join(self.tmp, "upgrades")
        for d in ("usr/bin", "opt", "etc/systemd/system", "home"):
            os.makedirs(os.path.join(self.fs, d), exist_ok=True)
        for d in (self.fs, os.path.join(self.fs, "usr"), os.path.join(self.fs, "usr/bin"), os.path.join(self.fs, "opt"),
                  os.path.join(self.fs, "home"), os.path.join(self.fs, "etc")):
            os.chmod(d, 0o755)
        self.home = os.path.join(self.fs, "home", U1)
        os.makedirs(self.home)
        os.chown(self.home, self.u1.pw_uid, self.u1.pw_gid)
        self.lib = load(self.fs, self.base)
        self.lib.master_user = lambda: U1
        self.lib.swizzin_users = lambda: [U1]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def F(self, path):
        return self.fs + path


class Autobrr(Base):
    def setUp(self):
        super().setUp()
        put(self.F("/usr/bin/autobrr"), "prog-old", mode=0o755)
        put(self.F("/usr/bin/autobrrctl"), "ctl-old", mode=0o755)
        cfg = self.F("/home/{}/.config/autobrr".format(U1))
        os.makedirs(cfg)
        put(cfg + "/autobrr.db", "db-old", self.u1, 0o600)
        put(cfg + "/autobrr.db-wal", "wal-old", self.u1, 0o600)
        put(cfg + "/config.toml", "cfg-old", self.u1, 0o600)
        own_tree(self.F("/home/{}/.config".format(U1)), self.u1)
        self.cfg = cfg

    def upgrade(self):
        put(self.F("/usr/bin/autobrr"), "prog-new", mode=0o755)
        put(self.cfg + "/autobrr.db", "db-new", self.u1, 0o600)
        os.unlink(self.cfg + "/autobrr.db-wal")

    def test_copy_keep_check_restore_undo(self):
        complete, reason = self.lib.snap_save("autobrr", "new")
        self.assertTrue(complete, reason)
        self.upgrade()
        self.lib.snap_keep("autobrr", "1.0", "1.1")
        with open(os.path.join(self.base, "rollback.json")) as f:
            rb = json.load(f)
        self.assertEqual(rb["autobrr"]["previous"], "1.0")
        self.assertEqual(rb["autobrr"]["current"], "1.1")
        self.lib.snap_check("autobrr")
        self.assertTrue(self.lib.snap_save("autobrr", "undo")[0])
        ok, why = self.lib.snap_restore("autobrr", "last")
        self.assertTrue(ok, why)
        self.assertEqual(read(self.F("/usr/bin/autobrr")), "prog-old")
        self.assertEqual(read(self.cfg + "/autobrr.db"), "db-old")
        self.assertEqual(read(self.cfg + "/autobrr.db-wal"), "wal-old")     # the old WAL comes back with it
        st = os.stat(self.cfg + "/autobrr.db")
        self.assertEqual((st.st_uid, st.st_mode & 0o777), (self.u1.pw_uid, 0o600))
        self.assertTrue(self.lib.snap_verify("autobrr", "last"))
        ok, why = self.lib.snap_restore("autobrr", "undo")
        self.assertTrue(ok, why)
        self.assertEqual(read(self.F("/usr/bin/autobrr")), "prog-new")
        self.assertFalse(os.path.exists(self.cfg + "/autobrr.db-wal"))        # absent in the copy -> removed

    def test_changed_outside_the_panel_blocks_rollback(self):
        self.lib.snap_save("autobrr", "new")
        self.upgrade()
        self.lib.snap_keep("autobrr", "1.0", "1.1")
        put(self.F("/usr/bin/autobrr"), "prog-newer", mode=0o755)
        with self.assertRaises(self.lib.Fail):
            self.lib.snap_check("autobrr")

    def test_symlink_to_a_root_file_is_never_read(self):
        put(self.F("/secret"), "TOP-SECRET", mode=0o600)
        os.unlink(self.cfg + "/autobrr.db")
        os.symlink(self.F("/secret"), self.cfg + "/autobrr.db")
        os.lchown(self.cfg + "/autobrr.db", self.u1.pw_uid, self.u1.pw_gid)
        complete, reason = self.lib.snap_save("autobrr", "new")
        self.assertFalse(complete)
        for root, dirs, files in os.walk(os.path.join(self.base, "snap")):
            for f in files:
                with open(os.path.join(root, f), "rb") as fh:
                    self.assertNotIn(b"TOP-SECRET", fh.read())

    def test_symlink_planted_before_restore_is_replaced_not_followed(self):
        put(self.F("/rootfile"), "ROOT-OWNED", mode=0o644)
        self.lib.snap_save("autobrr", "new")
        os.unlink(self.cfg + "/autobrr.db")
        os.symlink(self.F("/rootfile"), self.cfg + "/autobrr.db")
        os.lchown(self.cfg + "/autobrr.db", self.u1.pw_uid, self.u1.pw_gid)
        self.lib.snap_restore("autobrr", "new")
        self.assertEqual(read(self.F("/rootfile")), "ROOT-OWNED")
        self.assertFalse(os.path.islink(self.cfg + "/autobrr.db"))
        self.assertEqual(read(self.cfg + "/autobrr.db"), "db-old")

    def test_folder_given_to_another_user_is_not_written(self):
        self.lib.snap_save("autobrr", "new")
        own_tree(self.cfg, self.u2)
        put(self.cfg + "/autobrr.db", "u2-data", self.u2, 0o600)
        ok, why = self.lib.snap_restore("autobrr", "new")
        self.assertFalse(ok)
        self.assertEqual(read(self.cfg + "/autobrr.db"), "u2-data")

    def test_user_folder_swapped_for_symlink_to_root_folder(self):
        put(self.F("/etc/victim"), "KEEP", mode=0o644)
        self.lib.snap_save("autobrr", "new")
        shutil.rmtree(self.cfg)
        os.symlink(self.F("/etc"), self.cfg)
        os.lchown(self.cfg, self.u1.pw_uid, self.u1.pw_gid)
        self.lib.snap_restore("autobrr", "new")
        self.assertEqual(read(self.F("/etc/victim")), "KEEP")
        self.assertFalse(os.path.exists(self.F("/etc/autobrr.db")))

    def test_program_in_a_user_writable_folder_is_handled_as_that_user(self):
        os.chmod(self.F("/usr/bin"), 0o777)       # nonsense setup: root must not write there as root
        complete, _ = self.lib.snap_save("autobrr", "new")
        self.assertFalse(complete)
        os.chmod(self.F("/usr/bin"), 0o755)


class Servarr(Base):
    def setUp(self):
        super().setUp()
        prog = self.F("/opt/Prowlarr")
        os.makedirs(prog + "/bin")
        put(prog + "/Prowlarr", "exe-old", mode=0o755)
        put(prog + "/bin/Prowlarr.Core.dll", "core-old")
        own_tree(prog, self.u1)
        data = "/home/{}/.config/Prowlarr".format(U1)
        os.makedirs(self.F(data))
        own_tree(self.F("/home/{}/.config".format(U1)), self.u1)
        put(self.F("/etc/systemd/system/prowlarr.service"),
            "[Service]\nUser={}\nExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data={}\n".format(U1, data))
        self.db = self.F(data + "/prowlarr.db")
        con = sqlite3.connect(self.db)
        con.execute("pragma journal_mode=wal")
        con.execute("create table t (v text)")
        con.execute("insert into t values ('old')")
        con.commit()
        con.close()
        for f in os.listdir(self.F(data)):
            os.chown(os.path.join(self.F(data), f), self.u1.pw_uid, self.u1.pw_gid)

    def test_program_folder_and_live_database(self):
        complete, reason = self.lib.snap_save("prowlarr", "new")
        self.assertTrue(complete, reason)
        put(self.F("/opt/Prowlarr/Prowlarr"), "exe-new", self.u1, 0o755)
        put(self.F("/opt/Prowlarr/bin/extra.dll"), "x", self.u1)
        con = sqlite3.connect(self.db)
        con.execute("update t set v='migrated'")
        con.commit()
        con.close()
        self.lib.snap_keep("prowlarr", "1.0", "2.0")
        self.lib.snap_check("prowlarr")
        ok, why = self.lib.snap_restore("prowlarr", "last")
        self.assertTrue(ok, why)
        self.assertEqual(read(self.F("/opt/Prowlarr/Prowlarr")), "exe-old")
        self.assertFalse(os.path.exists(self.F("/opt/Prowlarr/bin/extra.dll")))
        self.assertEqual(os.stat(self.F("/opt/Prowlarr")).st_uid, self.u1.pw_uid)
        self.assertEqual(os.stat(self.F("/opt/Prowlarr/Prowlarr")).st_uid, self.u1.pw_uid)
        self.assertFalse(os.path.exists(self.F("/opt/.Prowlarr.panel-old")))
        con = sqlite3.connect(self.db)
        self.assertEqual(con.execute("select v from t").fetchone()[0], "old")
        con.close()
        self.assertTrue(self.lib.snap_verify("prowlarr", "last"))


class Packages(Base):
    def test_package_app_copy_runs_through(self):
        # Jellyfin: package copies (not installed here, so the copy is incomplete) + databases as their owner
        data = self.F("/var/lib/jellyfin/data")
        os.makedirs(data)
        for d in (self.F("/var"), self.F("/var/lib")):
            os.chmod(d, 0o755)
        put(data + "/jellyfin.db", "jf-db", self.u1, 0o600)
        own_tree(self.F("/var/lib/jellyfin"), self.u1)
        complete, reason = self.lib.snap_save("jellyfin", "new")
        self.assertFalse(complete)
        self.assertIn("jellyfin", reason)
        meta = self.lib.snap_meta("jellyfin", "new")
        db = [i for i in meta["items"] if i.get("path", "").endswith("jellyfin.db")][0]
        self.assertEqual((db["state"], db["uid"]), ("present", self.u1.pw_uid))
        self.lib.snap_keep("jellyfin", "1", "2")
        self.assertNotIn("jellyfin", self.lib.read_json(os.path.join(self.base, "rollback.json"), {}))

    def test_package_fingerprint_needs_no_path(self):
        fp = self.lib.fingerprint({"type": "debs", "pkgs": ["swz-no-such-package"], "role": "prog"})
        self.assertEqual(fp, "swz-no-such-package=-")


class History(Base):
    def test_cap_logs_and_detection(self):
        log = os.path.join(self.tmp, "job.log")
        put(log, "\n".join("line %d \x1b[32mok\x1b[0m" % i for i in range(500)))
        first = self.lib.history_add("autobrr", "upgrade", "done", "1.0", "1.1", by=U1, message="ok", log=log)
        self.assertTrue(os.path.isfile(os.path.join(self.base, "history", first + ".log")))
        text = read(os.path.join(self.base, "history", first + ".log"))
        self.assertNotIn("\x1b", text)
        self.assertLessEqual(len(text.splitlines()), self.lib.LOG_LINES)
        # the panel's own update isn't recorded again as an outside change
        self.assertFalse(self.lib.note_detected("autobrr", "1.0", "1.1"))
        self.assertTrue(self.lib.note_detected("autobrr", "1.1", "1.2"))
        e = self.lib.history_entries()[0]
        self.assertEqual((e["action"], e["from"], e["to"], e["message"]), ("detected", "1.1", "1.2", "Updated outside the panel"))
        for i in range(self.lib.HISTORY_MAX + 5):
            self.lib.history_add("radarr", "upgrade", "done", "1", "2", message="m%d" % i)
        self.assertEqual(len(self.lib.history_entries()), self.lib.HISTORY_MAX)
        self.assertFalse(os.path.exists(os.path.join(self.base, "history", first + ".log")))   # pruned with its entry
        st = os.stat(os.path.join(self.base, "history.json"))
        self.assertEqual(st.st_mode & 0o777, 0o640)
        self.assertEqual(os.stat(os.path.join(self.base, "snap")).st_mode & 0o777, 0o700)

    def test_messages_are_cleaned(self):
        self.lib.history_add("autobrr", "upgrade", "failed", "1", "2", by="bad user!", message="a\nb\x00c" + "x" * 900)
        e = self.lib.history_entries()[0]
        self.assertIsNone(e["by"])
        self.assertNotIn("\n", e["message"])
        self.assertLessEqual(len(e["message"]), 300)

    def test_hold_release(self):
        self.lib.hold("autobrr", "1.2.3", U1)
        self.assertEqual(self.lib.holds()["autobrr"]["version"], "1.2.3")
        self.assertTrue(self.lib.release("autobrr", U1))
        self.assertNotIn("autobrr", self.lib.holds())
        self.assertFalse(self.lib.release("autobrr", U1))
        acts = [e["action"] for e in self.lib.history_entries()]
        self.assertEqual(acts[:2], ["release", "hold"])


class FakeArr(http.server.BaseHTTPRequestHandler):
    state = {}

    def log_message(self, *a):
        pass

    def _send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        s = self.state
        if self.headers.get("X-Api-Key") != "k" * 32:
            return self._send(401, {})
        if self.path.endswith("/system/status"):
            s["polls"] = s.get("polls", 0) + 1
            if s.get("updating") and s["polls"] > 3:
                s["version"] = s["target"]
            return self._send(200, {"version": s["version"]})
        if self.path.endswith("/update"):
            return self._send(200, [{"version": v} for v in s["available"]])
        if "/command/" in self.path:
            return self._send(200, {"status": s.get("cmd_status", "started"), "message": s.get("cmd_message")})
        return self._send(404, {})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        self.state["posted"] = body
        if not self.state.get("broken"):
            self.state["updating"] = True
        self._send(201, {"id": 7})


class ArrUpdate(Base):
    def setUp(self):
        super().setUp()
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), FakeArr)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        put(os.path.join(self.base, "arr.json"), json.dumps(
            {"prowlarr": {"url": "http://127.0.0.1:%d" % self.srv.server_port, "key": "k" * 32}}))
        os.makedirs(self.base, exist_ok=True)
        FakeArr.state = {"version": "2.6.5.1", "available": ["2.7.0.1"], "target": "2.7.0.1"}

    def tearDown(self):
        self.srv.shutdown()
        super().tearDown()

    def test_update_installs(self):
        rc, msg, frm, to = self.lib.arr_update("prowlarr")
        self.assertEqual((rc, frm, to), (0, "2.6.5.1", "2.7.0.1"), msg)
        self.assertNotIn("installMajorUpdate", FakeArr.state["posted"])

    def test_major_needs_confirming(self):
        FakeArr.state.update(available=["3.1.0.5"], target="3.1.0.5")
        rc, msg, _, _ = self.lib.arr_update("prowlarr")
        self.assertEqual(rc, 100)
        self.assertNotIn("posted", FakeArr.state)
        rc, msg, _, to = self.lib.arr_update("prowlarr", major=True)
        self.assertEqual((rc, to), (0, "3.1.0.5"))
        self.assertTrue(FakeArr.state["posted"].get("installMajorUpdate"))

    def test_updater_failure_reason_comes_through(self):
        FakeArr.state.update(broken=True, cmd_status="failed", cmd_message="Unable to install update: disk full")
        rc, msg, _, _ = self.lib.arr_update("prowlarr")
        self.assertEqual(rc, 1)
        self.assertIn("disk full", msg)

    def test_nothing_newer(self):
        FakeArr.state.update(available=["2.6.5.1"])
        rc, _, frm, to = self.lib.arr_update("prowlarr")
        self.assertEqual((rc, frm, to), (100, "2.6.5.1", "2.6.5.1"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
