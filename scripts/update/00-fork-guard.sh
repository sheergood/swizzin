#!/bin/bash
# sheergood fork: warn (never fail) when this server has apps installed that the fork no longer ships.
# Those apps keep running exactly as before; box simply can't upgrade or remove them anymore.

unsupported=()
for lock in /install/.*.lock; do
    [[ -e $lock ]] || continue
    app=${lock##*/.}
    app=${app%.lock}
    case $app in
        panel | nginx | letsencrypt | delugeweb | rutorrent | sonarrold) continue ;; # infra or sub-locks
    esac
    [[ -f /etc/swizzin/scripts/install/$app.sh ]] || unsupported+=("$app")
done

if ((${#unsupported[@]})); then
    echo_warn "Installed but not maintained by the sheergood fork: ${unsupported[*]}
They keep running untouched, but 'box upgrade/remove' no longer handles them.
To remove one cleanly, switch back to upstream for a moment (see FORK.md → Rollback)."
fi
exit 0
