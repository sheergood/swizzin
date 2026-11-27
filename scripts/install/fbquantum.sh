#!/usr/bin/env bash
# FileBrowser Quantum installer for swizzin (sheergood fork)
# https://github.com/gtsteffaniak/filebrowser — the maintained successor to File Browser.
#
# Runs as the master user on a private unix socket, reached through nginx at /fbquantum/. Like the
# original File Browser it has its own login page (your swizzin username and password), separate from
# the dashboard. Share links (/fbquantum/public/) are public.

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/fbquantum
. /etc/swizzin/sources/functions/fbquantum

if [[ ! -f /install/.nginx.lock ]]; then
    echo_error "FileBrowser Quantum is served through nginx. Install it first: box install nginx"
    exit 1
fi

username="$(_get_master_username)"
password="$(_get_user_password "$username")"
confdir="/home/${username}/.config/fbquantum"

_install() {
    echo_progress_start "Downloading FileBrowser Quantum (latest stable)"
    tag="$(fbquantum_fetch)" || exit 1
    rm -f "${FBQ_BIN}.bak"
    echo_progress_done "Downloaded ${tag}"
}

_config() {
    echo_progress_start "Configuring FileBrowser Quantum"
    fbquantum_write_config "$username" "$confdir"
    if ! fbquantum_set_account "$username" "$confdir" "$password" >> "$log" 2>&1; then
        echo_error "Could not create the FileBrowser Quantum user"
        exit 1
    fi
    echo_progress_done
}

_systemd() {
    echo_progress_start "Installing systemd service"
    fbquantum_write_unit "$username" "$confdir"
    systemctl enable -q --now fbquantum.service 2>&1 | tee -a "$log"
    if ! fbquantum_healthy; then
        echo_error "FileBrowser Quantum did not start; see: journalctl -u fbquantum"
        exit 1
    fi
    echo_progress_done "Service started"
}

_nginx() {
    echo_progress_start "Configuring nginx"
    bash /etc/swizzin/scripts/nginx/fbquantum.sh
    if ! nginx -t > /dev/null 2>&1; then
        rm -f /etc/nginx/apps/fbquantum.conf /etc/nginx/snippets/fbquantum-proxy.conf
        echo_error "nginx rejected the FileBrowser Quantum config; it was removed again. See: nginx -t"
        exit 1
    fi
    systemctl reload nginx
    echo_progress_done
}

_install
_config
_systemd
_nginx

touch /install/.fbquantum.lock
echo_success "FileBrowser Quantum ${tag} installed"
echo_info "Open https://your-server/fbquantum/ and sign in with your swizzin username and password"
