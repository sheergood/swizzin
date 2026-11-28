#!/bin/bash
# CI: scripts/panel-upgrade-run end to end, with systemctl/dpkg-query/apt-get and the app's upgrade
# script faked (the update check is faked too: it reports autobrr's version from its program file).
#   - a good upgrade keeps the new program and data, keeps a rollback copy, and is in the history
#   - Roll back puts back the old program AND its old database, holds the app, and the hold is honoured
#   - a rollback whose app doesn't come up is undone (the newer version runs again, the copy stays)
#   - an upgrade whose app doesn't come back puts back program and data, and keeps no rollback copy
#   - an apt "upgrade" that leaves the same version installed is reported as unchanged, not as done
#   - the app is never left stopped
# Run as root on a throwaway machine (it shadows systemctl/dpkg-query/apt-get in /usr/sbin while it
# runs and removes them at the end). Run it as the last step.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
for f in systemctl dpkg-query apt-get; do
    [[ ! -e /usr/sbin/$f ]] || { echo "::error::/usr/sbin/$f exists; refusing to shadow it"; exit 1; }
done
u=$(mktemp -d)
chmod 755 "$u"
cleanup() {
    rm -f /usr/sbin/systemctl /usr/sbin/dpkg-query /usr/sbin/apt-get
    [[ -n ${made_unit:-} ]] && rm -f /etc/systemd/system/swizzin-updates.service
    return 0
}
trap cleanup EXIT
[[ -e /etc/swizzin ]] || ln -s "$repo" /etc/swizzin
# the helper re-runs itself as the files' owners, so it must be readable by them
libdir=$(mktemp -d)
chmod 755 "$libdir"
install -m 755 "$repo/scripts/panel-upgrade-lib" "$libdir/panel-upgrade-lib"
export SWZ_UPG_LIB="$libdir/panel-upgrade-lib" SWZ_SETTLE=1
fake=$(mktemp -d)
mkdir -p "$fake/upgrade"
[[ -e /usr/local/bin/swizzin ]] || ln -s "$fake" /usr/local/bin/swizzin
[[ -f /root/.master.info ]] || echo "ci:ci-Pass-123" > /root/.master.info
getent group swizzin > /dev/null || groupadd -r swizzin
master=$(cut -d: -f1 < /root/.master.info)
id "$master" > /dev/null 2>&1 || useradd -m -s /bin/bash "$master"
cfg=/home/${master}/.config/autobrr
mkdir -p "$cfg"
chown -R "${master}:" "/home/${master}/.config"
if [[ ! -f /etc/systemd/system/swizzin-updates.service ]]; then
    touch /etc/systemd/system/swizzin-updates.service
    made_unit=1
fi
U=/var/lib/swizzin/upgrades
mkdir -p "$U"

cat > /usr/sbin/systemctl << EOF
#!/bin/bash
U=$u
if [[ \$1 == is-active || \$1 == is-enabled ]]; then shift; [[ \$1 == -q ]] && shift; [[ -f \$U/\$1 ]]; exit; fi
case "\$1" in
    stop) rm -f "\$U/\$2" ;;
    start)
        if [[ \$2 == swizzin-updates.service ]]; then
            v=1.0; grep -q new /usr/bin/autobrr && v=1.1
            printf '{"checked": %s, "apps": {"autobrr": {"installed": "%s"}}}' "\$(date +%s)" "\$v" > /var/lib/swizzin/updates.json
            exit 0
        fi
        if [[ \$2 == autobrr@* ]] && grep -q new /usr/bin/autobrr && [[ -f \$U/broken ]]; then exit 1; fi
        if [[ \$2 == autobrr@* ]] && grep -q old /usr/bin/autobrr && [[ -f \$U/brokenold ]]; then exit 1; fi
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
chown ${master}: $cfg/autobrr.db
systemctl try-restart autobrr@${master}
EOF
cp -a /usr/bin/autobrr /tmp/autobrr.ci-keep 2> /dev/null || true
mkdir -p /install
touch /install/.autobrr.lock
reset() {
    echo old > /usr/bin/autobrr
    echo old > /usr/bin/autobrrctl
    echo old-schema > "$cfg/autobrr.db"
    echo wal > "$cfg/autobrr.db-wal"
    chown "${master}:" "$cfg/autobrr.db" "$cfg/autobrr.db-wal"
    touch "$u/autobrr@${master}"
    rm -f "$u/broken" "$u/brokenold"
    rm -rf "$U/snap/autobrr" "$U/holds.json"
    systemctl start swizzin-updates.service
}
L() { python3 -I "$SWZ_UPG_LIB" "$@"; }
state() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "$U/$1.json"; }
last() { python3 -c "import json,sys; e=json.load(open(sys.argv[1]))['entries'][0]; print(e['action'], e['result'], e.get('from'), e.get('to'))" "$U/history.json"; }
fail() { echo "::error::$*"; tail -n 30 "$U"/*.log || true; exit 1; }

reset
bash "$repo/scripts/panel-upgrade-run" autobrr --by "$master"
[[ $(state autobrr) == "done" ]] || fail "good upgrade not reported done"
[[ $(cat /usr/bin/autobrr) == new && $(cat "$cfg/autobrr.db") == migrated-schema ]] || fail "good upgrade didn't keep the new program/data"
[[ -f $u/autobrr@${master} ]] || fail "autobrr left stopped after a good upgrade"
[[ ! -e /usr/bin/autobrr.panel-prev ]] || fail "old-style backup left behind"
[[ $(last) == "upgrade done 1.0 1.1" ]] || fail "history says '$(last)'"
grep -q '"autobrr"' "$U/rollback.json" || fail "no rollback copy offered after a good upgrade"
[[ $(stat -c %a "$U/snap") == 700 ]] || fail "copies readable by others"
echo "ok: good upgrade, in the history, rollback copy kept"

touch "$u/brokenold"
bash "$repo/scripts/panel-upgrade-run" --rollback autobrr --by "$master"
[[ $(state autobrr) == failed ]] || fail "a rollback whose app didn't start was reported $(state autobrr)"
[[ $(cat /usr/bin/autobrr) == new && $(cat "$cfg/autobrr.db") == migrated-schema ]] || fail "failed rollback not undone"
[[ -f $u/autobrr@${master} ]] || fail "autobrr left stopped after an undone rollback"
[[ $(last) == "rollback failed 1.1 1.0" ]] || fail "history says '$(last)'"
grep -q '"autobrr"' "$U/rollback.json" || fail "rollback copy lost after an undone rollback"
rm -f "$u/brokenold"
echo "ok: a rollback that doesn't start is undone"

bash "$repo/scripts/panel-upgrade-run" --rollback autobrr --by "$master"
[[ $(state autobrr) == "done" ]] || fail "rollback not reported done: $(cat "$U/autobrr.json")"
[[ $(cat /usr/bin/autobrr) == old && $(cat "$cfg/autobrr.db") == old-schema && $(cat "$cfg/autobrr.db-wal") == wal ]] || fail "rollback didn't put back program + data"
[[ $(stat -c %U "$cfg/autobrr.db") == "$master" ]] || fail "restored database no longer belongs to $master"
[[ -f $u/autobrr@${master} ]] || fail "autobrr left stopped after the rollback"
[[ $(last) == "rollback done 1.1 1.0" ]] || fail "history says '$(last)'"
[[ $(L held autobrr) == 1.0 ]] || fail "not held after the rollback"
! grep -q '"autobrr"' "$U/rollback.json" || fail "rollback still offered after rolling back"
echo "ok: rollback restores program and data, holds the app"

bash "$repo/scripts/panel-upgrade-run" autobrr
[[ $(state autobrr) == failed && $(cat /usr/bin/autobrr) == old ]] || fail "a held app was upgraded"
L release autobrr
echo "ok: a held app isn't upgraded"

reset
touch "$u/broken"
bash "$repo/scripts/panel-upgrade-run" autobrr
[[ $(state autobrr) == failed ]] || fail "broken upgrade not reported failed"
[[ $(cat /usr/bin/autobrr) == old ]] || fail "old program not restored"
[[ $(cat "$cfg/autobrr.db") == old-schema && $(cat "$cfg/autobrr.db-wal") == wal ]] || fail "old database not restored with the old program"
[[ -f $u/autobrr@${master} ]] || fail "autobrr left stopped after the restore"
[[ $(last) == "upgrade restored 1.0 None" ]] || fail "history says '$(last)'"
! grep -q '"autobrr"' "$U/rollback.json" || fail "rollback offered after a failed upgrade"
echo "ok: broken upgrade restores program and data"

touch /install/.plex.lock "$u/plexmediaserver"
bash "$repo/scripts/panel-upgrade-run" plex
[[ $(state plex) == failed ]] || fail "apt no-op reported as $(state plex)"
grep -q "nothing newer was installed" "$U/plex.log" || fail "apt no-op not explained in the log"
[[ $(last) == "upgrade unchanged"* ]] || fail "history says '$(last)'"
[[ -f $u/plexmediaserver ]] || fail "plex left stopped"
rm -f /install/.plex.lock
echo "ok: apt no-op reported as unchanged"

[[ -f /tmp/autobrr.ci-keep ]] && mv -f /tmp/autobrr.ci-keep /usr/bin/autobrr
echo "panel-upgrade-run ok"
