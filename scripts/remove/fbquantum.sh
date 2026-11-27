#!/usr/bin/env bash
# box remove fbquantum — removes the app, its settings and its nginx config. Your files are not touched.

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

username="$(cut -d: -f1 < /root/.master.info)"

systemctl disable -q --now fbquantum.service 2> /dev/null
rm -f /etc/systemd/system/fbquantum.service
systemctl daemon-reload
rm -rf /opt/fbquantum "/home/${username}/.config/fbquantum"
if [[ -f /etc/nginx/apps/fbquantum.conf ]]; then
    rm -f /etc/nginx/apps/fbquantum.conf /etc/nginx/snippets/fbquantum-proxy.conf
    systemctl reload nginx
fi
rm -f /install/.fbquantum.lock
