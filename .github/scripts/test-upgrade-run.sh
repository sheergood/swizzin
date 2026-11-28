#!/bin/bash
# CI: scripts/panel-upgrade-run end to end, with systemctl/dpkg-query/apt-get and the app's upgrade
# script faked. Checks: a good upgrade keeps the new program and data; an upgrade whose app doesn't
# come back puts back both the old program AND its old database; an apt "upgrade" that leaves the
# same version installed is reported as failed, not as done; the app is never left stopped.
# Run as root on a throwaway machine (it shadows systemctl/dpkg-query/apt-get in /usr/sbin while it
# runs and removes them at the end). Run it as the last step.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
for f in systemctl dpkg-query apt-get; do
    [[ ! -e /usr/sbin/$f ]] || { echo "::error::/usr/sbin/$f exists; refusing to shadow it"; exit 1; }
done
u=$(mktemp -d)
cleanup() {
    rm -f /usr/sbin/systemctl /usr/sbin/dpkg-query /usr/sbin/apt-get
}
trap cleanup EXIT
[[ -e /etc/swizzin ]] || ln -s "$repo" /etc/swizzin
fake=$(mktemp -d)
mkdir -p "$fake/upgrade"
[[ -e /usr/local/bin/swizzin ]] || ln -s "$fake" /usr/local/bin/swizzin
[[ -f /root/.master.info ]] || echo "ci:ci-Pass-123" > /root/.master.info
getent group swizzin > /dev/null || groupadd -r swizzin
master=$(cut -d: -f1 < /root/.master.info)
cfg=/home/${master}/.config/autobrr
mkdir -p "$cfg"

cat > /usr/sbin/systemctl << EOF
#!/bin/bash
U=$u
if [[ \$1 == is-active ]]; then shift; [[ \$1 == -q ]] && shift; [[ -f \$U/\$1 ]]; exit; fi
case "\$1" in
    stop) rm -f "\$U/\$2" ;;
    start)
        if [[ \$2 == autobrr@* ]] && grep -q new /usr/bin/autobrr && [[ -f \$U/broken ]]; then exit 1; fi
        touch "\$U/\$2" ;;
esac
exit 0
EOF
printf '#!/bin/bash\necho -n "1.41.5.9522-abc"\n' > /usr/sbin/dpkg-query
printf '#!/bin/bash\necho "apt-get $*"\nexit 0\n' > /usr/sbin/apt-get
chmod +x /usr/sbin/systemctl /usr/sbin/dpkg-query /usr/sbin/apt-get
cat > "$fake/upgrade/autobrr.sh" << EOF
#!/bin/bash
echo new > /usr/bin/autobrr; echo new > /usr/bin/autobrrctl
echo migrated-schema > $cfg/autobrr.db
systemctl try-restart autobrr@${master}
EOF
cp -a /usr/bin/autobrr /tmp/autobrr.ci-keep 2> /dev/null || true
reset() {
    echo old > /usr/bin/autobrr
    echo old > /usr/bin/autobrrctl
    echo old-schema > "$cfg/autobrr.db"
    echo wal > "$cfg/autobrr.db-wal"
    touch "$u/autobrr@${master}"
    rm -f "$u/broken"
}
state() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "/var/lib/swizzin/upgrades/$1.json"; }
fail() { echo "::error::$*"; tail -n 20 /var/lib/swizzin/upgrades/*.log || true; exit 1; }

reset
bash "$repo/scripts/panel-upgrade-run" autobrr
[[ $(state autobrr) == "done" ]] || fail "good upgrade not reported done"
[[ $(cat /usr/bin/autobrr) == new && $(cat "$cfg/autobrr.db") == migrated-schema ]] || fail "good upgrade didn't keep the new program/data"
[[ -f $u/autobrr@${master} ]] || fail "autobrr left stopped after a good upgrade"
[[ ! -e /usr/bin/autobrr.panel-prev ]] || fail "backup left behind"
echo "ok: good upgrade"

reset
touch "$u/broken"
bash "$repo/scripts/panel-upgrade-run" autobrr
[[ $(state autobrr) == failed ]] || fail "broken upgrade not reported failed"
[[ $(cat /usr/bin/autobrr) == old ]] || fail "old program not restored"
[[ $(cat "$cfg/autobrr.db") == old-schema && $(cat "$cfg/autobrr.db-wal") == wal ]] || fail "old database not restored with the old program"
[[ -f $u/autobrr@${master} ]] || fail "autobrr left stopped after the restore"
echo "ok: broken upgrade restores program and data"

mkdir -p /install
touch /install/.plex.lock "$u/plexmediaserver"
bash "$repo/scripts/panel-upgrade-run" plex
[[ $(state plex) == failed ]] || fail "apt no-op reported as $(state plex)"
grep -q "nothing newer was installed" /var/lib/swizzin/upgrades/plex.log || fail "apt no-op not explained in the log"
rm -f /install/.plex.lock
echo "ok: apt no-op reported as failed"

[[ -f /tmp/autobrr.ci-keep ]] && mv -f /tmp/autobrr.ci-keep /usr/bin/autobrr
echo "panel-upgrade-run ok"
