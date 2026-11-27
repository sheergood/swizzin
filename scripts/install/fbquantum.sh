#!/usr/bin/env bash
# FileBrowser Quantum installer for swizzin (sheergood fork)
# https://github.com/gtsteffaniak/filebrowser — the maintained successor to File Browser.
#
# Runs as the master user, listens on 127.0.0.1 only, and is reached through nginx at /fbquantum
# behind the same login as the rest of swizzin. Share links (/fbquantum/public/) stay public.

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
port="$(port 10001 32001)"

_install() {
    echo_progress_start "Downloading FileBrowser Quantum (latest stable)"
    tag="$(fbquantum_fetch)" || exit 1
    rm -f "${FBQ_BIN}.bak"
    echo_progress_done "Downloaded ${tag}"
}

_config() {
    echo_progress_start "Configuring FileBrowser Quantum"
    mkdir -p "${confdir}/cache"
    cat > "${confdir}/config.yaml" << CONFIG
# FileBrowser Quantum — https://filebrowserquantum.com/en/docs/configuration/
# Changes take effect after: systemctl restart fbquantum
http:
  port: ${port}
  listen: "127.0.0.1"           # only nginx can reach it
  baseURL: "/fbquantum/"
  trustProxyHeaders: true
  trustedProxies: ["127.0.0.1", "::1"]
server:
  disableUpdateCheck: true      # updates come from: box upgrade fbquantum
  cacheDir: "${confdir}/cache"
  database:
    path: "${confdir}/fbquantum.db"
  sources:
    - path: "/home/${username}"
      name: "${username}"
      config:
        defaultEnabled: true
  logging:
    - levels: "info|warning|error"
auth:
  methods:
    password:
      enabled: true
      minLength: 5
      signup: false
      adminUsername: "${username}"
CONFIG
    chown -R "${username}:" "$confdir"
    chmod 700 "$confdir"
    # Create the admin account with the swizzin password. It is passed through the environment and
    # stdin only, so it never appears in the process list, the config file or the log. Without
    # FILEBROWSER_ADMIN_PASSWORD the first run would invent a random password and force a change.
    if ! (cd "$confdir" && printf '%s' "$password" | FILEBROWSER_ADMIN_PASSWORD="$password" \
        runuser -u "$username" -- "$FBQ_BIN" -c "${confdir}/config.yaml" user set "$username" --password --admin) >> "$log" 2>&1; then
        echo_error "Could not create the FileBrowser Quantum user"
        exit 1
    fi
    echo_progress_done
}

_systemd() {
    echo_progress_start "Installing systemd service"
    cat > /etc/systemd/system/fbquantum.service << SERVICE
[Unit]
Description=FileBrowser Quantum
After=network.target

[Service]
User=${username}
Group=${username}
UMask=002
Type=simple
WorkingDirectory=${confdir}
ExecStart=${FBQ_BIN} -c ${confdir}/config.yaml
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable -q --now fbquantum.service 2>&1 | tee -a "$log"
    if ! fbquantum_healthy "$port"; then
        echo_error "FileBrowser Quantum did not start; see: journalctl -u fbquantum"
        exit 1
    fi
    echo_progress_done "Service started"
}

_nginx() {
    echo_progress_start "Configuring nginx"
    bash /etc/swizzin/scripts/nginx/fbquantum.sh
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
