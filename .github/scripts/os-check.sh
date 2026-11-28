#!/bin/bash
# Runs INSIDE a throwaway Debian container with systemd (see .github/workflows/os-check.yml): a
# fresh swizzin install from this checkout, then each app one by one, then `box update`, then
# checks that every service runs and answers. Every step is recorded, also the failed ones, so one
# broken app doesn't hide the others. Writes /root/os-check.md (a table) and keeps all logs.
#
# env: APPS (space separated), ALLOW_RELEASE=yes (add this Debian release to swizzin's supported
#      list in this copy only, to see what happens on a release swizzin doesn't support yet)
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
release=$(. /etc/os-release && echo "$VERSION_CODENAME")
src=/root/swizzin
out=/root/os-check.md
user=ci
pass='Ci-Pass-1234567890'
failed=0

row() { # step result seconds note
    printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >> "$out"
    [[ $2 == "✅" ]] || failed=1
}
# step name, command...; output appended to /root/os-check-logs/<name>.log
step() {
    local name=$1 t0 rc log
    shift
    log="/root/os-check-logs/${name// /_}.log"
    t0=$(date +%s)
    timeout 100m "$@" > "$log" 2>&1 < /dev/null
    rc=$?
    echo "$((($(date +%s) - t0)))" > "$log.secs"
    return $rc
}
tailnote() { # last useful error line of a log, for the table
    grep -aE "ERROR|Error|error:|failed|Failed|not supported|No such|E: " "$1" 2> /dev/null | tail -n1 |
        sed 's/\x1b\[[0-9;]*m//g; s/|/\\|/g' | cut -c1-160
}

mkdir -p /root/os-check-logs
{
    echo "### Debian ${release} ($(. /etc/os-release && echo "$VERSION_ID")), $(uname -m)"
    echo
    echo "| Step | Result | Time (s) | Note |"
    echo "|---|---|---|---|"
} > "$out"

if [[ ${ALLOW_RELEASE:-no} == yes ]]; then
    # this copy only: let the installer and box accept this release
    sed -i "s/\^(focal|bullseye|jammy|bookworm|noble)\\$/^(focal|bullseye|jammy|bookworm|noble|${release})\$/" "$src/setup.sh"
    sed -i "s/\"focal\" | \"bullseye\" | \"jammy\" | \"bookworm\" | \"noble\")/\"focal\" | \"bullseye\" | \"jammy\" | \"bookworm\" | \"noble\" | \"${release}\")/" "$src/scripts/box"
    grep -q "$release" "$src/setup.sh" && grep -q "\"$release\"" "$src/scripts/box" || {
        row "allow ${release} in this test copy" "❌" 0 "couldn't patch the release lists"
        exit 1
    }
    row "allow ${release} in this test copy" "✅" 0 "installer and box release lists"
fi

# --- 1. base install: nginx + panel through the real installer
export QBITTORRENT_VERSION=latest SKIPCRACKLIB=true
step "setup nginx panel" bash "$src/setup.sh" --local --unattend --skip-cracklib --user "$user" --pass "$pass" nginx panel
rc=$?
secs=$(cat "/root/os-check-logs/setup_nginx_panel.log.secs")
if [[ $rc -eq 0 && -f /install/.nginx.lock && -f /install/.panel.lock ]]; then
    row "install: swizzin + nginx + panel" "✅" "$secs" ""
else
    row "install: swizzin + nginx + panel" "❌" "$secs" "exit ${rc}: $(tailnote /root/os-check-logs/setup_nginx_panel.log)$(tailnote /root/logs/swizzin.log)"
    exit 1   # nothing else can be tested without the base
fi
box=/etc/swizzin/scripts/box

# --- 2. each app on its own
for app in ${APPS:-autobrr filebrowser prowlarr radarr sonarr qbittorrent plex}; do
    step "install $app" bash "$box" install "$app"
    rc=$?
    secs=$(cat "/root/os-check-logs/install_${app}.log.secs")
    if [[ $rc -eq 0 && -f /install/.${app}.lock ]]; then
        row "install: $app" "✅" "$secs" ""
    else
        note=$(tailnote "/root/os-check-logs/install_${app}.log")
        [[ -n $note ]] || note=$(tailnote /root/logs/swizzin.log)
        [[ $rc -eq 124 ]] && note="timed out after 100 min. $note"
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
secs=$(cat "/root/os-check-logs/box_update.log.secs")
if [[ $rc -eq 0 ]]; then
    row "box update" "✅" "$secs" ""
    if [[ -f /install/.plex.lock ]]; then
        if grep -rqs 'downloads.plex.tv/repo/deb' /etc/apt/sources.list.d/ || ! grep -rqs 'repo.plex.tv/deb' /etc/apt/sources.list.d/; then
            row "box update moved Plex to its new apt repository" "❌" "" "$(cat /etc/apt/sources.list.d/plex* 2> /dev/null | tr '\n' ' ')"
        else
            row "box update moved Plex to its new apt repository" "✅" "" ""
        fi
    fi
else
    row "box update" "❌" "$secs" "exit ${rc}: $(tailnote /root/os-check-logs/box_update.log)"
fi

# --- 4. is everything running and answering?
sleep 20
unit_of() {
    case $1 in
        autobrr | qbittorrent) echo "$1@$user" ;;
        plex) echo plexmediaserver ;;
        *) echo "$1" ;;
    esac
}
for app in nginx panel ${APPS:-autobrr filebrowser prowlarr radarr sonarr qbittorrent plex}; do
    u=$(unit_of "$app")
    # also apps whose install stopped half-way, if their service exists
    [[ -f /install/.${app}.lock || -f /etc/systemd/system/${u}.service || -f /etc/systemd/system/${u%@*}@.service ]] || continue
    if systemctl is-active -q "$u"; then
        row "running: $u" "✅" "" ""
    else
        row "running: $u" "❌" "" "$(systemctl is-active "$u" 2>&1); $(journalctl -u "$u" -n 3 --no-pager 2> /dev/null | tail -n1 | sed 's/|/\\|/g' | cut -c1-140)"
        # why: the unit's own output, kept with the other logs
        {
            systemctl status "$u" --no-pager -l 2>&1 | head -n 30
            journalctl -u "$u" -n 80 --no-pager 2>&1
            [[ -f /etc/systemd/system/${u}.service ]] && cat "/etc/systemd/system/${u}.service"
        } > "/root/os-check-logs/zz_journal_${u}.log"
    fi
done
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8333/login)
[[ $code == 200 ]] && row "panel answers (127.0.0.1:8333/login)" "✅" "" "HTTP $code" || row "panel answers (127.0.0.1:8333/login)" "❌" "" "HTTP $code"
for path in "" sonarr radarr prowlarr autobrr filebrowser qbittorrent; do
    [[ -z $path || -f /install/.${path}.lock ]] || continue
    code=$(curl -sk -o /dev/null -m 15 -w '%{http_code}' -u "${user}:${pass}" -H "Host: os-check.example" "https://127.0.0.1/${path}${path:+/}")
    case $code in
        2?? | 3??) row "through nginx: /${path}" "✅" "" "HTTP $code" ;;
        *) row "through nginx: /${path}" "❌" "" "HTTP $code" ;;
    esac
done
{
    echo
    echo "Python $(python3 -V 2>&1 | cut -d' ' -f2), nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+$'), PHP $(php -r 'echo PHP_VERSION;' 2> /dev/null || echo none), qBittorrent $(qbittorrent-nox --version 2> /dev/null | grep -oE '[0-9.]+' | head -n1 || echo none)"
} >> "$out"
exit $failed
