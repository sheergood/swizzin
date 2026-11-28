#!/bin/bash

# (sheergood fork) The old "/deb/" endpoint rewrite is gone: it turned Plex's new repository
# (https://repo.plex.tv/deb/) back into the retired one. Repository moves are done by
# scripts/update/06-plex-repo.sh, before box update first runs apt.

# removing lockfile for the upgrade script so that it can be re-run as many times as people want
if [ -f "/install/.updateplex.lock" ]; then
    # echo file exists
    rm /install/.updateplex.lock
fi
