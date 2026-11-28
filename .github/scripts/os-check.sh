#!/bin/bash
# Runs INSIDE a throwaway Debian container with systemd (see .github/workflows/os-check.yml): a
# fresh swizzin install from this checkout, then each app one by one, then `box update`, then a
# check that every service the apps created runs and that their pages answer through nginx.
# Every step is recorded, failed ones too, so one broken app doesn't hide the others. Writes
# /root/os-check.md (a table) and keeps all logs in /root/os-check-logs.
#
# env: APPS (space separated, in install order), ALLOW_RELEASE=yes (add this Debian release to
#      swizzin's supported list in this copy only, for releases the fork doesn't support yet)
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
release=$(. /etc/os-release && echo "$VERSION_CODENAME")
src=/root/swizzin
out=/root/os-check.md
logs=/root/os-check-logs
user=ci
pass='Ci-Pass-1234567890'
failed=0
apps=${APPS:-autobrr deluge filebrowser fbquantum jellyfin prowlarr qbittorrent radarr sonarr letsencrypt}
# answers the installers would otherwise ask for
export QBITTORRENT_VERSION=latest DELUGE_VERSION=2.1.x RTORRENT_VERSION=0.15.5 TRANSMISSION_VERSION=Repo SKIPCRACKLIB=true
# Let's Encrypt: a name with no public DNS, kept out of the default site, plain HTTP check
export LE_HOSTNAME=os-check.example LE_DEFAULTCONF=no LE_BOOL_CF=no

row() { # step result seconds note   (➖ = not checkable here, doesn't count as a failure)
    printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >> "$out"
    [[ $2 == "✅" || $2 == "➖" ]] || failed=1
}
clean() { sed 's/\x1b\[[0-9;]*m//g; s/\x1b(B//g; s/|/\\|/g' | tr -s ' \t' ' ' | cut -c1-170; }
tailnote() { # last useful error line of a log, for the table
    grep -aE "ERROR|Error|error:|failed|Failed|not supported|No such|E: |Unable to" "$1" 2> /dev/null | tail -n1 | clean
}
step() { # name command... -> rc; output in $logs/<name>.log, duration in .secs
    local name=$1 t0 rc log
    shift
    log="$logs/${name// /_}.log"
    t0=$(date +%s)
    timeout 60m "$@" > "$log" 2>&1 < /dev/null
    rc=$?
    echo "$(($(date +%s) - t0))" > "$log.secs"
    return $rc
}
unitfiles() { systemctl list-unit-files --type=service --no-legend --plain 2> /dev/null | awk '{print $1}' | sort; }

mkdir -p "$logs"
{
    echo "### Debian ${release} ($(. /etc/os-release && echo "$VERSION_ID")), $(uname -m)"
    echo
    echo "| Step | Result | Time (s) | Note |"
    echo "|---|---|---|---|"
} > "$out"

if [[ ${ALLOW_RELEASE:-no} == yes ]] && ! grep -q "|${release})" "$src/setup.sh"; then
    sed -i "s/\^(focal|bullseye|jammy|bookworm|noble)\\$/^(focal|bullseye|jammy|bookworm|noble|${release})\$/" "$src/setup.sh"
    sed -i "s/\"focal\" | \"bullseye\" | \"jammy\" | \"bookworm\" | \"noble\")/\"focal\" | \"bullseye\" | \"jammy\" | \"bookworm\" | \"noble\" | \"${release}\")/" "$src/scripts/box"
    row "allow ${release} in this test copy" "✅" 0 "installer and box release lists"
fi

# --- 1. base install: nginx + panel through the real installer
step "setup nginx panel" bash "$src/setup.sh" --local --unattend --skip-cracklib --user "$user" --pass "$pass" nginx panel
rc=$?
secs=$(cat "$logs/setup_nginx_panel.log.secs")
if [[ $rc -eq 0 && -f /install/.nginx.lock && -f /install/.panel.lock ]]; then
    row "install: swizzin + nginx + panel" "✅" "$secs" ""
else
    row "install: swizzin + nginx + panel" "❌" "$secs" "exit ${rc}: $(tailnote "$logs/setup_nginx_panel.log") $(tailnote /root/logs/swizzin.log)"
    exit 1 # nothing else can be tested without the base
fi
box=/etc/swizzin/scripts/box
declare -A app_units=([nginx]=nginx [panel]=panel)

# GitHub API calls (autobrr, Filebrowser, qui... look up their latest release there) get the job's
# read-only token, so the shared anonymous limit can't fail the installs. Test machine only: curl is
# wrapped, and the token goes to api.github.com and nowhere else.
if [[ -n ${GH_TOKEN:-} && -x /usr/bin/curl && ! -e /usr/bin/curl.real ]]; then
    install -m 600 /dev/null /root/.gh-token
    printf '%s' "$GH_TOKEN" > /root/.gh-token
    mv /usr/bin/curl /usr/bin/curl.real
    cat > /usr/bin/curl << 'EOCURL'
#!/bin/bash
tok=$(cat /root/.gh-token 2> /dev/null)
if [[ -n $tok ]]; then
    for a in "$@"; do
        if [[ $a == https://api.github.com/* ]]; then exec /usr/bin/curl.real -H "Authorization: Bearer ${tok}" "$@"; fi
    done
fi
exec /usr/bin/curl.real "$@"
EOCURL
    chmod 755 /usr/bin/curl
fi
unset GH_TOKEN

# --- 2. each app on its own; remember which services it created
for app in $apps; do
    before=$(unitfiles)
    step "install $app" bash "$box" install "$app"
    rc=$?
    secs=$(cat "$logs/install_${app}.log.secs")
    units=""
    for uf in $(comm -13 <(echo "$before") <(unitfiles)); do
        base=${uf%.service}
        if [[ $base == *@ ]]; then
            if systemctl is-enabled -q "${base}${user}" 2> /dev/null; then units+=" ${base}${user}"; fi
        elif systemctl is-enabled -q "$base" 2> /dev/null; then
            units+=" $base"
        fi
    done
    app_units[$app]=${units# }
    if [[ $app == letsencrypt ]]; then
        # issuing needs a public domain; everything before it must work, and nginx must survive
        log="$logs/install_letsencrypt.log"
        if [[ -x /root/.acme.sh/acme.sh ]] && grep -q "Certificate could not be issued" "$log" &&
            ! grep -qE "Could not upgrade acme.sh|set default certificate authority" "$log" && systemctl is-active -q nginx && nginx -t > /dev/null 2>&1; then
            row "install: letsencrypt" "➖" "$secs" "acme.sh $(/root/.acme.sh/acme.sh --version 2> /dev/null | tail -n1) set up; issuing a certificate needs a public domain; nginx fine after the failed issue"
        elif [[ $rc -eq 0 && -f /install/.letsencrypt.lock ]]; then
            row "install: letsencrypt" "✅" "$secs" ""
        else
            row "install: letsencrypt" "❌" "$secs" "exit ${rc}: $(tailnote "$log")"
        fi
        continue
    fi
    if [[ $rc -eq 0 && -f /install/.${app}.lock ]]; then
        row "install: $app" "✅" "$secs" "${units:+services:$units}"
    else
        note=$(tailnote "$logs/install_${app}.log")
        [[ -n $note ]] || note=$(tailnote /root/logs/swizzin.log)
        [[ $rc -eq 124 ]] && note="timed out after 60 min. $note"
        row "install: $app" "❌" "$secs" "exit ${rc}: ${note}"
    fi
done

# --- 3. box update (no git pull here: this checkout is the code under test)
# A server set up before Plex retired its old apt repository still points at it, and then every
# apt update fails. Put that old entry back to check box update moves it (as on real servers).
if [[ -f /install/.plex.lock ]]; then
    rm -f /etc/apt/sources.list.d/plex*.list
    echo "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" > /etc/apt/sources.list.d/plexmediaserver.list
fi
step "box update" bash "$box" update
rc=$?
secs=$(cat "$logs/box_update.log.secs")
if [[ $rc -eq 0 ]]; then
    row "box update" "✅" "$secs" ""
    if [[ -f /install/.plex.lock ]]; then
        if grep -rqs 'downloads.plex.tv/repo/deb' /etc/apt/sources.list.d/ || ! grep -rqs 'repo.plex.tv/deb' /etc/apt/sources.list.d/; then
            row "box update moved Plex to its new apt repository" "❌" "" "$(cat /etc/apt/sources.list.d/plex* 2> /dev/null | tr '\n' ' ' | clean)"
        else
            row "box update moved Plex to its new apt repository" "✅" "" ""
        fi
    fi
else
    row "box update" "❌" "$secs" "exit ${rc}: $(tailnote "$logs/box_update.log")"
fi

# --- 4. is everything running and answering?
sleep 30
for app in nginx panel $apps; do
    if [[ -z ${app_units[$app]:-} ]]; then
        if [[ $app == plex ]] && dpkg-query -W -f='${db:Status-Status}' plexmediaserver 2> /dev/null | grep -q '^installed' &&
            ! systemctl cat plexmediaserver > /dev/null 2>&1; then
            # Plex's package doesn't create its service inside containers ("Docker detected")
            row "running: plexmediaserver" "➖" "" "not checkable in a container; package $(dpkg-query -W -f='${Version}' plexmediaserver) installed"
        fi
        continue
    fi
    for u in ${app_units[$app]}; do
        if systemctl is-active -q "$u"; then
            row "running: $u" "✅" "" ""
        else
            row "running: $u" "❌" "" "$(systemctl is-active "$u" 2>&1); $(journalctl -u "$u" -n 3 --no-pager 2> /dev/null | tail -n1 | clean)"
            {
                systemctl status "$u" --no-pager -l 2>&1 | head -n 30
                journalctl -u "$u" -n 80 --no-pager 2>&1
                # 203/EXEC means the program in ExecStart isn't there: show where the package put it
                exe=$(systemctl show -p ExecStart "$u" 2> /dev/null | grep -oP 'path=\K[^ ;]+' | head -n1)
                echo "--- ExecStart program: ${exe:-?}"
                [[ -n $exe ]] && ls -l "$exe" 2>&1
                pkg=$(dpkg -S "$(basename "${exe:-none}")" 2> /dev/null | head -n3)
                echo "--- packages with that name: ${pkg:-none}"
                for p in $(dpkg-query -W -f='${Package}\n' 2> /dev/null | grep -E "^(deluge|python3-deluge)"); do
                    echo "--- files of $p (bin)"
                    dpkg -L "$p" 2> /dev/null | grep -E '/bin/|dist-packages/deluge/?$|site-packages/deluge/?$' | head -n 20
                done
            } > "$logs/zz_journal_${u}.log"
        fi
    done
done
# fail2ban: running, with swizzin's web jails
if systemctl is-active -q fail2ban; then
    jails=$(fail2ban-client status 2> /dev/null | grep -oP 'Jail list:\s*\K.*')
    missing=""
    for j in swizzin-panel swizzin-nginx-auth swizzin-filebrowser swizzin-scan; do
        [[ $jails == *"$j"* ]] || missing+=" $j"
    done
    if [[ -z $missing ]]; then
        row "fail2ban with swizzin's web jails" "✅" "" "jails: ${jails}"
    else
        row "fail2ban with swizzin's web jails" "❌" "" "missing:${missing}; running: ${jails}"
    fi
else
    row "fail2ban with swizzin's web jails" "❌" "" "fail2ban $(systemctl is-active fail2ban 2>&1); $(journalctl -u fail2ban -n 2 --no-pager 2> /dev/null | tail -n1 | clean)"
    journalctl -u fail2ban -n 60 --no-pager > "$logs/zz_journal_fail2ban.log" 2>&1
fi
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8333/login)
[[ $code == 200 ]] && row "panel answers (127.0.0.1:8333/login)" "✅" "" "HTTP $code" || row "panel answers (127.0.0.1:8333/login)" "❌" "" "HTTP $code"
# every app with an nginx config: its page must answer (2xx-4xx; 5xx or nothing = broken)
for conf in /etc/nginx/apps/*.conf; do
    [[ -f $conf && $(basename "$conf") != panel.conf ]] || continue
    path=$(grep -oP '^\s*location\s+(\^~\s+|=\s+)?\K/[A-Za-z0-9_.-]+' "$conf" | head -n1)
    [[ -n $path ]] || continue
    code=$(curl -sk -o /dev/null -m 20 -w '%{http_code}' -u "${user}:${pass}" -H "Host: os-check.example" "https://127.0.0.1${path}/")
    case $code in
        2?? | 3?? | 4??) row "through nginx: ${path}" "✅" "" "HTTP $code" ;;
        *) row "through nginx: ${path}" "❌" "" "HTTP $code ($(basename "$conf"))" ;;
    esac
done
code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' -u "${user}:${pass}" -H "Host: os-check.example" https://127.0.0.1/)
[[ $code == 200 ]] && row "through nginx: / (panel)" "✅" "" "HTTP $code" || row "through nginx: / (panel)" "❌" "" "HTTP $code"
# --- 5. the panel's upgrade jobs on real apps: copy, upgrade, rollback, hold (panel-upgrade-run)
L() { python3 -I /etc/swizzin/scripts/panel-upgrade-lib "$@"; }
jobstate() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['state'], '|', d['message'])" "/var/lib/swizzin/upgrades/$1.json" 2> /dev/null; }
lasthist() { python3 -c "import json,sys; e=json.load(open(sys.argv[1]))['entries'][0]; print(e['app'], e['action'], e['result'], e.get('from'), e.get('to'), '|', e.get('message'))" /var/lib/swizzin/upgrades/history.json 2> /dev/null; }
python3 /etc/swizzin/scripts/panel-host-collect > "$logs/panel-host-collect.log" 2>&1 || true
step "update check" python3 /etc/swizzin/scripts/panel-updates-check || true
if [[ -f /install/.autobrr.lock ]]; then
    t0=$(date +%s)
    step "panel upgrade autobrr" bash /etc/swizzin/scripts/panel-upgrade-run autobrr --by "$user"
    st=$(jobstate autobrr)
    if [[ $st == done* ]] && grep -q '"autobrr"' /var/lib/swizzin/upgrades/rollback.json 2> /dev/null; then
        row "panel: upgrade autobrr (copy kept for rollback)" "✅" "$(($(date +%s) - t0))" "$(lasthist)"
    else
        row "panel: upgrade autobrr (copy kept for rollback)" "❌" "$(($(date +%s) - t0))" "${st:-no state}; $(tail -n2 /var/lib/swizzin/upgrades/autobrr.log | tr '\n' ' ' | clean)"
    fi
    t0=$(date +%s)
    step "panel rollback autobrr" bash /etc/swizzin/scripts/panel-upgrade-run --rollback autobrr --by "$user"
    st=$(jobstate autobrr)
    if [[ $st == done* ]] && systemctl is-active -q "autobrr@${user}" && [[ $(L held autobrr) != "" ]]; then
        row "panel: roll back autobrr (running, held)" "✅" "$(($(date +%s) - t0))" "$(lasthist)"
    else
        row "panel: roll back autobrr (running, held)" "❌" "$(($(date +%s) - t0))" "${st:-no state}; $(systemctl is-active "autobrr@${user}"); $(tail -n3 /var/lib/swizzin/upgrades/autobrr.log | tr '\n' ' ' | clean)"
    fi
    L release autobrr > /dev/null 2>&1 || true
fi
if [[ -f /install/.jellyfin.lock ]]; then
    # the package copy (apt-get download) and the database copy as the jellyfin user, put back for real
    t0=$(date +%s)
    systemctl stop jellyfin
    note=""
    L snap-save jellyfin new > "$logs/panel_copy_jellyfin.log" 2>&1 && L snap-restore jellyfin new >> "$logs/panel_copy_jellyfin.log" 2>&1 || note="copy or restore failed: $(tail -n2 "$logs/panel_copy_jellyfin.log" | tr '\n' ' ' | clean)"
    systemctl start jellyfin
    sleep 10
    systemctl is-active -q jellyfin || note="${note} jellyfin didn't start after the restore"
    L snap-drop jellyfin new > /dev/null 2>&1
    [[ -z $note ]] && row "panel: copy + restore jellyfin (packages + databases)" "✅" "$(($(date +%s) - t0))" "$(grep -c '^' "$logs/panel_copy_jellyfin.log") log lines" ||
        row "panel: copy + restore jellyfin (packages + databases)" "❌" "$(($(date +%s) - t0))" "$note"
fi
if [[ -f /install/.prowlarr.lock ]]; then
    # put an older Prowlarr in place, let the panel update it with Prowlarr's own updater, then roll back
    t0=$(date +%s)
    key=$(grep -oP '(?<=<ApiKey>)[^<]+' "/home/${user}/.config/Prowlarr/config.xml" 2> /dev/null)
    port=$(grep -oP '(?<=<Port>)[^<]+' "/home/${user}/.config/Prowlarr/config.xml" 2> /dev/null)
    base=$(grep -oP '(?<=<UrlBase>)[^<]+' "/home/${user}/.config/Prowlarr/config.xml" 2> /dev/null)
    api="http://127.0.0.1:${port:-9696}${base:+/${base#/}}/api/v1"
    ver() { curl -s -m 5 -H "X-Api-Key: $key" "$api/system/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" 2> /dev/null; }
    cur=$(ver)
    older=$(curl -s -m 20 -H "X-Api-Key: $key" "$api/update" | python3 -c "
import json, re, sys
cur = tuple(int(x) for x in re.findall(r'\d+', sys.argv[1])[:4])
ups = [u for u in json.load(sys.stdin) if u.get('url') and tuple(int(x) for x in re.findall(r'\d+', u.get('version', ''))[:4]) < cur]
ups.sort(key=lambda u: tuple(int(x) for x in re.findall(r'\d+', u['version'])[:4]), reverse=True)
# two steps back when there is one: the newest release can be ahead of what the updater offers for a day
pick = ups[1] if len(ups) > 1 and ups[1]['version'].split('.')[0] == sys.argv[1].split('.')[0] else (ups[0] if ups else None)
print(pick['version'], pick['url']) if pick else None" "$cur" 2> /dev/null)
    if [[ -z $cur || -z $older ]]; then
        row "panel: Prowlarr update + rollback" "➖" "" "no older Prowlarr offered by its update list (installed ${cur:-?})"
    else
        oldver=${older%% *} oldurl=${older#* }
        systemctl stop prowlarr
        if curl -sfL -m 300 "$oldurl" -o /tmp/prowlarr-old.tar.gz && rm -rf /opt/Prowlarr && tar -xzf /tmp/prowlarr-old.tar.gz -C /opt; then
            chown -R "${user}:" /opt/Prowlarr
            rm -f "/home/${user}/.config/Prowlarr/prowlarr.db"*   # an older version can't open a newer database
            systemctl start prowlarr
            for _ in $(seq 1 60); do [[ -n $(ver) ]] && break; sleep 3; done
            python3 /etc/swizzin/scripts/panel-updates-check > /dev/null 2>&1 || true
            step "panel upgrade prowlarr" bash /etc/swizzin/scripts/panel-upgrade-run prowlarr --by "$user"
            st=$(jobstate prowlarr) after=$(ver)
            if [[ $st == done* && -n $after && $after != "$oldver" ]] && grep -q '"prowlarr"' /var/lib/swizzin/upgrades/rollback.json; then
                row "panel: update Prowlarr ${oldver} with its own updater" "✅" "$(($(date +%s) - t0))" "$(lasthist)"
                t0=$(date +%s)
                step "panel rollback prowlarr" bash /etc/swizzin/scripts/panel-upgrade-run --rollback prowlarr --by "$user"
                st=$(jobstate prowlarr) back=$(ver)
                if [[ $st == done* && $back == "$oldver" ]]; then
                    row "panel: roll Prowlarr back to ${oldver} (running, held)" "✅" "$(($(date +%s) - t0))" "$(lasthist)"
                else
                    row "panel: roll Prowlarr back to ${oldver} (running, held)" "❌" "$(($(date +%s) - t0))" "${st:-no state}; answers ${back:-nothing}; $(tail -n3 /var/lib/swizzin/upgrades/prowlarr.log | tr '\n' ' ' | clean)"
                fi
            else
                row "panel: update Prowlarr ${oldver} with its own updater" "❌" "$(($(date +%s) - t0))" "${st:-no state}; answers ${after:-nothing}; $(tail -n3 /var/lib/swizzin/upgrades/prowlarr.log | tr '\n' ' ' | clean)"
            fi
        else
            row "panel: Prowlarr update + rollback" "➖" "" "couldn't download Prowlarr ${oldver}"
            systemctl start prowlarr
        fi
    fi
fi
cp -r /var/lib/swizzin/upgrades/*.log /var/lib/swizzin/upgrades/history.json "$logs/" 2> /dev/null || true
# --- 6. disk history + "what's using the disk" (swizzin-disk.timer): the sums must match df exactly
t0=$(date +%s)
# a container's / is an overlay, which the panel doesn't list: point the scan at it explicitly
if systemctl is-enabled -q swizzin-disk.timer 2> /dev/null && step "disk scan" env SWZ_DISK_MOUNTS=/ python3 /etc/swizzin/scripts/panel-disk-collect --scan; then
    note=$(python3 - << 'EOPY' 2>&1
import json, os, stat
u = json.load(open("/var/lib/swizzin/disk-usage.json"))
h = json.load(open("/var/lib/swizzin/disk-history.json"))
r = u["mounts"]["/"]
st = os.statvfs("/")
cats = sum(c["bytes"] for c in r["cats"])
problems = []
if cats + r["other"] != r["used"]:
    problems.append("categories %d + other %d != used %d" % (cats, r["other"], r["used"]))
if abs(r["used"] - (st.f_blocks - st.f_bfree) * st.f_frsize) > 2 * 1024 ** 3:
    problems.append("used differs from df by over 2 GiB")
if r["over"]:
    problems.append("du counted more than df")
# folders nothing else is inside of must match a du of their own, to the KiB
import subprocess
def alone(*paths):
    out = subprocess.run(["du", "-sxkc", "--"] + [x for x in paths if os.path.isdir(x)], stdout=subprocess.PIPE, universal_newlines=True).stdout
    return int(out.strip().splitlines()[-1].split()[0]) * 1024 if out.strip() else 0
by = {c["key"]: c["bytes"] for c in r["cats"]}
for key, paths in (("logs", ["/var/log"]), ("mediadata", ["/var/lib/jellyfin", "/var/cache/jellyfin", "/var/lib/plexmediaserver"])):
    want = alone(*paths)
    if want and abs(by.get(key, 0) - want) > 64 * 1024 * 1024:
        problems.append("%s %d != du %d" % (key, by.get(key, 0), want))
for key in (["downloads"] if os.path.isdir("/home/ci/torrents") else []) + ["apps", "system", "logs"]:
    if not by.get(key):
        problems.append("no " + key)
if not h["mounts"].get("/"):
    problems.append("no history sample")
for f in ("/var/lib/swizzin/disk-usage.json", "/var/lib/swizzin/disk-history.json"):
    if stat.S_IMODE(os.stat(f).st_mode) != 0o640:
        problems.append(f + " not 0640")
G = 1024 ** 3
print("; ".join(problems) if problems else "took %ss; %s; other %.1f GiB" % (
    u["took"], ", ".join("%s %.1f GiB" % (c["key"], c["bytes"] / G) for c in r["cats"]), r["other"] / G))
EOPY
)
    if [[ $note == took* ]]; then row "disk usage scan (sums match df)" "✅" "$(($(date +%s) - t0))" "$(echo "$note" | clean)"; else
        row "disk usage scan (sums match df)" "❌" "$(($(date +%s) - t0))" "$(echo "$note" | tail -n2 | tr '\n' ' ' | clean)"
    fi
else
    row "disk usage scan (sums match df)" "❌" "$(($(date +%s) - t0))" "timer $(systemctl is-enabled swizzin-disk.timer 2>&1); $(tail -n3 "$logs/disk_scan.log" 2> /dev/null | tr '\n' ' ' | clean)"
fi


{
    echo
    echo "Python $(python3 -V 2>&1 | cut -d' ' -f2), nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+$'), PHP $(php -r 'echo PHP_VERSION;' 2> /dev/null || echo none), GCC $(gcc -dumpversion 2> /dev/null || echo none)"
} >> "$out"
exit $failed
