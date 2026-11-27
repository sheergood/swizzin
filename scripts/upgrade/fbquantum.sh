#!/usr/bin/env bash
# box upgrade fbquantum — newest stable FileBrowser Quantum, rolled back automatically if it fails to start.
# Also moves older installs to the current setup (config version in config.yaml): private unix socket,
# own login page like the original File Browser, and no way for it to log you out of the dashboard.

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
if [[ -z $latest ]]; then
    if [[ $migrate == false ]]; then
        echo_warn "Couldn't check for a newer FileBrowser Quantum; nothing was changed (${current:-unknown} stays)"
        exit 0
    fi
    echo_info "Couldn't check for a newer FileBrowser Quantum; updating the setup and keeping ${current:-the installed version}"
elif [[ $latest == "$current" && $migrate == false ]]; then
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
    echo_progress_start "Updating the FileBrowser Quantum setup (own login page, dashboard stays signed in)"
    systemctl stop fbquantum
    if [[ $cfgver -lt 4 ]]; then
        # Accounts from earlier setups (single sign-on, Nov 27 2026) can't sign in with a password, so
        # Quantum starts with a fresh database. Your files are untouched; the old one is kept next to it.
        for f in "$db" "${db}-wal" "${db}-shm"; do [[ -f $f ]] && mv -f "$f" "${f/fbquantum.db/fbquantum.db.before-v4}"; done
    fi
    fbquantum_write_config "$username" "$confdir"
    if [[ $cfgver -lt 4 ]] && ! fbquantum_set_account "$username" "$confdir" "$(_get_user_password "$username")" >> "$log" 2>&1; then
        echo_warn "Could not create the FileBrowser Quantum account"
    fi
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
        for f in "${db}.before-v4" "${db}.before-v4-wal" "${db}.before-v4-shm"; do [[ -f $f ]] && mv -f "$f" "${f/fbquantum.db.before-v4/fbquantum.db}"; done
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
