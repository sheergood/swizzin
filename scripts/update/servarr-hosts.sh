#!/bin/bash
# Sonarr / Radarr / Prowlarr / Lidarr answer only to localhost (Allowed Hosts); nginx passes
# 127.0.0.1 to them, so every domain and the server IP keep working. See sources/functions/servarr_hosts.
# Never fails box update: problems only warn, and the previous files are put back.
#shellcheck source=sources/functions/servarr_hosts
. /etc/swizzin/sources/functions/servarr_hosts
(servarr_hosts_apply) || echo_warn "Couldn't set Allowed Hosts for the Servarr apps; nothing was changed"
exit 0
