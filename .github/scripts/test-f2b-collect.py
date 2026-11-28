#!/usr/bin/env python3
# Tests for scripts/panel-f2b-collect's "failing now" (which addresses are failing but not banned).
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("f2b", os.path.join(HERE, "..", "..", "scripts", "panel-f2b-collect"))
spec = importlib.util.spec_from_loader("f2b", loader)
f2b = importlib.util.module_from_spec(spec)
loader.exec_module(f2b)


def line(ago, jail, ip, kind="Found"):
    t = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - ago))
    if kind == "Found":
        return "{},100 fail2ban.filter         [747]: INFO    [{}] Found {} - {}".format(t, jail, ip, t)
    return "{},100 fail2ban.actions        [747]: NOTICE  [{}] {} {}".format(t, jail, kind, ip)


class Failing(unittest.TestCase):
    def run_on(self, lines, jails, banned=None):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("\n".join(lines) + "\n")
        try:
            return f2b.failing(f.name, jails, banned or {}, int(time.time()))
        finally:
            os.unlink(f.name)

    def test_counts_within_findtime_and_after_last_ban(self):
        out = self.run_on([
            line(1200, "sshd", "198.51.100.1"),                       # older than findtime
            line(180, "sshd", "198.51.100.2"), line(120, "sshd", "198.51.100.2"),
            line(150, "swizzin-panel", "203.0.113.5"), line(60, "swizzin-panel", "203.0.113.5", "Ban"),
            line(30, "swizzin-scan", "203.0.113.9"),                  # banned right now
            line(20, "other-jail", "192.0.2.1"),                      # jail without failures
        ], {"sshd": (600, 5), "swizzin-panel": (600, 8), "swizzin-scan": (3600, 2)}, {"swizzin-scan": {"203.0.113.9"}})
        self.assertEqual([(x["ip"], x["jail"], x["count"], x["maxretry"]) for x in out], [("198.51.100.2", "sshd", 2, 5)])

    def test_failures_after_a_ban_count_again(self):
        out = self.run_on([line(300, "sshd", "198.51.100.3"), line(200, "sshd", "198.51.100.3", "Ban"),
                           line(100, "sshd", "198.51.100.3", "Unban"), line(50, "sshd", "198.51.100.3")],
                          {"sshd": (600, 5)})
        self.assertEqual([(x["ip"], x["count"]) for x in out], [("198.51.100.3", 1)])

    def test_missing_log_is_empty(self):
        self.assertEqual(f2b.failing("/nonexistent/fail2ban.log", {"sshd": (600, 5)}, {}, int(time.time())), [])


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=1))
