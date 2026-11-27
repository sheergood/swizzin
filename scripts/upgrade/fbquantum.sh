#!/usr/bin/env bash
# box upgrade fbquantum — newest stable FileBrowser Quantum, rolled back automatically if it fails to start.
# Also moves installs from before Nov 27 2026 (TCP port + separate Quantum login) to the unix socket and
# swizzin single sign-on, which fixes the browser login popup that logged you out of the dashboard.

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/fbquantum
. /etc/swizzin/sources/functions/fbquantum

if [[ ! -f /install/.fbquantum.lock ]]; then
    echo_error "FileBrowser Quantum does not appear to be installed!"
    exit 1
fi

username="$(_get_master_username)"
confdir="/home/${username}/.config/fbquantum"
config="${confdir}/config.yaml"
db="${confdir}/fbquantum.db"
current="$(fbquantum_installed_version)"

cfgver="$(fbquantum_config_version "$config")"
migrate=false
[[ $cfgver -lt $FBQ_CONFIG_VERSION ]] && migrate=true

read -r latest _ <<< "$(fbquantum_latest_stable)"
if [[ -n $latest && $latest == "$current" && $migrate == false ]]; then
    echo_success "FileBrowser Quantum is already up to date (${current})"
    exit 0
fi

# copies to roll back to: database (a new version may migrate it), config, service, nginx
cp -p "$db" "${db}.pre-upgrade" 2> /dev/null || true
cp -p "$config" "${config}.pre-upgrade" 2> /dev/null || true
cp -p /etc/systemd/system/fbquantum.service /tmp/fbquantum.service.pre-upgrade 2> /dev/null || true
cp -p /etc/nginx/apps/fbquantum.conf /tmp/fbquantum.nginx.pre-upgrade 2> /dev/null || true
cp -p /etc/nginx/snippets/fbquantum-proxy.conf /tmp/fbquantum.snippet.pre-upgrade 2> /dev/null || true

if [[ -n $latest && $latest != "$current" ]]; then
    echo_progress_start "Upgrading FileBrowser Quantum ${current:-?} -> ${latest}"
    tag="$(fbquantum_fetch)" || exit 1
    echo_progress_done "Downloaded ${tag}"
fi

if [[ $migrate == true ]]; then
    echo_progress_start "Switching to swizzin single sign-on (no second login, no browser popup)"
    systemctl stop fbquantum
    if [[ $cfgver -lt 3 ]]; then
        # Accounts from the separate Quantum login (v1), or made before share/API permissions were set
        # (v2, Nov 27 2026 only), can't be used as-is, so Quantum starts with a fresh database. Your
        # files are untouched; the old database is kept next to it.
        for f in "$db" "${db}-wal" "${db}-shm"; do [[ -f $f ]] && mv -f "$f" "${f/fbquantum.db/fbquantum.db.before-sso}"; done
    fi
    fbquantum_write_config "$username" "$confdir"
    fbquantum_write_unit "$username" "$confdir"
    bash /etc/swizzin/scripts/nginx/fbquantum.sh
    echo_progress_done
fi

systemctl restart fbquantum
if fbquantum_healthy && nginx -t > /dev/null 2>&1; then
    systemctl reload nginx
    rm -f "${FBQ_BIN}.bak"
    echo_success "FileBrowser Quantum is ready ($(fbquantum_installed_version))"
else
    echo_warn "The new setup did not start; restoring the previous one"
    systemctl stop fbquantum
    [[ -f ${FBQ_BIN}.bak ]] && mv -f "${FBQ_BIN}.bak" "$FBQ_BIN"
    [[ -f ${db}.pre-upgrade ]] && cp -p "${db}.pre-upgrade" "$db"
    if [[ $migrate == true ]]; then
        for f in "${db}.before-sso" "${db}.before-sso-wal" "${db}.before-sso-shm"; do [[ -f $f ]] && mv -f "$f" "${f/fbquantum.db.before-sso/fbquantum.db}"; done
        [[ -f ${config}.pre-upgrade ]] && cp -p "${config}.pre-upgrade" "$config"
        [[ -f /tmp/fbquantum.service.pre-upgrade ]] && cp -p /tmp/fbquantum.service.pre-upgrade /etc/systemd/system/fbquantum.service
        [[ -f /tmp/fbquantum.nginx.pre-upgrade ]] && cp -p /tmp/fbquantum.nginx.pre-upgrade /etc/nginx/apps/fbquantum.conf
        [[ -f /tmp/fbquantum.snippet.pre-upgrade ]] && cp -p /tmp/fbquantum.snippet.pre-upgrade /etc/nginx/snippets/fbquantum-proxy.conf
        systemctl daemon-reload
    fi
    systemctl start fbquantum
    nginx -t > /dev/null 2>&1 && systemctl reload nginx
    echo_error "Upgrade failed and was rolled back; see: journalctl -u fbquantum"
    exit 1
fi
