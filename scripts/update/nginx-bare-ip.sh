#!/bin/bash
# Requests to the server's bare IP address get no answer; every domain keeps working.
# See sources/functions/bare_ip. Never fails box update.
if [[ -f /install/.nginx.lock ]]; then
    #shellcheck source=sources/functions/bare_ip
    . /etc/swizzin/sources/functions/bare_ip
    (bare_ip_apply) || echo_warn "Couldn't apply the bare-IP rule; nginx is unchanged"
fi
exit 0
