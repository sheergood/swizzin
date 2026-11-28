#!/bin/bash
# swizzin dashboard installer
# Author: liara
# Copyright (C) 2020 Swizzin
# Licensed under GNU General Public License v3.0 GPL-3 (in short)
#
#   You may copy, distribute and modify the software as long as you track
#   changes/dates in source files. Any modifications to our software
#   including (via compiler) GPL-licensed code must also be made available
#   under the GPL along with build & install instructions.
#
#! /bin/bash

if [[ ! -f /install/.nginx.lock ]]; then
    echo_warn "This package requires nginx to be installed!"
    if ask "Install nginx?" Y; then
        bash /usr/local/bin/swizzin/install/nginx.sh
    else
        exit 1
    fi
fi

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/pyenv
. /etc/swizzin/sources/functions/pyenv
#shellcheck source=sources/functions/panel
. /etc/swizzin/sources/functions/panel

master=$(_get_master_username)

useradd -r swizzin -s /usr/sbin/nologin > /dev/null 2>&1

systempy3_ver=$(get_candidate_version python3)

if dpkg --compare-versions ${systempy3_ver} lt 3.6.0; then
    LIST='acl'
    PYENV=True
else
    LIST='python3-pip python3-venv acl'
fi

apt_install $LIST

case ${PYENV} in
    True)
        pyenv_install
        pyenv_install_version 3.8.6
        pyenv_create_venv 3.8.6 /opt/.venv/swizzin
        chown -R swizzin: /opt/.venv/swizzin
        ;;
    *)
        python3_venv swizzin swizzin
        ;;
esac

echo_progress_start "Cloning panel"
git clone -b "$PANEL_BRANCH" "$PANEL_REPO" /opt/swizzin >> ${log} 2>&1
echo_progress_done "Panel cloned"

echo_progress_start "Installing python dependencies"
/opt/.venv/swizzin/bin/pip install --upgrade pip wheel >> ${log} 2>&1
/opt/.venv/swizzin/bin/pip install -r /opt/swizzin/requirements.txt >> ${log} 2>&1
echo_progress_done

echo_progress_start "Setting permissions"
chown -R swizzin: /opt/swizzin
chown -R swizzin: /opt/.venv/swizzin
setfacl -m g:swizzin:rx /home/*
echo_progress_done

echo_progress_start "Configuring panel"
if [[ -f /install/.deluge.lock ]]; then
    touch /install/.delugeweb.lock
fi

if [[ $master == $(id -nu 1000) ]]; then
    :
else
    echo "ADMIN_USER = '$master'" >> /opt/swizzin/swizzin.cfg
fi
echo_progress_done

# Checking nginx existence is the first thing that happens in the script
echo_progress_start "Configuring nginx"
bash /usr/local/bin/swizzin/nginx/panel.sh
systemctl reload nginx
echo_progress_done

echo_progress_start "Setting up SMART collector and traffic stats"
(panel_smart_setup) || echo_warn "SMART collector setup failed; drive health will be unavailable"
(panel_f2b_setup) || echo_warn "fail2ban snapshot setup failed; the Security card will be empty"
(panel_host_setup) || echo_warn "host info setup failed; memory module details and Plex now playing will be unavailable"
(panel_vnstat_setup) || echo_warn "vnstat setup failed; transfer stats will be unavailable"
(panel_updates_setup) || echo_warn "update check setup failed; the panel won't show app updates"
(panel_f2b_web_setup) || echo_warn "Couldn't add the fail2ban web jails; fail2ban keeps its previous setup"
echo_progress_done

echo_progress_start "Installing systemd service"
cat > /etc/systemd/system/panel.service << EOS
[Unit]
Description=swizzin panel service
After=nginx.service

[Service]
Type=simple
User=swizzin

ExecStart=/opt/.venv/swizzin/bin/python swizzin.py
WorkingDirectory=/opt/swizzin
Restart=on-failure
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOS

panel_sudoers || echo_warn "Couldn't write the panel's sudo rules; app buttons in the panel won't work"

systemctl enable -q --now panel >> ${log} 2>&1
echo_progress_done "Panel started"

echo_success "Panel installed"
touch /install/.panel.lock
