#!/bin/bash
# Plex's old apt repository answers 404 and makes `apt update` fail for everything, so servers are
# moved to the new one before anything else in box update runs apt. See sources/functions/plex_repo.
# Never fails box update.
#shellcheck source=sources/functions/plex_repo
. /etc/swizzin/sources/functions/plex_repo
if plex_repo_migrate; then
    echo_info "Plex apt repository moved to repo.plex.tv (the old one was retired by Plex)"
fi
exit 0
