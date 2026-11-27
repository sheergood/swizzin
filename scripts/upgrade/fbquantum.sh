#!/usr/bin/env bash
# box upgrade fbquantum — newest stable FileBrowser Quantum, rolled back automatically if it fails to start

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/fbquantum
. /etc/swizzin/sources/functions/fbquantum

if [[ ! -f /install/.fbquantum.lock ]]; then
    echo_error "FileBrowser Quantum does not appear to be installed!"
    exit 1
fi

username="$(_get_master_username)"
config="/home/${username}/.config/fbquantum/config.yaml"
port="$(fbquantum_port "$config")"
current="$(fbquantum_installed_version)"

read -r latest _ <<< "$(fbquantum_latest_stable)"
if [[ -n $latest && $latest == "$current" ]]; then
    echo_success "FileBrowser Quantum is already up to date (${current})"
    exit 0
fi

echo_progress_start "Upgrading FileBrowser Quantum ${current:-?} -> ${latest:-latest stable}"
# a copy of the database, in case the new version migrates it and has to be rolled back
cp -p "/home/${username}/.config/fbquantum/fbquantum.db" "/home/${username}/.config/fbquantum/fbquantum.db.pre-upgrade" 2> /dev/null || true
tag="$(fbquantum_fetch)" || exit 1
systemctl restart fbquantum

if fbquantum_healthy "$port"; then
    rm -f "${FBQ_BIN}.bak"
    echo_progress_done "Now on ${tag}"
else
    echo_warn "${tag} did not start; restoring ${current}"
    systemctl stop fbquantum
    mv -f "${FBQ_BIN}.bak" "$FBQ_BIN"
    if [[ -f /home/${username}/.config/fbquantum/fbquantum.db.pre-upgrade ]]; then
        cp -p "/home/${username}/.config/fbquantum/fbquantum.db.pre-upgrade" "/home/${username}/.config/fbquantum/fbquantum.db"
    fi
    systemctl start fbquantum
    echo_error "Upgrade failed and was rolled back; see: journalctl -u fbquantum"
    exit 1
fi
