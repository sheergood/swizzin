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
apps=${APPS:-autobrr filebrowser prowlarr radarr sonarr qbittorrent plex}
# answers the installers would otherwise ask for
export QBITTORRENT_VERSION=latest DELUGE_VERSION=2.1.x RTORRENT_VERSION=0.15.5 TRANSMISSION_VERSION=Repo SKIPCRACKLIB=true

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
            } > "$logs/zz_journal_${u}.log"
        fi
    done
done
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
{
    echo
    echo "Python $(python3 -V 2>&1 | cut -d' ' -f2), nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+$'), PHP $(php -r 'echo PHP_VERSION;' 2> /dev/null || echo none), GCC $(gcc -dumpversion 2> /dev/null || echo none)"
} >> "$out"
exit $failed
