#! /bin/bash

if [[ -f /install/.panel.lock ]]; then
    #shellcheck source=sources/functions/utils
    . /etc/swizzin/sources/functions/utils
    #shellcheck source=sources/functions/pyenv
    . /etc/swizzin/sources/functions/pyenv
    #shellcheck source=sources/functions/panel
    . /etc/swizzin/sources/functions/panel
    if [[ ! -d /opt/swizzin ]]; then
        echo_progress_start "swizzifying the panel"
        rm_if_exists "/srv/panel"
        rm_if_exists "/etc/cron.d/set_interface"
        rm_if_exists "/etc/nginx/apps/panel.conf"

        bash /usr/local/bin/swizzin/install/panel.sh

        echo_progress_done "Panel has been swizzified"
    else
        if [[ -d /opt/swizzin/venv ]]; then
            echo_progress_start "Moving swizzin venv to /opt/.venv"
            mkdir -p /opt/.venv
            python3 -m venv /opt/.venv/swizzin
            rm -rf /opt/swizzin/venv
            mv /opt/swizzin/swizzin/* /opt/swizzin/swizzin/.git /opt/swizzin
            rm_if_exists "/opt/swizzin/swizzin"
            sed -i 's|ExecStart=.*|ExecStart=/opt/.venv/swizzin/bin/python swizzin.py|g' /etc/systemd/system/panel.service
            sed -i 's|WorkingDirectory=.*|WorkingDirectory=/opt/swizzin|g' /etc/systemd/system/panel.service
            systemctl daemon-reload
            echo_progress_done "venv moved"
        fi

        pyminver=3.6.0
        pyenv_version=$(/opt/.venv/swizzin/bin/python3 --version | awk '{print $2}')

        if dpkg --compare-versions ${pyenv_version} lt ${pyminver}; then
            rm_if_exists "/opt/.venv/swizzin"
            pyenv_install
            pyenv_install_version 3.8.6
            pyenv_create_venv 3.8.6 /opt/.venv/swizzin
            chown -R swizzin: /opt/.venv/swizzin
        fi

        chown -R swizzin: /opt/swizzin
        chown -R swizzin: /opt/.venv/swizzin
        PANEL_PREV=$(sudo -u swizzin git -C /opt/swizzin rev-parse HEAD 2> /dev/null)
        export PANEL_PREV
        panel_use_fork_remote
        # Handles its own prints FYI
        bash /usr/local/bin/swizzin/upgrade/panel.sh

    fi

    # sudo rules: app control through the checked wrapper once this panel supports it
    (panel_sudoers) || echo_warn "Couldn't update the panel's sudo rules; kept the current ones"

    # Optional panel extras run in subshells: a failure here only warns, it never aborts box update.
    if [[ ! -f /etc/systemd/system/swizzin-smart.timer ]]; then
        echo_progress_start "Adding SMART collector for the panel"
        (panel_smart_setup) || echo_warn "SMART collector setup failed; drive health will be unavailable"
        echo_progress_done
    fi

    if [[ ! -f /etc/systemd/system/swizzin-f2b.timer ]]; then
        echo_progress_start "Adding fail2ban snapshot for the panel"
        (panel_f2b_setup) || echo_warn "fail2ban snapshot setup failed; the Security card will be empty"
        echo_progress_done
    fi

    fbq_conf="/home/$(_get_master_username 2> /dev/null)/.config/fbquantum/config.yaml"
    if [[ -f /install/.fbquantum.lock && -f /etc/swizzin/scripts/upgrade/fbquantum.sh && -f $fbq_conf ]] &&
        (. /etc/swizzin/sources/functions/fbquantum && [[ $(fbquantum_config_version "$fbq_conf") -lt $FBQ_CONFIG_VERSION ]]); then
        # Quantum's own config is older than its nginx config: move both together (with rollback),
        # never the nginx side alone, which would leave Quantum's login unusable.
        echo_progress_start "Updating the FileBrowser Quantum setup"
        bash /etc/swizzin/scripts/upgrade/fbquantum.sh >> "$log" 2>&1 || echo_warn "FileBrowser Quantum setup update failed and was rolled back; see ${log}"
        echo_progress_done
    elif [[ -f /install/.fbquantum.lock && -f /etc/swizzin/scripts/nginx/fbquantum.sh ]]; then
        # keep FileBrowser Quantum's nginx config current (it has its own login page)
        cp -p /etc/nginx/apps/fbquantum.conf /tmp/fbquantum.conf.prev 2> /dev/null
        if bash /etc/swizzin/scripts/nginx/fbquantum.sh >> "$log" 2>&1 && nginx -t > /dev/null 2>&1; then
            systemctl reload nginx
        elif [[ -f /tmp/fbquantum.conf.prev ]]; then
            cp -p /tmp/fbquantum.conf.prev /etc/nginx/apps/fbquantum.conf    # never leave nginx unloadable
            echo_warn "Couldn't refresh FileBrowser Quantum's nginx config; kept the previous one"
        fi
    fi

    # Torrent racing and Discord alerts were added then removed (sheergood-8/9): take away what a
    # server that updated in between got - the crash-alert units, the saved webhook and the racing data.
    if [[ -f /etc/systemd/system/swizzin-panel-alert.service ]] || [[ -f /etc/systemd/system/panel.service.d/alert.conf ]]; then
        rm -f /etc/systemd/system/swizzin-panel-alert.service /etc/systemd/system/panel.service.d/alert.conf
        rmdir /etc/systemd/system/panel.service.d 2> /dev/null || true
        systemctl daemon-reload
    fi
    rm -f /opt/swizzin/alerts.json /opt/swizzin/alerts.json.tmp /opt/swizzin/alerts-state.json \
        /opt/swizzin/alerts-state.json.tmp /opt/swizzin/racing.json /opt/swizzin/racing.json.tmp
    if grep -qE '"(qbittorrent|autobrr)"' /var/lib/swizzin/arr.json 2> /dev/null; then
        systemctl start swizzin-host.service > /dev/null 2>&1 || true    # rewrites it without qBittorrent/autobrr
    fi

    if [[ ! -f /etc/systemd/system/swizzin-host.timer ]]; then
        echo_progress_start "Adding host info snapshot for the panel"
        (panel_host_setup) || echo_warn "host info setup failed; memory module details and Plex now playing will be unavailable"
        echo_progress_done
    fi

    if [[ ! -f /etc/systemd/system/swizzin-updates.timer ]]; then
        echo_progress_start "Adding app update checks for the panel"
        (panel_updates_setup) || echo_warn "update check setup failed; the panel won't show app updates"
        echo_progress_done
    fi

    if ! systemctl is-enabled -q vnstat 2> /dev/null; then
        echo_progress_start "Enabling vnstat for panel traffic stats"
        (panel_vnstat_setup) || echo_warn "vnstat setup failed; transfer stats will be unavailable"
        echo_progress_done
    fi

    if grep -q -E "swizzin.*/bin/sh" /etc/passwd; then
        echo_progress_start "Removing shell access for panel"
        usermod swizzin -s /usr/sbin/nologin
        echo_progress_done
    fi
fi
